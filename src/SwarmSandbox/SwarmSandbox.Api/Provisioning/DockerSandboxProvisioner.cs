using System.Formats.Tar;
using System.Globalization;
using System.Text;
using Docker.DotNet;
using Docker.DotNet.Models;
using Microsoft.Extensions.Options;
using SwarmSandbox.Api.Contracts;

namespace SwarmSandbox.Api.Provisioning;

/// <summary>
/// Provisions sandbox containers through the local Docker daemon (Docker.DotNet.Enhanced).
/// </summary>
public sealed class DockerSandboxProvisioner : ISandboxProvisioner
{
    private const long MemoryBytes = 4L * 1024 * 1024 * 1024;
    private const long NanoCpusForTwoCores = 2_000_000_000;
    private const long PidsLimit = 512;
    private const uint StopTimeoutSeconds = 10;
    private const string NamePrefix = "swarmsandbox-";

    private readonly SandboxOptions _options;
    private readonly IDockerClient _client;
    private readonly ILogger<DockerSandboxProvisioner> _logger;

    public DockerSandboxProvisioner(IOptions<SandboxOptions> options, ILogger<DockerSandboxProvisioner> logger)
        : this(options.Value, CreateClient(options.Value.DockerHost), logger)
    {
    }

    internal DockerSandboxProvisioner(SandboxOptions options, IDockerClient client, ILogger<DockerSandboxProvisioner> logger)
    {
        options.Validate();
        _options = options;
        _client = client;
        _logger = logger;
    }

    private static IDockerClient CreateClient(string dockerHost) =>
        new DockerClientBuilder().WithEndpoint(new Uri(dockerHost)).Build();

    public async Task<SandboxInfo> CreateSandboxAsync(SandboxRequest request, CancellationToken ct)
    {
        var name = NamePrefix + Guid.NewGuid().ToString("N")[..8];
        var create = new CreateContainerParameters
        {
            Name = name,
            Image = _options.ImageName,
            Env =
            [
                $"REPO_URL={_options.RepoUrl}",
                $"GIT_TOKEN={_options.GitToken}",
                $"WORKSPACE_BRANCH={SandboxRequest.NormalizeBranch(request.Branch)}",
            ],
            // No Cmd: the image ENTRYPOINT (/entrypoint.sh) already runs by itself.
            HostConfig = new HostConfig
            {
                CapDrop = ["ALL"],
                SecurityOpt = ["no-new-privileges"],
                Memory = MemoryBytes,
                NanoCPUs = NanoCpusForTwoCores,
                PidsLimit = PidsLimit,
                NetworkMode = _options.NetworkName,
                RestartPolicy = new RestartPolicy { Name = RestartPolicyKind.No },
            },
        };

        var created = await _client.Containers.CreateContainerAsync(create, ct);
        try
        {
            await _client.Containers.StartContainerAsync(created.ID, new ContainerStartParameters(), ct);
        }
        catch (Exception ex)
        {
            // The container exists but never became manageable: the caller only learns
            // the identity on success, so an unstarted container would be orphaned with
            // no API path to it. Remove it here while the id is still known.
            _logger.LogWarning(ex, "Container {ContainerId} failed to start; removing it to avoid an orphan.", created.ID);
            try
            {
                await _client.Containers.RemoveContainerAsync(
                    created.ID,
                    new ContainerRemoveParameters { Force = true, RemoveVolumes = true },
                    CancellationToken.None);
            }
            catch (Exception removeEx)
            {
                _logger.LogError(removeEx, "Cleanup of unstarted container {ContainerId} failed; remove it manually.", created.ID);
            }

            throw;
        }

        await TrySeedAsync(created.ID, ct);

        var now = DateTimeOffset.UtcNow;
        return new SandboxInfo(name, created.ID, SandboxState.Running, now, now + _options.DefaultTtl, name);
    }

    public async Task<SandboxStatus> GetStatusAsync(string sandboxId, CancellationToken ct)
    {
        ContainerInspectResponse inspect;
        try
        {
            inspect = await _client.Containers.InspectContainerAsync(sandboxId, ct);
        }
        catch (DockerContainerNotFoundException ex)
        {
            // The sandbox is gone; that is still a reportable status.
            return new SandboxStatus(
                new SandboxInfo(sandboxId, sandboxId, SandboxState.Removed, DateTimeOffset.UtcNow, null, sandboxId),
                ex.Message);
        }

        var createdAt = new DateTimeOffset(DateTime.SpecifyKind(inspect.Created, DateTimeKind.Utc));
        var info = new SandboxInfo(
            sandboxId,
            inspect.ID,
            MapState(inspect.State?.Status),
            createdAt,
            createdAt + _options.DefaultTtl,
            string.IsNullOrEmpty(inspect.Name) ? sandboxId : inspect.Name.TrimStart('/'));
        return new SandboxStatus(info, string.IsNullOrEmpty(inspect.State?.Error) ? null : inspect.State.Error);
    }

