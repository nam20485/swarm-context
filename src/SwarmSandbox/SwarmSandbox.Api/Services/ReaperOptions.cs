namespace SwarmSandbox.Api.Services;

/// <summary>
/// Reaper tick configuration, bound from the "Sandbox" configuration section
/// (key Sandbox:ReapInterval, e.g. SANDBOX__REAPINTERVAL).
///
/// Note: the sandbox TTL itself is NOT duplicated here — it comes from
/// SwarmSandbox.Api.Provisioning.SandboxOptions (M1-owned, same "Sandbox" section).
/// This class exists only because the reaper's tick interval is configurable and
/// Provisioning is owned concurrently by M1.
/// </summary>
public sealed class ReaperOptions
{
    /// <summary>How often the reaper scans for expired sandboxes (default 60s).</summary>
    public TimeSpan ReapInterval { get; set; } = TimeSpan.FromMinutes(1);
}
