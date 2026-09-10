namespace SwarmSandbox.Api.Provisioning;

using System.Text.RegularExpressions;

/// <summary>
/// Sandbox provisioning configuration, bound from the "Sandbox" configuration section
/// (AppHost passes it as SANDBOX__* environment variables).
/// </summary>
public sealed class SandboxOptions
{
    public const string SectionName = "Sandbox";

    public string DockerHost { get; set; } = "unix:///var/run/docker.sock";

    public string ImageName { get; set; } = "swarmsandbox-workspace:latest";

    /// <summary>Host directory containing the zcode server runtime to inject (zcode-server.cjs + node). Optional accelerator.</summary>
    public string? SeedSourcePath { get; set; } = "/opt/ZCode/resources";

    public string RepoUrl { get; set; } = "https://github.com/nam20485/swarm-context.git";

    public string GitToken { get; set; } = string.Empty;

    public string WorkspaceBranch { get; set; } = "development";

    public TimeSpan DefaultTtl { get; set; } = TimeSpan.FromHours(1);

    /// <summary>Docker network the sandbox containers are attached to.</summary>
    public string NetworkName { get; set; } = "swarmsandbox";

    /// <summary>uid:gid of the user the container runs as (used for chown after seed upload).</summary>
    public string ContainerUser { get; set; } = "1000:1000";

    /// <summary>
    /// Throws when <see cref="ContainerUser"/> is not numeric "uid:gid": the value is
    /// interpolated into a container exec command, so anything else is a command-injection
    /// hole. Called by the provisioner before first use.
    /// </summary>
    public void Validate()
    {
        if (!Regex.IsMatch(ContainerUser, @"^[0-9]+:[0-9]+$"))
        {
            throw new InvalidOperationException(
                $"Sandbox:ContainerUser '{ContainerUser}' must be numeric 'uid:gid' (matches '^<uid>:<gid>'); got a value that would be interpolated unsafely into a container exec command.");
        }
    }
}
