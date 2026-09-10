namespace SwarmSandbox.Tests;

public class SolutionStructureTests
{
    public static TheoryData<string> ExpectedProjects => new()
    {
        "SwarmSandbox.AppHost/SwarmSandbox.AppHost.csproj",
        "SwarmSandbox.ServiceDefaults/SwarmSandbox.ServiceDefaults.csproj",
        "SwarmSandbox.Api/SwarmSandbox.Api.csproj",
        "SwarmSandbox.Web/SwarmSandbox.Web.csproj",
        "SwarmSandbox.Tests/SwarmSandbox.Tests.csproj",
    };

    [Theory]
    [MemberData(nameof(ExpectedProjects))]
    public void SolutionListsProject(string projectPath)
    {
        var slnText = File.ReadAllText(FindSolutionFile());
        Assert.Contains(projectPath, slnText.Replace('\\', '/'));
    }

    private static string FindSolutionFile()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "SwarmSandbox.sln");
            if (File.Exists(candidate))
            {
                return candidate;
            }

            dir = dir.Parent;
        }

        throw new InvalidOperationException("SwarmSandbox.sln not found above the test output directory.");
    }
}
