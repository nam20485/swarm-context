using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using SwarmSandbox.Api.Contracts;
using SwarmSandbox.Api.Data;

namespace SwarmSandbox.Api.Services;

/// <summary>
/// Background loop that stops/removes sandboxes whose TTL expired (Running or Faulted past ExpiresAt)
/// and marks them Removed. Per-item failures are logged and the loop keeps ticking.
/// </summary>
public sealed class SandboxReaper(
    IServiceScopeFactory scopeFactory,
    IOptions<ReaperOptions> options,
    TimeProvider timeProvider,
    ILogger<SandboxReaper> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var interval = options.Value.ReapInterval;
        if (interval <= TimeSpan.Zero)
        {
            interval = TimeSpan.FromMinutes(1);
        }

        using var timer = new PeriodicTimer(interval, timeProvider);
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await ReapOnceAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Sandbox reap pass failed; retrying next tick.");
            }

            try
            {
                await timer.WaitForNextTickAsync(stoppingToken);
            }
            catch (OperationCanceledException)
            {
            }
        }
    }

    /// <summary>Runs a single reap pass (one scope, one store query). Public for unit testing.</summary>
    public async Task ReapOnceAsync(CancellationToken ct)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var store = scope.ServiceProvider.GetRequiredService<ISandboxStore>();
        var provisioner = scope.ServiceProvider.GetRequiredService<ISandboxProvisioner>();

        var expired = await store.FindExpiredAsync(timeProvider.GetUtcNow(), ct);
        foreach (var record in expired)
        {
            try
            {
                // Address the provisioner by container identity (name, falling back to
                // the recorded container id) — the record id is not a Docker identity.
                var containerIdentity = ContainerIdentity(record);
                await provisioner.StopAsync(containerIdentity, ct);
                await provisioner.RemoveAsync(containerIdentity, ct);
                record.State = SandboxState.Removed;
                await store.UpdateAsync(record, ct);
                logger.LogInformation("Reaped expired sandbox {SandboxId} (state {State}).", record.Id, record.State);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Failed to reap expired sandbox {SandboxId}; will retry next tick.", record.Id);
            }
        }
    }

    private static string ContainerIdentity(SandboxRecord record) =>
        !string.IsNullOrEmpty(record.ContainerName) ? record.ContainerName
        : !string.IsNullOrEmpty(record.ContainerId) ? record.ContainerId
        : record.Id;
}
