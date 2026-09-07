namespace SwarmSandbox.Api.Contracts;

/// <summary>
/// Provisions and manages Docker sandbox containers (M1 owns the implementation in Api/Provisioning/).
/// </summary>
public interface ISandboxProvisioner
{
    Task<SandboxInfo> CreateSandboxAsync(SandboxRequest request, CancellationToken ct);

    Task<SandboxStatus> GetStatusAsync(string sandboxId, CancellationToken ct);

    Task<string> GetLogsAsync(string sandboxId, int tail, CancellationToken ct);

    Task StopAsync(string sandboxId, CancellationToken ct);

    Task RemoveAsync(string sandboxId, CancellationToken ct);
}
