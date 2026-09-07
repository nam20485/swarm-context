using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using NSubstitute;
using SwarmSandbox.Api.Contracts;
using SwarmSandbox.Api.Data;
using SwarmSandbox.Api.Services;
using SwarmSandbox.Tests.Services;
using Xunit;

namespace SwarmSandbox.Tests.Api;

/// <summary>
/// End-to-end wiring tests: real Api Program.cs (DI + endpoints) with the provisioner and store faked.
/// </summary>
public class SandboxEndpointsIntegrationTests
{
    private static readonly DateTimeOffset Now = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    [Fact]
    public async Task Post_creates_a_sandbox_and_returns_202_with_the_payload()
    {
        var store = new InMemorySandboxStore();
        var provisioner = Substitute.For<ISandboxProvisioner>();
        provisioner
            .CreateSandboxAsync(Arg.Any<SandboxRequest>(), Arg.Any<CancellationToken>())
            .Returns(new SandboxInfo("abc123def456", "cid-1", SandboxState.Running, Now, Now.AddHours(1), "swarmsandbox-abc123de"));
        using var factory = CreateFactory(store, provisioner);
        var client = factory.CreateClient();

        var response = await client.PostAsJsonAsync("/api/sandboxes", new { branch = "main" });

        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        // The 202 payload carries the persisted record id (manager-generated).
        Assert.Equal(Assert.Single(store.Rows).Id, body.GetProperty("sandboxId").GetString());
        Assert.Equal("main", body.GetProperty("branch").GetString());
        Assert.Equal("swarmsandbox-abc123de", body.GetProperty("containerName").GetString());
        await provisioner.Received(1).CreateSandboxAsync(
            Arg.Is<SandboxRequest>(r => r.Branch == "main"), Arg.Any<CancellationToken>());
        var record = Assert.Single(store.Rows);
        Assert.Equal(SandboxState.Running, record.State);
        Assert.Equal("main", record.Branch);
    }

    [Fact]
    public async Task Post_defaults_a_blank_branch_to_development()
    {
        var store = new InMemorySandboxStore();
        var provisioner = Substitute.For<ISandboxProvisioner>();
        provisioner
            .CreateSandboxAsync(Arg.Any<SandboxRequest>(), Arg.Any<CancellationToken>())
            .Returns(new SandboxInfo("dev111222333", "cid-2", SandboxState.Running, Now, Now.AddHours(1), "swarmsandbox-dev"));
        using var factory = CreateFactory(store, provisioner);
        var client = factory.CreateClient();

        var response = await client.PostAsJsonAsync("/api/sandboxes", new { branch = "" });

        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("development", body.GetProperty("branch").GetString());
        Assert.Equal(SandboxRequest.DefaultBranch, Assert.Single(store.Rows).Branch);
    }

    [Fact]
    public async Task Get_list_returns_the_persisted_records()
    {
        var store = new InMemorySandboxStore();
        store.Seed(Row("first", SandboxState.Running), Row("second", SandboxState.Faulted));
        var provisioner = Substitute.For<ISandboxProvisioner>();
        using var factory = CreateFactory(store, provisioner);
        var client = factory.CreateClient();

        var response = await client.GetAsync("/api/sandboxes");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(2, body.GetArrayLength());
        Assert.Equal("first", body[0].GetProperty("id").GetString());
        Assert.Equal("second", body[1].GetProperty("id").GetString());
    }