    public async Task<string> GetLogsAsync(string sandboxId, int tail, CancellationToken ct)
    {
        var logs = new StringBuilder();
        await _client.Containers.GetContainerLogsAsync(
            sandboxId,
            new ContainerLogsParameters
            {
                ShowStdout = true,
                ShowStderr = true,
                Tail = tail.ToString(CultureInfo.InvariantCulture),
            },
            new SyncProgress(value => logs.Append(value)),
            ct);
        return logs.ToString();
    }

    public async Task StopAsync(string sandboxId, CancellationToken ct)
    {
        try
        {
            await _client.Containers.StopContainerAsync(
                sandboxId,
                new ContainerStopParameters { WaitBeforeKillSeconds = StopTimeoutSeconds },
                ct);
        }
        catch (DockerContainerNotFoundException)
        {
            _logger.LogDebug("sandbox container {SandboxId} already gone on stop", sandboxId);
        }
    }

    public async Task RemoveAsync(string sandboxId, CancellationToken ct)
    {
        try
        {
            await _client.Containers.RemoveContainerAsync(
                sandboxId,
                new ContainerRemoveParameters { Force = true, RemoveVolumes = true },
                ct);
        }
        catch (DockerContainerNotFoundException)
        {
            _logger.LogDebug("sandbox container {SandboxId} already gone on remove", sandboxId);
        }
    }

    private static SandboxState MapState(string? status) => status switch
    {
        "created" => SandboxState.Creating,
        "running" => SandboxState.Running,
        "restarting" => SandboxState.Stopping,
        "paused" or "exited" => SandboxState.Stopped,
        "removing" => SandboxState.Removed,
        _ => SandboxState.Faulted,
    };

    /// <summary>
    /// Best-effort upload of the zcode server seed into the running container.
    /// Provisioning never fails on a missing or broken seed — the desktop provisions it on first connect.
    /// </summary>
    private async Task TrySeedAsync(string containerId, CancellationToken ct)
    {
        var seedPath = _options.SeedSourcePath;
        if (string.IsNullOrWhiteSpace(seedPath)
            || !Directory.Exists(seedPath)
            || !File.Exists(Path.Combine(seedPath, "zcode-server.cjs"))
            || !File.Exists(Path.Combine(seedPath, "node")))
        {
            _logger.LogInformation(
                "zcode server seed not available at {Path}; desktop will provision on first connect",
                seedPath);
            return;
        }

        try
        {
            var home = (await ExecInContainerAsync(
                containerId,
                ["sh", "-lc", "printf %s \"$HOME\""],
                ct)).Trim();
            var target = $"{home}/.zcode/server";
            // The image deliberately ships no ~/.zcode and PutArchive 404s when the
            // destination is missing, so create it before the upload.
            await ExecInContainerAsync(containerId, ["sh", "-lc", $"mkdir -p {target}"], ct);
            await UploadSeedAsync(containerId, seedPath, target, ct);
            await ExecInContainerAsync(
                containerId,
                ["sh", "-lc", $"chown -R {_options.ContainerUser} {target} && chmod +x {target}/zcode-server.cjs {target}/node"],
                ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(
                ex,
                "zcode server seed injection failed for container {ContainerId}; desktop will provision on first connect",
                containerId);
        }
    }

    private async Task UploadSeedAsync(string containerId, string seedPath, string targetPath, CancellationToken ct)
    {
        using var tar = new MemoryStream();
        using (var writer = new TarWriter(tar, TarEntryFormat.Ustar, leaveOpen: true))
        {
            foreach (var file in Directory.EnumerateFiles(seedPath, "*", SearchOption.AllDirectories))
            {
                var entry = new UstarTarEntry(TarEntryType.RegularFile, Path.GetRelativePath(seedPath, file).Replace('\\', '/'));
                entry.Mode = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute
                    | UnixFileMode.GroupRead | UnixFileMode.GroupExecute
                    | UnixFileMode.OtherRead | UnixFileMode.OtherExecute; // 0755 so executables survive the upload
                using var stream = File.OpenRead(file);
                entry.DataStream = stream;
                writer.WriteEntry(entry);
            }
        }

        tar.Position = 0;
        await _client.Containers.ExtractArchiveToContainerAsync(
            containerId,
            new CopyToContainerParameters { Path = targetPath },
            tar,
            ct);
    }

    private async Task<string> ExecInContainerAsync(string containerId, string[] cmd, CancellationToken ct)
    {
        var exec = await _client.Exec.CreateContainerExecAsync(
            containerId,
            new ContainerExecCreateParameters
            {
                Cmd = cmd,
                AttachStdout = true,
                AttachStderr = true,
            },
            ct);
        var stream = await _client.Exec.StartContainerExecAsync(exec.ID, new ContainerExecStartParameters(), ct);
        if (stream is null)
        {
            return string.Empty;
        }

        using (stream)
        {
            var (stdout, stderr) = await stream.ReadOutputToEndAsync(ct);
            return stdout + stderr;
        }
    }

    /// <summary>Collects log chunks synchronously in arrival order (Progress&lt;T&gt; would post asynchronously).</summary>
    private sealed class SyncProgress(Action<string> onReport) : IProgress<string>
    {
        public void Report(string value) => onReport(value);
    }
}
