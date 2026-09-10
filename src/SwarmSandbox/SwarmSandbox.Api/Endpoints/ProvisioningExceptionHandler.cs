using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using SwarmSandbox.Api.Services;

namespace SwarmSandbox.Api.Endpoints;

/// <summary>
/// Maps <see cref="SandboxProvisioningException"/> (Docker unreachable, container create/start
/// failure, ...) to a 502 ProblemDetails response; all other exceptions stay unhandled.
/// </summary>
public sealed class ProvisioningExceptionHandler(
    IProblemDetailsService problemDetailsService,
    ILogger<ProvisioningExceptionHandler> logger) : IExceptionHandler
{
    public async ValueTask<bool> TryHandleAsync(HttpContext httpContext, Exception exception, CancellationToken cancellationToken)
    {
        if (exception is not SandboxProvisioningException failure)
        {
            return false;
        }

        logger.LogError(failure, "Sandbox provisioning failed for {SandboxId}.", failure.SandboxId);
        httpContext.Response.StatusCode = StatusCodes.Status502BadGateway;
        return await problemDetailsService.TryWriteAsync(new ProblemDetailsContext
        {
            HttpContext = httpContext,
            ProblemDetails = new ProblemDetails
            {
                Status = StatusCodes.Status502BadGateway,
                Title = "Sandbox provisioning failed.",
                Detail = failure.Message,
                Instance = httpContext.Request.Path,
            },
        });
    }
}
