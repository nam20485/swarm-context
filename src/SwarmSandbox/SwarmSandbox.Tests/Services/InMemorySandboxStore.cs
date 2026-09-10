using SwarmSandbox.Api.Contracts;
using SwarmSandbox.Api.Data;
using SwarmSandbox.Api.Services;

namespace SwarmSandbox.Tests.Services;

/// <summary>In-memory ISandboxStore fake so unit tests need no database.</summary>
internal sealed class InMemorySandboxStore : ISandboxStore
{
    private readonly Dictionary<string, SandboxRecord> _records = new();

    /// <summary>Snapshot of all rows, for assertions.</summary>
    public IReadOnlyCollection<SandboxRecord> Rows => _records.Values.ToArray();

    public SandboxRecord? Find(string id) => _records.GetValueOrDefault(id);

    public void Seed(params SandboxRecord[] records)
    {
        foreach (var record in records)
        {
            _records.Add(record.Id, record);
        }
    }

    public Task AddAsync(SandboxRecord record, CancellationToken ct)
    {
        _records.Add(record.Id, record);
        return Task.CompletedTask;
    }

    public Task<SandboxRecord?> FindAsync(string id, CancellationToken ct) =>
        Task.FromResult(_records.GetValueOrDefault(id));

    public Task<IReadOnlyList<SandboxRecord>> ListAsync(CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<SandboxRecord>>(_records.Values.ToList());

    public Task UpdateAsync(SandboxRecord record, CancellationToken ct)
    {
        _records[record.Id] = record;
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<SandboxRecord>> FindExpiredAsync(DateTimeOffset now, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<SandboxRecord>>(_records.Values
            .Where(r => r.ExpiresAt is { } expires && expires <= now &&
                        r.State is SandboxState.Creating or SandboxState.Running or SandboxState.Faulted)
            .ToList());
}
