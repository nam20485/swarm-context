using System.Formats.Tar;
using System.Net;
using System.Text;
using Docker.DotNet;
using Docker.DotNet.Models;
using Microsoft.Extensions.Logging;
using NSubstitute;
using SwarmSandbox.Api.Contracts;
using SwarmSandbox.Api.Provisioning;

namespace SwarmSandbox.Tests.Provisioning;

public class DockerSandboxProvisionerTests
{
    private static readonly TimeSpan Ttl = TimeSpan.FromHours(2);

    private static SandboxOptions Options(string? seedSourcePath = null) => new()
    {
        DockerHost = "unix:///var/run/docker.sock",
        ImageName = "test-image:1",
        SeedSourcePath = seedSourcePath,
        RepoUrl = "https://repo.example.com/swarm.git",
        GitToken = "tok-123",
        WorkspaceBranch = "development",
        DefaultTtl = Ttl,
        NetworkName = "sandbox-net",
        ContainerUser = "1000:1000",
    };

    private sealed class CapturingLogger : ILogger<DockerSandboxProvisioner>
    {
        public List<(LogLevel Level, string Message)> Entries { get; } = [];

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter) =>
            Entries.Add((logLevel, formatter(state, exception)));
    }

    private sealed record Subject(
        DockerSandboxProvisioner Provisioner,
        IContainerOperations Containers,
        IExecOperations Exec,
        CapturingLogger Logger);

    private static Subject CreateSubject(SandboxOptions? options = null)
    {
        var containers = Substitute.For<IContainerOperations>();
        var exec = Substitute.For<IExecOperations>();
        var client = Substitute.For<IDockerClient>();
        client.Containers.Returns(containers);
        client.Exec.Returns(exec);
        var logger = new CapturingLogger();
        return new Subject(new DockerSandboxProvisioner(options ?? Options(), client, logger), containers, exec, logger);
    }

    private static void SetupSuccessfulCreate(IContainerOperations containers, string containerId = "docker-id-42")
    {
        containers
            .CreateContainerAsync(Arg.Any<CreateContainerParameters>(), Arg.Any<CancellationToken>())
            .Returns(new CreateContainerResponse { ID = containerId });
        containers
            .StartContainerAsync(Arg.Any<string>(), Arg.Any<ContainerStartParameters>(), Arg.Any<CancellationToken>())
            .Returns(true);
    }

    [Fact]
    public async Task CreateSandboxAsync_ShapesContainerCreateRequest()
    {
        var subject = CreateSubject();
        CreateContainerParameters? captured = null;
        subject.Containers
            .CreateContainerAsync(Arg.Do<CreateContainerParameters>(p => captured = p), Arg.Any<CancellationToken>())
            .Returns(new CreateContainerResponse { ID = "docker-id-42" });
        subject.Containers
            .StartContainerAsync(Arg.Any<string>(), Arg.Any<ContainerStartParameters>(), Arg.Any<CancellationToken>())
            .Returns(true);

        await subject.Provisioner.CreateSandboxAsync(new SandboxRequest("feature/worker-wave"), CancellationToken.None);

        Assert.NotNull(captured);
        Assert.Matches(@"^swarmsandbox-[0-9a-f]{8}$", captured.Name);
        Assert.Equal("test-image:1", captured.Image);
        Assert.Equal(
            new[]
            {
                "REPO_URL=https://repo.example.com/swarm.git",
                "GIT_TOKEN=tok-123",
                "WORKSPACE_BRANCH=feature/worker-wave",
            },
            captured.Env);
        // No Cmd override: the image ENTRYPOINT already runs /entrypoint.sh.
        Assert.True(captured.Cmd is null or [], "image ENTRYPOINT already runs /entrypoint.sh; Cmd must stay unset");

        var host = captured.HostConfig;
        Assert.NotNull(host);
        Assert.Equal(["ALL"], host.CapDrop);
        Assert.Equal(["no-new-privileges"], host.SecurityOpt);
        Assert.Equal(4L * 1024 * 1024 * 1024, host.Memory);
        Assert.Equal(2_000_000_000L, host.NanoCPUs);
        Assert.Equal(512, host.PidsLimit);
        Assert.Equal("sandbox-net", host.NetworkMode);
        Assert.Equal(RestartPolicyKind.No, host.RestartPolicy.Name);
        Assert.True(host.Binds is null or [], "sandbox containers must have no host binds");
        Assert.True(host.Mounts is null or [], "sandbox containers must have no mounts (incl. docker.sock)");
        Assert.False(host.Privileged);
    }

    [Fact]
    public async Task CreateSandboxAsync_StartsContainerAndReturnsRunningInfo()
    {
        var subject = CreateSubject();
        SetupSuccessfulCreate(subject.Containers, "docker-id-42");

        var info = await subject.Provisioner.CreateSandboxAsync(new SandboxRequest("main"), CancellationToken.None);

        _ = subject.Containers.Received(1).StartContainerAsync(
            "docker-id-42",
            Arg.Any<ContainerStartParameters>(),
            Arg.Any<CancellationToken>());
        Assert.Equal(SandboxState.Running, info.State);
        Assert.Equal("docker-id-42", info.ContainerId);
        Assert.Matches(@"^swarmsandbox-[0-9a-f]{8}$", info.Id);
        Assert.Equal(info.Id, info.ContainerName);
        Assert.Equal(Ttl, info.ExpiresAt - info.CreatedAt);
    }

    [Fact]
    public async Task CreateSandboxAsync_DefaultsBranchWhenRequestBranchMissing()
    {
        var subject = CreateSubject();
        CreateContainerParameters? captured = null;
        subject.Containers
            .CreateContainerAsync(Arg.Do<CreateContainerParameters>(p => captured = p), Arg.Any<CancellationToken>())
            .Returns(new CreateContainerResponse { ID = "docker-id-42" });
        subject.Containers
            .StartContainerAsync(Arg.Any<string>(), Arg.Any<ContainerStartParameters>(), Arg.Any<CancellationToken>())
            .Returns(true);

        await subject.Provisioner.CreateSandboxAsync(new SandboxRequest("   "), CancellationToken.None);

        Assert.NotNull(captured);
        Assert.Contains("WORKSPACE_BRANCH=development", captured.Env);
    }

    [Fact]
    public async Task CreateSandboxAsync_SkipsSeedWhenSeedPathInvalid()
    {
        var subject = CreateSubject(Options(seedSourcePath: "/definitely/not/a/seed/dir"));
        SetupSuccessfulCreate(subject.Containers);

        var info = await subject.Provisioner.CreateSandboxAsync(new SandboxRequest("main"), CancellationToken.None);

        _ = subject.Containers.DidNotReceive().ExtractArchiveToContainerAsync(
            Arg.Any<string>(),
            Arg.Any<CopyToContainerParameters>(),
            Arg.Any<Stream>(),
            Arg.Any<CancellationToken>());
        _ = subject.Exec.DidNotReceive().CreateContainerExecAsync(
            Arg.Any<string>(),
            Arg.Any<ContainerExecCreateParameters>(),
            Arg.Any<CancellationToken>());
        Assert.Equal(SandboxState.Running, info.State);
        Assert.Contains(
            subject.Logger.Entries,
            e => e.Level == LogLevel.Information
                && e.Message.Contains("/definitely/not/a/seed/dir")
                && e.Message.Contains("desktop will provision on first connect"));
    }

    [Fact]
    public async Task CreateSandboxAsync_SkipsSeedWhenSeedSourcePathUnset()
    {
        var subject = CreateSubject(Options(seedSourcePath: null));
        SetupSuccessfulCreate(subject.Containers);

        await subject.Provisioner.CreateSandboxAsync(new SandboxRequest("main"), CancellationToken.None);

        _ = subject.Containers.DidNotReceive().ExtractArchiveToContainerAsync(
            Arg.Any<string>(),
            Arg.Any<CopyToContainerParameters>(),
            Arg.Any<Stream>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task CreateSandboxAsync_InjectsSeedWhenSeedPathValid()
    {
        var seedDir = CreateSeedDir();
        try
        {
            var subject = CreateSubject(Options(seedSourcePath: seedDir));
            SetupSuccessfulCreate(subject.Containers);

            var execCalls = new List<ContainerExecCreateParameters>();
            subject.Exec
                .CreateContainerExecAsync(Arg.Any<string>(), Arg.Do<ContainerExecCreateParameters>(execCalls.Add), Arg.Any<CancellationToken>())
                .Returns(new ContainerExecCreateResponse { ID = "exec-1" });
            subject.Exec
                .StartContainerExecAsync(Arg.Any<string>(), Arg.Any<ContainerExecStartParameters>(), Arg.Any<CancellationToken>())
                // Fresh stream per exec: ReadOutputToEndAsync disposes it, and the
                // provisioner now runs a second exec (mkdir) before the upload.
                .Returns(_ => new MultiplexedStream(new MemoryStream(Encoding.UTF8.GetBytes("/home/dev")), multiplexed: false));

            string? uploadedPath = null;
            byte[]? uploadedTar = null;
            subject.Containers
                .ExtractArchiveToContainerAsync(
                    Arg.Any<string>(),
                    Arg.Do<CopyToContainerParameters>(p => uploadedPath = p.Path),
                    Arg.Do<Stream>(s =>
                    {
                        using var ms = new MemoryStream();
                        s.Position = 0;
                        s.CopyTo(ms);
                        uploadedTar = ms.ToArray();
                    }),
                    Arg.Any<CancellationToken>())
                .Returns(Task.CompletedTask);

            await subject.Provisioner.CreateSandboxAsync(new SandboxRequest("main"), CancellationToken.None);

            // 1st exec resolves HOME, 2nd creates the destination dir, 3rd fixes ownership/permissions.
            Assert.Equal(3, execCalls.Count);
            Assert.Equal(new[] { "sh", "-lc", "printf %s \"$HOME\"" }, execCalls[0].Cmd);
            Assert.Equal(new[] { "sh", "-lc", "mkdir -p /home/dev/.zcode/server" }, execCalls[1].Cmd);
            var fixup = string.Join(" ", execCalls[2].Cmd);
            Assert.Contains("chown -R 1000:1000 /home/dev/.zcode/server", fixup);
            Assert.Contains("chmod +x /home/dev/.zcode/server/zcode-server.cjs /home/dev/.zcode/server/node", fixup);

            Assert.Equal("/home/dev/.zcode/server", uploadedPath);
            Assert.NotNull(uploadedTar);
            var entryNames = ReadTarEntryNames(uploadedTar);
            Assert.Contains("zcode-server.cjs", entryNames);
            Assert.Contains("node", entryNames);
        }
        finally
        {
            Directory.Delete(seedDir, recursive: true);
        }
    }

    [Fact]
    public async Task CreateSandboxAsync_SeedFailureDoesNotFailProvisioning()
    {
        var seedDir = CreateSeedDir();
        try
        {
            var subject = CreateSubject(Options(seedSourcePath: seedDir));
            SetupSuccessfulCreate(subject.Containers);

            subject.Exec
                .CreateContainerExecAsync(Arg.Any<string>(), Arg.Any<ContainerExecCreateParameters>(), Arg.Any<CancellationToken>())
                .Returns(new ContainerExecCreateResponse { ID = "exec-1" });
            subject.Exec
                .StartContainerExecAsync(Arg.Any<string>(), Arg.Any<ContainerExecStartParameters>(), Arg.Any<CancellationToken>())
                .Returns(_ => new MultiplexedStream(new MemoryStream(Encoding.UTF8.GetBytes("/home/dev")), multiplexed: false));
            subject.Containers
                .ExtractArchiveToContainerAsync(Arg.Any<string>(), Arg.Any<CopyToContainerParameters>(), Arg.Any<Stream>(), Arg.Any<CancellationToken>())
                .Returns<Task>(_ => throw new DockerApiException(HttpStatusCode.Conflict, "extract failed"));

            var info = await subject.Provisioner.CreateSandboxAsync(new SandboxRequest("main"), CancellationToken.None);

            Assert.Equal(SandboxState.Running, info.State);
            Assert.Contains(subject.Logger.Entries, e => e.Level == LogLevel.Warning && e.Message.Contains("seed"));
        }
        finally
        {
            Directory.Delete(seedDir, recursive: true);
        }
    }

    [Theory]
    [InlineData("created", SandboxState.Creating)]
    [InlineData("running", SandboxState.Running)]
    [InlineData("restarting", SandboxState.Stopping)]
    [InlineData("paused", SandboxState.Stopped)]
    [InlineData("exited", SandboxState.Stopped)]
    [InlineData("dead", SandboxState.Faulted)]
    [InlineData("removing", SandboxState.Removed)]
    [InlineData("something-new", SandboxState.Faulted)]
    public async Task GetStatusAsync_MapsDockerStateToSandboxState(string dockerStatus, SandboxState expected)
    {
        var subject = CreateSubject();
        var created = new DateTime(2026, 1, 2, 3, 4, 5, DateTimeKind.Utc);
        subject.Containers
            .InspectContainerAsync("cid", Arg.Any<CancellationToken>())
            .Returns(new ContainerInspectResponse
            {
                ID = "docker-full-id",
                Name = "/swarmsandbox-ab12cd34",
                Created = created,
                State = new State { Status = dockerStatus, Error = "boom" },
            });

        var status = await subject.Provisioner.GetStatusAsync("cid", CancellationToken.None);

        Assert.Equal(expected, status.Info.State);
        Assert.Equal("docker-full-id", status.Info.ContainerId);
        Assert.Equal("swarmsandbox-ab12cd34", status.Info.ContainerName);
        Assert.Equal("boom", status.LastError);
        Assert.Equal(Ttl, status.Info.ExpiresAt - status.Info.CreatedAt);
    }

    [Fact]
    public async Task GetStatusAsync_WhenContainerNotFound_ReturnsRemovedInsteadOfThrowing()
    {
        var subject = CreateSubject();
        subject.Containers
            .InspectContainerAsync("gone", Arg.Any<CancellationToken>())
            .Returns<ContainerInspectResponse>(_ => throw new DockerContainerNotFoundException(HttpStatusCode.NotFound, "No such container: gone"));

        var status = await subject.Provisioner.GetStatusAsync("gone", CancellationToken.None);

        Assert.Equal(SandboxState.Removed, status.Info.State);
        Assert.NotNull(status.LastError);
    }

    [Fact]
    public async Task GetStatusAsync_WithoutStateError_ReportsNullLastError()
    {
        var subject = CreateSubject();
        subject.Containers
            .InspectContainerAsync("cid", Arg.Any<CancellationToken>())
            .Returns(new ContainerInspectResponse
            {
                ID = "docker-full-id",
                Name = "/swarmsandbox-ab12cd34",
                State = new State { Status = "running", Error = "" },
            });

        var status = await subject.Provisioner.GetStatusAsync("cid", CancellationToken.None);

        Assert.Null(status.LastError);
        Assert.Equal(SandboxState.Running, status.Info.State);
    }

    [Fact]
    public async Task GetLogsAsync_PassesTailParameterAndReturnsOutput()
    {
        var subject = CreateSubject();

        subject.Containers
            .GetContainerLogsAsync(
                "cid",
                Arg.Any<ContainerLogsParameters>(),
                Arg.Any<IProgress<string>>(),
                Arg.Any<CancellationToken>())
            .Returns(ci =>
            {
                var progress = ci.ArgAt<IProgress<string>>(2);
                progress.Report("line1\n");
                progress.Report("line2\n");
                return Task.CompletedTask;
            });

        var logs = await subject.Provisioner.GetLogsAsync("cid", 100, CancellationToken.None);

        _ = subject.Containers.Received(1).GetContainerLogsAsync(
            "cid",
            Arg.Is<ContainerLogsParameters>(p => p.Tail == "100" && p.ShowStdout == true && p.ShowStderr == true),
            Arg.Any<IProgress<string>>(),
            Arg.Any<CancellationToken>());
        Assert.Equal("line1\nline2\n", logs);
    }

    [Fact]
    public async Task StopAsync_UsesTenSecondTimeout()
    {
        var subject = CreateSubject();
        subject.Containers
            .StopContainerAsync(Arg.Any<string>(), Arg.Any<ContainerStopParameters>(), Arg.Any<CancellationToken>())
            .Returns(true);

        await subject.Provisioner.StopAsync("cid", CancellationToken.None);

        _ = subject.Containers.Received(1).StopContainerAsync(
            "cid",
            Arg.Is<ContainerStopParameters>(p => p.WaitBeforeKillSeconds == 10),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task StopAsync_WhenContainerNotFound_DoesNotThrow()
    {
        var subject = CreateSubject();
        subject.Containers
            .StopContainerAsync(Arg.Any<string>(), Arg.Any<ContainerStopParameters>(), Arg.Any<CancellationToken>())
            .Returns<bool>(_ => throw new DockerContainerNotFoundException(HttpStatusCode.NotFound, "No such container: cid"));

        await subject.Provisioner.StopAsync("cid", CancellationToken.None);
    }

    [Fact]
    public async Task RemoveAsync_ForcesRemoval()
    {
        var subject = CreateSubject();
        subject.Containers
            .RemoveContainerAsync(Arg.Any<string>(), Arg.Any<ContainerRemoveParameters>(), Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        await subject.Provisioner.RemoveAsync("cid", CancellationToken.None);

        _ = subject.Containers.Received(1).RemoveContainerAsync(
            "cid",
            Arg.Is<ContainerRemoveParameters>(p => p.Force == true && p.RemoveVolumes == true),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task RemoveAsync_WhenContainerNotFound_DoesNotThrow()
    {
        var subject = CreateSubject();
        subject.Containers
            .RemoveContainerAsync(Arg.Any<string>(), Arg.Any<ContainerRemoveParameters>(), Arg.Any<CancellationToken>())
            .Returns<Task>(_ => throw new DockerContainerNotFoundException(HttpStatusCode.NotFound, "No such container: cid"));

        await subject.Provisioner.RemoveAsync("cid", CancellationToken.None);
    }

    [Fact]
    public async Task CreateSandboxAsync_SeedValidIssuesMkdirExecBeforeExtractArchive()
    {
        var seedDir = CreateSeedDir();
        try
        {
            var subject = CreateSubject(Options(seedSourcePath: seedDir));
            SetupSuccessfulCreate(subject.Containers);

            var timeline = new List<string>();
            subject.Exec
                .CreateContainerExecAsync(
                    Arg.Any<string>(),
                    Arg.Do<ContainerExecCreateParameters>(p => timeline.Add("exec: " + string.Join(' ', p.Cmd))),
                    Arg.Any<CancellationToken>())
                .Returns(new ContainerExecCreateResponse { ID = "exec-1" });
            subject.Exec
                .StartContainerExecAsync(Arg.Any<string>(), Arg.Any<ContainerExecStartParameters>(), Arg.Any<CancellationToken>())
                .Returns(_ => new MultiplexedStream(new MemoryStream(Encoding.UTF8.GetBytes("/home/dev")), multiplexed: false));
            subject.Containers
                .ExtractArchiveToContainerAsync(
                    Arg.Any<string>(),
                    Arg.Do<CopyToContainerParameters>(p => timeline.Add("extract: " + p.Path)),
                    Arg.Any<Stream>(),
                    Arg.Any<CancellationToken>())
                .Returns(Task.CompletedTask);

            await subject.Provisioner.CreateSandboxAsync(new SandboxRequest("main"), CancellationToken.None);

            // Docker's PutArchive 404s when the destination is missing, so the
            // mkdir exec must land before ExtractArchiveToContainerAsync.
            var mkdirIndex = timeline.FindIndex(t => t.Contains("mkdir -p /home/dev/.zcode/server"));
            var extractIndex = timeline.FindIndex(t => t.StartsWith("extract: ", StringComparison.Ordinal));
            Assert.True(mkdirIndex >= 0, "expected a mkdir -p exec before the seed upload; timeline: " + string.Join(" | ", timeline));
            Assert.True(extractIndex > mkdirIndex, $"extract (index {extractIndex}) must run after mkdir (index {mkdirIndex}); timeline: " + string.Join(" | ", timeline));
        }
        finally
        {
            Directory.Delete(seedDir, recursive: true);
        }
    }

    [Theory]
    [InlineData("1000:1000")]
    [InlineData("0:0")]
    [InlineData("65534:65534")]
    public void ContainerUserValidation_AcceptsNumericUidGid(string value)
    {
        var options = Options();
        options.ContainerUser = value;

        options.Validate();
    }

    [Theory]
    [InlineData("root")]
    [InlineData("1000")]
    [InlineData("abc:def")]
    [InlineData("1000 ")]
    [InlineData("1000:1000; rm -rf /")]
    [InlineData("")]
    public void ContainerUserValidation_RejectsAnythingButNumericUidGid(string value)
    {
        var options = Options();
        options.ContainerUser = value;

        var exception = Assert.Throws<InvalidOperationException>(() => options.Validate());
        Assert.Contains("uid:gid", exception.Message);
    }

    [Fact]
    public void Constructor_ThrowsWhenContainerUserIsNotNumericUidGid()
    {
        var options = Options();
        options.ContainerUser = "1000:1000; rm -rf /";

        Assert.Throws<InvalidOperationException>(() => CreateSubject(options));
    }

    private static string CreateSeedDir()
    {
        var dir = Path.Combine(Path.GetTempPath(), "m1-seed-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "zcode-server.cjs"), "// server");
        File.WriteAllText(Path.Combine(dir, "node"), "#!/bin/sh\necho node");
        return dir;
    }

    private static List<string> ReadTarEntryNames(byte[] tarBytes)
    {
        var names = new List<string>();
        using var ms = new MemoryStream(tarBytes);
        using var reader = new TarReader(ms);
        while (reader.GetNextEntry() is { } entry)
        {
            names.Add(entry.Name);
        }

        return names;
    }
}
