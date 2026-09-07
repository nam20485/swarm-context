using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.EntityFrameworkCore;
using SwarmSandbox.Api.Contracts;
using SwarmSandbox.Api.Data;
using SwarmSandbox.Api.Endpoints;
using SwarmSandbox.Api.Provisioning;
using SwarmSandbox.Api.Services;

var builder = WebApplication.CreateBuilder(args);

builder.AddServiceDefaults();

// Wire format: enums as camelCase strings (matches SwarmSandbox.Web's SandboxApiClient).
builder.Services.ConfigureHttpJsonOptions(options =>
    options.SerializerOptions.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase)));

// Provisioning failures become 502 ProblemDetails; everything else stays unhandled.
builder.Services.AddProblemDetails();
builder.Services.AddExceptionHandler<ProvisioningExceptionHandler>();

// Sandbox configuration (SANDBOX__* environment variables passed by the AppHost).
builder.Services.Configure<SandboxOptions>(builder.Configuration.GetSection(SandboxOptions.SectionName));
builder.Services.Configure<ReaperOptions>(builder.Configuration.GetSection("Sandbox"));
builder.Services.AddSingleton(TimeProvider.System);

builder.Services.AddDbContext<SwarmSandboxDbContext>(options =>
{
    // Aspire injects the Postgres connection string as ConnectionStrings:postgres;
    // non-Aspire runs configure ConnectionStrings:swarmsandbox instead.
    var connectionString = builder.Configuration.GetConnectionString("postgres")
        ?? builder.Configuration.GetConnectionString("swarmsandbox")
        ?? throw new InvalidOperationException(
            "No Postgres connection string configured (expected 'ConnectionStrings:postgres' or 'ConnectionStrings:swarmsandbox').");
    options.UseNpgsql(connectionString);
});

builder.Services.AddScoped<ISandboxStore, EfSandboxStore>();
builder.Services.AddSingleton<ISandboxProvisioner, DockerSandboxProvisioner>();
builder.Services.AddScoped<ISandboxManager, SandboxManager>();
builder.Services.AddHostedService<SandboxReaper>();

var app = builder.Build();

app.UseExceptionHandler();

// Dev-grade schema bootstrap (Simplicity First): create the database and schema on
// startup so a first run against a fresh Postgres does not 500 on every request.
// EF migrations are the intended production follow-up (see ARCHITECTURE.md).
using (var scope = app.Services.CreateScope())
{
    try
    {
        await scope.ServiceProvider.GetRequiredService<SwarmSandboxDbContext>().Database.EnsureCreatedAsync();
    }
    catch (Exception ex)
    {
        app.Logger.LogWarning(
            ex,
            "Database schema creation failed; continuing (requests may fail until the database is reachable).");
    }
}

app.MapDefaultEndpoints();

app.MapSandboxEndpoints();

app.Run();

// Exposed for WebApplicationFactory-based integration tests (SwarmSandbox.Tests).
public partial class Program { }
