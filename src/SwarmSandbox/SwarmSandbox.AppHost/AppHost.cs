var builder = DistributedApplication.CreateBuilder(args);

// Parameters (defaults live in appsettings.json under "Parameters"; git-token is secret, supply
// via user secrets / Parameters__gitToken).
var dockerHost = builder.AddParameter("dockerHost");
var imageName = builder.AddParameter("imageName");
var seedSourcePath = builder.AddParameter("seedSourcePath");
var repoUrl = builder.AddParameter("repoUrl");
var gitToken = builder.AddParameter("gitToken", secret: true);
var workspaceBranch = builder.AddParameter("workspaceBranch");
var defaultTtl = builder.AddParameter("defaultTtl");

var postgres = builder.AddPostgres("postgres");

var api = builder.AddProject<Projects.SwarmSandbox_Api>("api")
    .WithReference(postgres)
    .WaitFor(postgres)
    .WithEnvironment("SANDBOX__DOCKERHOST", dockerHost)
    .WithEnvironment("SANDBOX__IMAGENAME", imageName)
    .WithEnvironment("SANDBOX__SEEDSOURCEPATH", seedSourcePath)
    .WithEnvironment("SANDBOX__REPOURL", repoUrl)
    .WithEnvironment("SANDBOX__GITTOKEN", gitToken)
    .WithEnvironment("SANDBOX__WORKSPACEBRANCH", workspaceBranch)
    .WithEnvironment("SANDBOX__DEFAULTTTL", defaultTtl);

builder.AddProject<Projects.SwarmSandbox_Web>("web")
    .WithEnvironment("SANDBOX_API_URL", api.GetEndpoint("https"));

builder.Build().Run();