    [Fact]
    public async Task Get_by_id_returns_200_with_live_status_and_404_for_unknown_ids()
    {
        var store = new InMemorySandboxStore();
        store.Seed(Row("known", SandboxState.Creating));
        var provisioner = Substitute.For<ISandboxProvisioner>();
        // P0 regression guard: the manager calls the provisioner with the container
        // name (Row() sets ContainerName = "sbx-{id}"), not the record id.
        provisioner
            .GetStatusAsync("sbx-known", Arg.Any<CancellationToken>())
            .Returns(new SandboxStatus(
                new SandboxInfo("known", "live-cid", SandboxState.Stopped, Now, null, "live-name"),
                "container exited"));
        using var factory = CreateFactory(store, provisioner);
        var client = factory.CreateClient();

        var found = await client.GetAsync("/api/sandboxes/known");
        Assert.Equal(HttpStatusCode.OK, found.StatusCode);
        var status = await found.Content.ReadFromJsonAsync<JsonElement>();
        // Enums serialize as camelCase strings on the wire (JsonStringEnumConverter).
        Assert.Equal("stopped", status.GetProperty("info").GetProperty("state").GetString());
        Assert.Equal("live-cid", status.GetProperty("info").GetProperty("containerId").GetString());
        Assert.Equal("container exited", status.GetProperty("lastError").GetString());

        var missing = await client.GetAsync("/api/sandboxes/unknown");
        Assert.Equal(HttpStatusCode.NotFound, missing.StatusCode);
    }

    [Fact]
    public async Task Delete_returns_204_for_known_ids_then_404_once_removed()
    {
        var store = new InMemorySandboxStore();
        store.Seed(Row("gone", SandboxState.Running));
        var provisioner = Substitute.For<ISandboxProvisioner>();
        using var factory = CreateFactory(store, provisioner);
        var client = factory.CreateClient();

        var first = await client.DeleteAsync("/api/sandboxes/gone");
        Assert.Equal(HttpStatusCode.NoContent, first.StatusCode);
        // P0 regression guard: removal targets the container name, not the record id.
        await provisioner.Received(1).RemoveAsync("sbx-gone", Arg.Any<CancellationToken>());
        await provisioner.DidNotReceive().RemoveAsync("gone", Arg.Any<CancellationToken>());
        Assert.Equal(SandboxState.Removed, store.Find("gone")!.State);

        // Deleted rows are kept for audit; only a never-seen id 404s.
        var second = await client.DeleteAsync("/api/sandboxes/never-seen");
        Assert.Equal(HttpStatusCode.NotFound, second.StatusCode);
    }

    [Fact]
    public async Task Post_returns_502_problem_details_when_provisioning_fails()
    {
        var store = new InMemorySandboxStore();
        var provisioner = Substitute.For<ISandboxProvisioner>();
        provisioner
            .CreateSandboxAsync(Arg.Any<SandboxRequest>(), Arg.Any<CancellationToken>())
            .Returns(Task.FromException<SandboxInfo>(new InvalidOperationException("docker down")));
        using var factory = CreateFactory(store, provisioner);
        var client = factory.CreateClient();

        var response = await client.PostAsJsonAsync("/api/sandboxes", new { branch = "main" });

        Assert.Equal(HttpStatusCode.BadGateway, response.StatusCode);
        Assert.Contains("application/problem+json", response.Content.Headers.ContentType?.ToString());
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(502, problem.GetProperty("status").GetInt32());
        var record = Assert.Single(store.Rows);
        Assert.Equal(SandboxState.Faulted, record.State);
    }

    private static WebApplicationFactory<Program> CreateFactory(
        InMemorySandboxStore store, ISandboxProvisioner provisioner) =>
        new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
        {
            // Program requires a Postgres connection string at startup; the store is faked below,
            // so Npgsql stays registered but is never used.
            builder.UseSetting("ConnectionStrings:postgres", "Host=localhost;Database=unused;Username=unused;Password=unused");
            builder.ConfigureServices(services =>
            {
                services.RemoveAll<ISandboxStore>();
                services.AddSingleton<ISandboxStore>(store);
                services.RemoveAll<ISandboxProvisioner>();
                services.AddSingleton(provisioner);
            });
        });

    private static SandboxRecord Row(string id, SandboxState state) => new()
    {
        Id = id,
        ContainerId = $"cid-{id}",
        ContainerName = $"sbx-{id}",
        State = state,
        Branch = SandboxRequest.DefaultBranch,
        CreatedAt = DateTimeOffset.UtcNow,
        ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(30),
    };
}
