using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using NSubstitute;
using SwarmSandbox.Api.Contracts;
using SwarmSandbox.Api.Data;
using SwarmSandbox.Api.Provisioning;
using SwarmSandbox.Api.Services;

namespace SwarmSandbox.Tests.Services;

public class SandboxManagerTests
{
    private static readonly DateTimeOffset Now = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private readonly InMemorySandboxStore _store = new();
    private readonly ISandboxProvisioner _provisioner = Substitute.For<ISandboxProvisioner>();
    private readonly SandboxManager _manager;

    public SandboxManagerTests()
    {
        _manager = new SandboxManager(
            _store,
            _provisioner,
            Options.Create(new SandboxOptions { DefaultTtl = TimeSpan.FromMinutes(30) }),
            new FixedTimeProvider(Now));
    }

    [Fact]
    public async Task CreatePersistsCreatingThenRunningWithNormalizedBranchAndTtl()
    {
        SandboxState? stateDuringProvisioning = null;
        _provisioner
            .CreateSandboxAsync(Arg.Any<SandboxRequest>(), Arg.Any<CancellationToken>())
            .Returns(callInfo =>
            {
                stateDuringProvisioning = _store.Rows.Single().State;
                return new SandboxInfo("ignored", "cid-123", SandboxState.Running, Now, Now.AddMinutes(30), "sbx-name");
            });

        var info = await _manager.CreateSandboxAsync(new SandboxRequest(null!), CancellationToken.None);

        Assert.Equal(SandboxState.Creating, stateDuringProvisioning);

        await _provisioner.Received(1).CreateSandboxAsync(
            Arg.Is<SandboxRequest>(r => r.Branch == SandboxRequest.DefaultBranch),
            Arg.Any<CancellationToken>());

        var record = _store.Rows.Single();
        Assert.NotEmpty(record.Id);
        Assert.Equal(SandboxState.Running, record.State);
        Assert.Equal(SandboxRequest.DefaultBranch, record.Branch);
        Assert.Equal(Now, record.CreatedAt);
        Assert.Equal(Now.AddMinutes(30), record.ExpiresAt);
        Assert.Equal("cid-123", record.ContainerId);
        Assert.Equal("sbx-name", record.ContainerName);

        Assert.Equal(record.Id, info.Id);
        Assert.Equal(SandboxState.Running, info.State);
        Assert.Equal("cid-123", info.ContainerId);
        Assert.Equal("sbx-name", info.ContainerName);
    }

    [Fact]
    public async Task CreateMarksFaultedWithLastErrorAndThrowsTypedExceptionOnProvisionerFailure()
    {
        var failure = new InvalidOperationException("docker down");
        _provisioner
            .CreateSandboxAsync(Arg.Any<SandboxRequest>(), Arg.Any<CancellationToken>())
            .Returns(Task.FromException<SandboxInfo>(failure));

        var exception = await Assert.ThrowsAsync<SandboxProvisioningException>(
            () => _manager.CreateSandboxAsync(new SandboxRequest("main"), CancellationToken.None));

        Assert.Equal(failure, exception.InnerException);

        var record = _store.Rows.Single();
        Assert.Equal(SandboxState.Faulted, record.State);
        Assert.Equal("docker down", record.LastError);
    }

    [Fact]
    public async Task GetStatusReturnsNullForUnknownId()
    {
        Assert.Null(await _manager.GetStatusAsync("nope", CancellationToken.None));
    }

    [Fact]
    public async Task GetStatusMergesLiveProvisionerStatusWithRecord()
    {
        _store.Seed(SeedRecord("sbx1", SandboxState.Running, expiresAt: Now.AddMinutes(30)));
        // P0 regression guard: the provisioner is addressed by the container identity
        // (ContainerName, falling back to ContainerId) — never the sandbox record id.
        _provisioner
            .GetStatusAsync("name-old", Arg.Any<CancellationToken>())
            .Returns(new SandboxStatus(
                new SandboxInfo("sbx1", "live-cid", SandboxState.Stopped, Now, null, "live-name"),
                "container exited"));

        var status = await _manager.GetStatusAsync("sbx1", CancellationToken.None);

        await _provisioner.Received(1).GetStatusAsync("name-old", Arg.Any<CancellationToken>());
        await _provisioner.DidNotReceive().GetStatusAsync("sbx1", Arg.Any<CancellationToken>());
        Assert.NotNull(status);
        Assert.Equal(SandboxState.Stopped, status.Info.State);
        Assert.Equal("live-cid", status.Info.ContainerId);
        Assert.Equal("live-name", status.Info.ContainerName);
        Assert.Equal(Now.AddMinutes(30), status.Info.ExpiresAt);
        Assert.Equal("container exited", status.LastError);
    }

