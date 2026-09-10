using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using NSubstitute;
using SwarmSandbox.Api.Contracts;
using SwarmSandbox.Api.Data;
using SwarmSandbox.Api.Services;

namespace SwarmSandbox.Tests.Services;

public class SandboxReaperTests
{
    private static readonly DateTimeOffset Now = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    [Fact]
    public async Task ReapOnceReapsOnlyExpiredCreatingRunningOrFaultedRowsAndMarksThemRemoved()
    {
        var store = new InMemorySandboxStore();
        var expiredRunning = Row("expired-running", SandboxState.Running, Now.AddHours(-1));
        var expiredFaulted = Row("expired-faulted", SandboxState.Faulted, Now.AddHours(-2));
        // A Creating row past its expiry is stranded provisioning (client abort or
        // crash between insert and the Running update) — it must expire out too.
        var strandedCreating = Row("stranded-creating", SandboxState.Creating, Now.AddHours(-1));
        var fresh = Row("fresh", SandboxState.Running, Now.AddHours(1));
        store.Seed(expiredRunning, expiredFaulted, strandedCreating, fresh);

        var provisioner = Substitute.For<ISandboxProvisioner>();
        var reaper = CreateReaper(store, provisioner);

        await reaper.ReapOnceAsync(CancellationToken.None);

        // P0 regression guard: the reaper addresses the provisioner by container
        // identity (ContainerName = "sbx-{recordId}" per Row()), never the record id.
        await provisioner.Received(1).StopAsync("sbx-expired-running", Arg.Any<CancellationToken>());
        await provisioner.Received(1).RemoveAsync("sbx-expired-running", Arg.Any<CancellationToken>());
        await provisioner.Received(1).StopAsync("sbx-expired-faulted", Arg.Any<CancellationToken>());
        await provisioner.Received(1).RemoveAsync("sbx-expired-faulted", Arg.Any<CancellationToken>());
        await provisioner.Received(1).RemoveAsync("sbx-stranded-creating", Arg.Any<CancellationToken>());
        await provisioner.DidNotReceive().StopAsync("sbx-fresh", Arg.Any<CancellationToken>());
        await provisioner.DidNotReceive().RemoveAsync("sbx-fresh", Arg.Any<CancellationToken>());

        Assert.Equal(SandboxState.Removed, store.Find("expired-running")!.State);
        Assert.Equal(SandboxState.Removed, store.Find("expired-faulted")!.State);
        Assert.Equal(SandboxState.Removed, store.Find("stranded-creating")!.State);
        Assert.Equal(SandboxState.Running, store.Find("fresh")!.State);
    }

    [Fact]
    public async Task ReapOnceSurvivesPerItemExceptionsAndKeepsReapingOthers()
    {
        var store = new InMemorySandboxStore();
        store.Seed(
            Row("bad", SandboxState.Running, Now.AddHours(-1)),
            Row("good", SandboxState.Running, Now.AddHours(-1)));

        var provisioner = Substitute.For<ISandboxProvisioner>();
        provisioner
            .StopAsync("sbx-bad", Arg.Any<CancellationToken>())
            .Returns(Task.FromException(new InvalidOperationException("docker exploded")));
        var reaper = CreateReaper(store, provisioner);

        await reaper.ReapOnceAsync(CancellationToken.None);

        await provisioner.Received(1).RemoveAsync("sbx-good", Arg.Any<CancellationToken>());
        Assert.Equal(SandboxState.Removed, store.Find("good")!.State);
        Assert.Equal(SandboxState.Running, store.Find("bad")!.State);
    }

    [Fact]
    public async Task ExecuteAsync_reaps_on_every_tick_until_stopped()
    {
        var store = new InMemorySandboxStore();
        store.Seed(Row("expired", SandboxState.Running, Now.AddHours(-1)));
        var provisioner = Substitute.For<ISandboxProvisioner>();
        var reaper = new SandboxReaper(
            ScopeFactory(store, provisioner),
            Options.Create(new ReaperOptions { ReapInterval = TimeSpan.FromMilliseconds(25) }),
            new FixedTimeProvider(Now),
            NullLogger<SandboxReaper>.Instance);

        using var cts = new CancellationTokenSource();
        await reaper.StartAsync(cts.Token);
        await WaitUntilAsync(() => store.Find("expired")!.State == SandboxState.Removed, TimeSpan.FromSeconds(5));
        await provisioner.Received(1).StopAsync("sbx-expired", Arg.Any<CancellationToken>());

        cts.Cancel();
        await reaper.StopAsync(new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);
    }

    [Fact]
    public async Task ExecuteAsync_falls_back_to_the_default_interval_and_survives_store_failures()
    {
        var store = Substitute.For<ISandboxStore>();
        var findExpiredCalls = 0;
        store
            .FindExpiredAsync(Arg.Any<DateTimeOffset>(), Arg.Any<CancellationToken>())
            .Returns(ci =>
            {
                findExpiredCalls++;
                return Task.FromException<IReadOnlyList<SandboxRecord>>(new InvalidOperationException("db down"));
            });
        var provisioner = Substitute.For<ISandboxProvisioner>();
        var reaper = new SandboxReaper(
            ScopeFactory(store, provisioner),
            Options.Create(new ReaperOptions { ReapInterval = TimeSpan.Zero }),
            new FixedTimeProvider(Now),
            NullLogger<SandboxReaper>.Instance);

        using var cts = new CancellationTokenSource();
        await reaper.StartAsync(cts.Token);
        // The first reap pass can land on a pool thread under load; wait for it
        // deterministically instead of asserting immediately after StartAsync.
        await WaitUntilAsync(() => findExpiredCalls > 0, TimeSpan.FromSeconds(5));
        await store.Received(1).FindExpiredAsync(Arg.Any<DateTimeOffset>(), Arg.Any<CancellationToken>());

        cts.Cancel();
        await reaper.StopAsync(new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);

        await provisioner.DidNotReceive().StopAsync(Arg.Any<string>(), Arg.Any<CancellationToken>());
    }

    private static IServiceScopeFactory ScopeFactory(ISandboxStore store, ISandboxProvisioner provisioner)
    {
        var services = new ServiceCollection();
        services.AddSingleton(store);
        services.AddSingleton(provisioner);
        return services.BuildServiceProvider().GetRequiredService<IServiceScopeFactory>();
    }

    private static async Task WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (!condition() && DateTime.UtcNow < deadline)
        {
            await Task.Delay(10);
        }

        Assert.True(condition());
    }

    private static SandboxReaper CreateReaper(InMemorySandboxStore store, ISandboxProvisioner provisioner)
    {
        var services = new ServiceCollection();
        services.AddSingleton<ISandboxStore>(store);
        services.AddSingleton<ISandboxProvisioner>(provisioner);
        var provider = services.BuildServiceProvider();

        return new SandboxReaper(
            provider.GetRequiredService<IServiceScopeFactory>(),
            Options.Create(new ReaperOptions()),
            new FixedTimeProvider(Now),
            NullLogger<SandboxReaper>.Instance);
    }

    private static SandboxRecord Row(string id, SandboxState state, DateTimeOffset expiresAt) => new()
    {
        Id = id,
        ContainerId = $"cid-{id}",
        ContainerName = $"sbx-{id}",
        State = state,
        Branch = SandboxRequest.DefaultBranch,
        CreatedAt = Now.AddHours(-2),
        ExpiresAt = expiresAt,
    };
}
