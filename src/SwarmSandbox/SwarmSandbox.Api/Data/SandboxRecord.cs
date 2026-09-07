using SwarmSandbox.Api.Contracts;

namespace SwarmSandbox.Api.Data;

/// <summary>Persisted row for a provisioned sandbox container.</summary>
public class SandboxRecord
{
    public string Id { get; set; } = string.Empty;

    public string ContainerId { get; set; } = string.Empty;

    public string ContainerName { get; set; } = string.Empty;

    public SandboxState State { get; set; }

    public string Branch { get; set; } = string.Empty;

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset? ExpiresAt { get; set; }

    public string? LastError { get; set; }
}
