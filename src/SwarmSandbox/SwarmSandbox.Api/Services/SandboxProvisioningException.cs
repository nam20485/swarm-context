namespace SwarmSandbox.Api.Services;

/// <summary>Thrown when provisioning a sandbox fails; the record is marked Faulted with the cause.</summary>
public sealed class SandboxProvisioningException(string sandboxId, Exception innerException)
    : Exception($"Provisioning of sandbox '{sandboxId}' failed.", innerException)
{
    public string SandboxId { get; } = sandboxId;
}
