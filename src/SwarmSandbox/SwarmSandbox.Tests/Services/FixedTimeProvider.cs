namespace SwarmSandbox.Tests.Services;

/// <summary>Deterministic clock for tests.</summary>
internal sealed class FixedTimeProvider(DateTimeOffset utcNow) : TimeProvider
{
    public override DateTimeOffset GetUtcNow() => utcNow;
}
