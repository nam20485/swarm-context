using SwarmSandbox.Api.Contracts;
using SwarmSandbox.Api.Services;

namespace SwarmSandbox.Api.Endpoints;

/// <summary>Sandbox lifecycle endpoints backed by ISandboxManager (persistence + Docker provisioning).</summary>
public static class SandboxEndpoints
{
    public static IEndpointRouteBuilder MapSandboxEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapPost("/api/sandboxes", async (SandboxRequest? request, ISandboxManager manager, CancellationToken ct) =>
        {
            var branch = SandboxRequest.NormalizeBranch(request?.Branch);
            var info = await manager.CreateSandboxAsync(new SandboxRequest(branch), ct);
            return Results.Accepted(value: new { sandboxId = info.Id, branch, containerName = info.ContainerName });
        });

        app.MapGet("/api/sandboxes", async (ISandboxManager manager, CancellationToken ct) =>
            Results.Ok(await manager.ListAsync(ct)));

        app.MapGet("/api/sandboxes/{id}", async (string id, ISandboxManager manager, CancellationToken ct) =>
            await manager.GetStatusAsync(id, ct) is { } status
                ? Results.Ok(status)
                : Results.NotFound());

        app.MapDelete("/api/sandboxes/{id}", async (string id, ISandboxManager manager, CancellationToken ct) =>
            await manager.DeleteAsync(id, ct) ? Results.NoContent() : Results.NotFound());

        return app;
    }
}
