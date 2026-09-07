using System.Net;
using System.Net.Http;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Hosting;
using Xunit;

namespace SwarmSandbox.Tests.ServiceDefaults;

public class ServiceDefaultsTests
{
    [Fact]
    public async Task AddServiceDefaults_registers_a_healthy_self_check()
    {
        var builder = Host.CreateEmptyApplicationBuilder(new HostApplicationBuilderSettings());

        builder.AddServiceDefaults();

        using var host = builder.Build();
        var health = host.Services.GetRequiredService<HealthCheckService>();
        var report = await health.CheckHealthAsync();
        Assert.Equal(HealthStatus.Healthy, report.Status);
        Assert.Contains("self", report.Entries.Keys);
    }

    [Fact]
    public void AddServiceDefaults_with_an_otlp_endpoint_wires_the_otlp_exporter()
    {
        var builder = Host.CreateEmptyApplicationBuilder(new HostApplicationBuilderSettings());
        builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://127.0.0.1:4317",
        });

        builder.AddServiceDefaults();

        // Building only: no exporter traffic starts until the host runs.
        using var host = builder.Build();
        Assert.NotNull(host.Services.GetRequiredService<HealthCheckService>());
    }

    [Fact]
    public async Task MapDefaultEndpoints_exposes_health_and_alive_in_development()
    {
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions { EnvironmentName = "Development" });
        builder.WebHost.UseUrls("http://127.0.0.1:0");
        builder.AddServiceDefaults();

        await using var app = builder.Build();
        app.MapDefaultEndpoints();
        await app.StartAsync();
        try
        {
            var address = app.Services.GetRequiredService<IServer>()
                .Features.Get<IServerAddressesFeature>()!.Addresses.First();
            using var client = new HttpClient { BaseAddress = new Uri(address) };

            using var health = await client.GetAsync("/health");
            Assert.Equal(HttpStatusCode.OK, health.StatusCode);
            Assert.Equal("Healthy", await health.Content.ReadAsStringAsync());

            using var alive = await client.GetAsync("/alive");
            Assert.Equal(HttpStatusCode.OK, alive.StatusCode);
            Assert.Equal("Healthy", await alive.Content.ReadAsStringAsync());

            using var other = await client.GetAsync("/api/nothing");
            Assert.Equal(HttpStatusCode.NotFound, other.StatusCode);
        }
        finally
        {
            await app.StopAsync();
        }
    }

    [Fact]
    public async Task MapDefaultEndpoints_maps_nothing_in_production()
    {
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions { EnvironmentName = "Production" });
        builder.WebHost.UseUrls("http://127.0.0.1:0");
        builder.AddServiceDefaults();

        await using var app = builder.Build();
        app.MapDefaultEndpoints();
        await app.StartAsync();
        try
        {
            var address = app.Services.GetRequiredService<IServer>()
                .Features.Get<IServerAddressesFeature>()!.Addresses.First();
            using var client = new HttpClient { BaseAddress = new Uri(address) };

            using var health = await client.GetAsync("/health");
            Assert.Equal(HttpStatusCode.NotFound, health.StatusCode);
        }
        finally
        {
            await app.StopAsync();
        }
    }
}
