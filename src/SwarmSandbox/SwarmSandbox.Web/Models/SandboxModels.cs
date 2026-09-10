namespace SwarmSandbox.Web.Models;

// DTOs duplicated from SwarmSandbox.Api/Contracts (Web must not reference the Api project).
// Owned by M4 (Blazor UI).

/// <summary>Request to create a sandbox for a repo branch.</summary>
public record SandboxRequest(string Branch);

/// <summary>Acknowledgement returned by <c>POST /api/sandboxes</c> (202).</summary>
public record CreateSandboxResponse(string SandboxId, string Branch, string? ContainerName);

/// <summary>Lifecycle state of a sandbox container.</summary>
public enum SandboxState
{
    Creating,
    Running,
    Stopping,
    Stopped,
    Faulted,
    Removed
}

/// <summary>Facts about a provisioned sandbox.</summary>
public record SandboxInfo(
    string Id,
    string ContainerId,
    SandboxState State,
    DateTimeOffset CreatedAt,
    DateTimeOffset? ExpiresAt,
    string ContainerName);

/// <summary>Health snapshot of a sandbox.</summary>
public record SandboxStatus(SandboxInfo Info, string? LastError);
