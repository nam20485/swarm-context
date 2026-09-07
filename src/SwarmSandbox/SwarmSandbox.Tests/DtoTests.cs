using SwarmSandbox.Api.Contracts;

namespace SwarmSandbox.Tests;

public class DtoTests
{
    [Theory]
    [InlineData(null, "development")]
    [InlineData("", "development")]
    [InlineData("   ", "development")]
    [InlineData("main", "main")]
    [InlineData("feature/worker-wave", "feature/worker-wave")]
    public void NormalizeBranchDefaultsNullEmptyToDevelopment(string? branch, string expected)
    {
        Assert.Equal(expected, SandboxRequest.NormalizeBranch(branch));
    }
}
