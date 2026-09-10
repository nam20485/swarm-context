using SwarmSandbox.Api.Data;

namespace SwarmSandbox.Api.Services;

/// <summary>
/// Persistence seam for sandbox records: <see cref="EfSandboxStore"/> in production,
/// an in-memory fake in tests.
/// </summary>
public interface ISandboxStore
{
    Task AddAsync(SandboxRecord record, CancellationToken ct);

    Task<SandboxRecord?> FindAsync(string id, CancellationToken ct);

    Task<IReadOnlyList<SandboxRecord>> ListAsync(CancellationToken ct);

    Task UpdateAsync(SandboxRecord record, CancellationToken ct);

    /// <summary>Returns Creating/Running/Faulted records whose ExpiresAt is at or before <paramref name="now"/>
    /// (Creating included so rows stranded by an aborted or crashed provisioning call still expire).</summary>
    Task<IReadOnlyList<SandboxRecord>> FindExpiredAsync(DateTimeOffset now, CancellationToken ct);
}