    [Fact]
    public async Task DeleteRemovesViaProvisionerAndMarksRemovedKeepingRow()
    {
        _store.Seed(SeedRecord("sbx1", SandboxState.Running));

        var deleted = await _manager.DeleteAsync("sbx1", CancellationToken.None);

        Assert.True(deleted);
        // P0 regression guard: removal goes to the container identity, not the record id.
        await _provisioner.Received(1).RemoveAsync("name-old", Arg.Any<CancellationToken>());
        await _provisioner.DidNotReceive().RemoveAsync("sbx1", Arg.Any<CancellationToken>());
        var record = _store.Find("sbx1");
        Assert.NotNull(record);
        Assert.Equal(SandboxState.Removed, record.State);
    }

    [Fact]
    public async Task GetStatusAddressesProvisionerByContainerIdWhenNameMissing()
    {
        _store.Seed(new SandboxRecord
        {
            Id = "sbx2",
            ContainerId = "cid-only",
            ContainerName = "",
            State = SandboxState.Running,
            Branch = SandboxRequest.DefaultBranch,
            CreatedAt = Now,
            ExpiresAt = Now.AddMinutes(30),
        });
        _provisioner
            .GetStatusAsync("cid-only", Arg.Any<CancellationToken>())
            .Returns(new SandboxStatus(
                new SandboxInfo("sbx2", "cid-only", SandboxState.Running, Now, null, "cid-only"), null));

        await _manager.GetStatusAsync("sbx2", CancellationToken.None);

        await _provisioner.Received(1).GetStatusAsync("cid-only", Arg.Any<CancellationToken>());
        await _provisioner.DidNotReceive().GetStatusAsync("sbx2", Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task DeleteAddressesProvisionerByContainerIdWhenNameMissing()
    {
        _store.Seed(new SandboxRecord
        {
            Id = "sbx3",
            ContainerId = "cid-del",
            ContainerName = "",
            State = SandboxState.Running,
            Branch = SandboxRequest.DefaultBranch,
            CreatedAt = Now,
        });

        await _manager.DeleteAsync("sbx3", CancellationToken.None);

        await _provisioner.Received(1).RemoveAsync("cid-del", Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task DeleteUnknownIdReturnsFalseWithoutCallingProvisioner()
    {
        var deleted = await _manager.DeleteAsync("nope", CancellationToken.None);

        Assert.False(deleted);
        await _provisioner.DidNotReceiveWithAnyArgs().RemoveAsync(default!, default);
    }

    [Fact]
    public async Task GetStatusFallsBackToPersistedRecordWhenProvisionerThrows()
    {
        _store.Seed(SeedRecord("sbx1", SandboxState.Running, expiresAt: Now.AddMinutes(30)));
        _provisioner
            .GetStatusAsync(Arg.Any<string>(), Arg.Any<CancellationToken>())
            .Returns(Task.FromException<SandboxStatus>(new InvalidOperationException("docker unreachable")));

        var status = await _manager.GetStatusAsync("sbx1", CancellationToken.None);

        Assert.NotNull(status);
        Assert.Equal(SandboxState.Running, status.Info.State);
        Assert.Equal("cid-old", status.Info.ContainerId);
        Assert.Equal("name-old", status.Info.ContainerName);
        Assert.Equal(Now.AddMinutes(30), status.Info.ExpiresAt);
        Assert.Null(status.LastError);
    }

    [Fact]
    public async Task ListMapsPersistedRecordsToInfos()
    {
        _store.Seed(SeedRecord("a", SandboxState.Running), SeedRecord("b", SandboxState.Creating));

        var list = await _manager.ListAsync(CancellationToken.None);

        Assert.Equal(2, list.Count);
        Assert.Contains(list, info => info.Id == "a" && info.State == SandboxState.Running);
        Assert.Contains(list, info => info.Id == "b" && info.State == SandboxState.Creating);
    }

    private SandboxRecord SeedRecord(string id, SandboxState state, DateTimeOffset? expiresAt = null) =>
        new()
        {
            Id = id,
            ContainerId = "cid-old",
            ContainerName = "name-old",
            State = state,
            Branch = SandboxRequest.DefaultBranch,
            CreatedAt = Now,
            ExpiresAt = expiresAt,
        };
}
