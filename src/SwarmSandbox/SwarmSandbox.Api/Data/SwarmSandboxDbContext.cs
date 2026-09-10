using Microsoft.EntityFrameworkCore;

namespace SwarmSandbox.Api.Data;

/// <summary>EF Core store for sandboxes (PostgreSQL via Npgsql).</summary>
public class SwarmSandboxDbContext(DbContextOptions<SwarmSandboxDbContext> options) : DbContext(options)
{
    public DbSet<SandboxRecord> Sandboxes => Set<SandboxRecord>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<SandboxRecord>(entity =>
        {
            entity.HasKey(s => s.Id);
            entity.Property(s => s.Id).HasMaxLength(64);
            entity.Property(s => s.ContainerId).HasMaxLength(128);
            entity.Property(s => s.ContainerName).HasMaxLength(256);
            entity.Property(s => s.Branch).HasMaxLength(256);
            entity.Property(s => s.LastError);
        });
    }
}
