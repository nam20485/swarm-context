using Microsoft.EntityFrameworkCore;
using SwarmSandbox.Api.Contracts;
using SwarmSandbox.Api.Data;
using SwarmSandbox.Api.Services;
using Xunit;

namespace SwarmSandbox.Tests.Services;

/// <summary>EfSandboxStore behavior against the EF Core InMemory provider (no Postgres needed).</summary>
public class EfSandboxStoreTests : IDisposable
{
    private static readonly DateTimeOffset Now = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private readonly SwarmSandboxDbContext _db = new(
        new DbContextOptionsBuilder<SwarmSandboxDbContext>()
            .UseInMemoryDatabase($"swarmsandbox-tests-{Guid.NewGuid()}")
            .Options);

    private readonly EfSandboxStore _store;

    public EfSandboxStoreTests() => _store = new EfSandboxStore(_db);

    [Fact]
    public async Task Add_then_Find_roundtrips_a_record()
    {
        var record = Row("dev-1", SandboxState.Running);

        await _store.AddAsync(record, CancellationToken.None);

        var found = await _store.FindAsync("dev-1", CancellationToken.None);
        Assert.NotNull(found);
        Assert.Equal("dev-1", found.Id);
        Assert.Equal("sbx-dev-1", found.ContainerName);
        Assert.Equal(SandboxState.Running, found.State);
    }

    [Fact]
    public async Task Find_returns_null_for_an_unknown_id()
    {
        Assert.Null(await _store.FindAsync("nope", CancellationToken.None));
    }

    [Fact]
    public async Task Update_persists_changes_to_an_existing_row()
    {
        var record = Row("dev-1", SandboxState.Creating);
        await _store.AddAsync(record, CancellationToken.None);

        record.State = SandboxState.Running;
        await _store.UpdateAsync(record, CancellationToken.None);

        var found = await _store.FindAsync("dev-1", CancellationToken.None);
        Assert.Equal(SandboxState.Running, found!.State);
    }

    [Fact]
    public async Task List_orders_rows_by_CreatedAt()
    {
        var second = Row("second", SandboxState.Running);
        second.CreatedAt = Now.AddMinutes(2);
        var first = Row("first", SandboxState.Running);
        first.CreatedAt = Now;
        await _store.AddAsync(second, CancellationToken.None);
        await _store.AddAsync(first, CancellationToken.None);

        var list = await _store.ListAsync(CancellationToken.None);

        Assert.Equal(new[] { "first", "second" }, list.Select(r => r.Id).ToArray());
    }

    [Fact]
    public async Task FindExpired_returns_only_expired_running_or_faulted_rows()
    {
        await _store.AddAsync(Row("expired-running", SandboxState.Running, expiresAt: Now.AddMinutes(-5)), CancellationToken.None);
        await _store.AddAsync(Row("expired-faulted", SandboxState.Faulted, expiresAt: Now.AddMinutes(-1)), CancellationToken.None);
        await _store.AddAsync(Row("future", SandboxState.Running, expiresAt: Now.AddMinutes(30)), CancellationToken.None);
        await _store.AddAsync(Row("stopped", SandboxState.Stopped, expiresAt: Now.AddMinutes(-30)), CancellationToken.None);
        await _store.AddAsync(Row("no-expiry", SandboxState.Running, expiresAt: null), CancellationToken.None);

        var expired = await _store.FindExpiredAsync(Now, CancellationToken.None);

        Assert.Equal(
            new[] { "expired-faulted", "expired-running" },
            expired.Select(r => r.Id).OrderBy(id => id).ToArray());
    }

    public void Dispose() => _db.Dispose();

    private static SandboxRecord Row(string id, SandboxState state, DateTimeOffset? expiresAt = null) => new()
    {
        Id = id,
        ContainerId = $"cid-{id}",
        ContainerName = $"sbx-{id}",
        State = state,
        Branch = SandboxRequest.DefaultBranch,
        CreatedAt = Now,
        ExpiresAt = expiresAt ?? Now.AddMinutes(30),
    };
}
