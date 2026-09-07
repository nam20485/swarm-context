using Microsoft.EntityFrameworkCore;
using SwarmSandbox.Api.Contracts;
using SwarmSandbox.Api.Data;

namespace SwarmSandbox.Api.Services;

/// <summary>EF Core-backed sandbox store (PostgreSQL via Npgsql).</summary>
public class EfSandboxStore(SwarmSandboxDbContext db) : ISandboxStore
{
    public async Task AddAsync(SandboxRecord record, CancellationToken ct)
    {
        db.Sandboxes.Add(record);
        await db.SaveChangesAsync(ct);
    }

    public Task<SandboxRecord?> FindAsync(string id, CancellationToken ct) =>
        db.Sandboxes.FirstOrDefaultAsync(s => s.Id == id, ct);

    public async Task<IReadOnlyList<SandboxRecord>> ListAsync(CancellationToken ct) =>
        await db.Sandboxes.AsNoTracking().OrderBy(s => s.CreatedAt).ToListAsync(ct);

    public async Task UpdateAsync(SandboxRecord record, CancellationToken ct)
    {
        db.Sandboxes.Update(record);
        await db.SaveChangesAsync(ct);
    }

    public async Task<IReadOnlyList<SandboxRecord>> FindExpiredAsync(DateTimeOffset now, CancellationToken ct) =>
        await db.Sandboxes
            .Where(s => (s.State == SandboxState.Running || s.State == SandboxState.Faulted)
                        && s.ExpiresAt != null && s.ExpiresAt <= now)
            .ToListAsync(ct);
}
