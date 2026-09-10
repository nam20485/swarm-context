namespace SwarmSandbox.Api.Contracts;

/// <summary>Request to create a sandbox for a repo branch.</summary>
public record SandboxRequest(string Branch)
{
    public const string DefaultBranch = "development";

    /// <summary>Returns the branch as-is, defaulting null/empty/whitespace to <see cref="DefaultBranch"/>.</summary>
    public static string NormalizeBranch(string? branch) =>
        string.IsNullOrWhiteSpace(branch) ? DefaultBranch : branch;
}

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
