using SwarmSandbox.Api.Contracts;

namespace SwarmSandbox.Api.Services;

/// <summary>Composes sandbox lifecycle: persistence + Docker provisioning + TTL.</summary>
public interface ISandboxManager
{
    /// <summary>Persists a Creating record, provisions via <see cref="ISandboxProvisioner"/>, then marks Running.
    /// Throws <see cref="SandboxProvisioningException"/> (record marked Faulted) on provisioning failure.</summary>
    Task<SandboxInfo> CreateSandboxAsync(SandboxRequest request, CancellationToken ct);

    Task<IReadOnlyList<SandboxInfo>> ListAsync(CancellationToken ct);

    /// <summary>Live provisioner status merged with the persisted record; null when the id is unknown.</summary>
    Task<SandboxStatus?> GetStatusAsync(string id, CancellationToken ct);

    /// <summary>Removes via the provisioner and marks the record Removed (row kept for audit); false if unknown.</summary>
    Task<bool> DeleteAsync(string id, CancellationToken ct);
}
