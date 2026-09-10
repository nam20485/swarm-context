using System.Net;
using System.Reflection;
using Bunit;
using Microsoft.Extensions.DependencyInjection;
using NSubstitute;
using SwarmSandbox.Web.Models;
using SwarmSandbox.Web.Pages;
using SwarmSandbox.Web.Services;

namespace SwarmSandbox.Tests.Web;

public class HomeTests : BunitContext
{
    public HomeTests() => JSInterop.Mode = JSRuntimeMode.Loose;

    [Fact]
    public void Home_renders_sandbox_rows_from_fake_api_client()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.ListAsync().Returns(
        [
            Info("dev-1", SandboxState.Running, "swarmsandbox-dev-1"),
            Info("dev-2", SandboxState.Creating, "swarmsandbox-dev-2"),
        ]);
        Services.AddSingleton(api);

        var cut = Render<Home>();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("swarmsandbox-dev-1", cut.Markup);
            Assert.Contains("Running", cut.Markup);
            Assert.Contains("swarmsandbox-dev-2", cut.Markup);
            Assert.Contains("Creating", cut.Markup);
        });
        Assert.Equal(2, cut.FindAll("tbody tr").Count);
    }

    [Fact]
    public void Home_create_form_posts_typed_branch()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.ListAsync().Returns([]);
        api.CreateAsync("feature-x").Returns(new CreateSandboxResponse("dev-9", "feature-x", "swarmsandbox-dev-9"));
        Services.AddSingleton(api);

        var cut = Render<Home>();
        cut.WaitForElement(".create-branch");

        cut.Find(".create-branch").Change("feature-x");
        cut.Find(".create-sandbox").Click();

        cut.WaitForAssertion(() => api.Received(1).CreateAsync("feature-x"));
    }

    [Fact]
    public void Home_shows_empty_state_when_there_are_no_sandboxes()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.ListAsync().Returns([]);
        Services.AddSingleton(api);

        var cut = Render<Home>();

        cut.WaitForAssertion(() => Assert.Contains("No sandboxes yet. Create one below.", cut.Markup));
    }

    [Fact]
    public void Home_shows_loading_placeholder_until_the_first_list_arrives()
    {
        var api = Substitute.For<ISandboxApiClient>();
        var list = new TaskCompletionSource<List<SandboxInfo>>(TaskCreationOptions.RunContinuationsAsynchronously);
        api.ListAsync().Returns(list.Task);
        Services.AddSingleton(api);

        var cut = Render<Home>();
        Assert.Contains("Loading...", cut.Markup);

        list.SetResult([]);
        cut.WaitForAssertion(() => Assert.Contains("No sandboxes yet.", cut.Markup));
    }

    [Fact]
    public void Home_shows_a_dismissible_banner_when_the_api_fails()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.ListAsync().Returns(Task.FromException<List<SandboxInfo>>(
            new ApiException(HttpStatusCode.ServiceUnavailable, "api exploded")));
        Services.AddSingleton(api);

        var cut = Render<Home>();
        cut.WaitForAssertion(() => Assert.Contains("api exploded", cut.Markup));

        cut.Find(".btn-close").Click();

        cut.WaitForAssertion(() => Assert.DoesNotContain("api exploded", cut.Markup));
    }

    [Fact]
    public void Home_shows_an_unreachable_message_on_connection_failure()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.ListAsync().Returns(Task.FromException<List<SandboxInfo>>(
            new HttpRequestException("connection refused")));
        Services.AddSingleton(api);

        var cut = Render<Home>();

        cut.WaitForAssertion(() => Assert.Contains("Sandbox API unreachable: connection refused", cut.Markup));
    }

    [Fact]
    public void Home_create_failure_surfaces_an_error_banner()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.ListAsync().Returns([]);
        api.CreateAsync("development").Returns(Task.FromException<CreateSandboxResponse>(
            new ApiException(HttpStatusCode.BadRequest, "quota exhausted")));
        Services.AddSingleton(api);

        var cut = Render<Home>();
        cut.WaitForElement(".create-sandbox");

        cut.Find(".create-sandbox").Click();

        cut.WaitForAssertion(() => Assert.Contains("quota exhausted", cut.Markup));
    }

    [Fact]
    public void Home_create_when_api_unreachable_shows_banner_instead_of_crashing()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.ListAsync().Returns([]);
        api.CreateAsync("development").Returns(Task.FromException<CreateSandboxResponse>(
            new HttpRequestException("connection refused")));
        Services.AddSingleton(api);

        var cut = Render<Home>();
        cut.WaitForElement(".create-sandbox");

        cut.Find(".create-sandbox").Click();

        cut.WaitForAssertion(() => Assert.Contains("Sandbox API unreachable: connection refused", cut.Markup));
    }

    [Fact]
    public async Task Home_delete_when_api_unreachable_shows_banner_instead_of_crashing()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.ListAsync().Returns([Info("dev-1", SandboxState.Running, "swarmsandbox-dev-1")]);
        api.DeleteAsync("dev-1", Arg.Any<CancellationToken>())
            .Returns(Task.FromException(new HttpRequestException("connection refused")));
        Services.AddSingleton(api);

        var cut = Render<Home>();
        cut.WaitForElement("tbody tr button");
        JSInterop.Setup<bool>("confirm", _ => true).SetResult(true);

        cut.Find("tbody tr button").Click();

        cut.WaitForAssertion(() => Assert.Contains("Sandbox API unreachable: connection refused", cut.Markup));
        await api.Received(1).DeleteAsync("dev-1", Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Home_delete_aborts_when_confirmation_is_declined()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.ListAsync().Returns([Info("dev-1", SandboxState.Running, "swarmsandbox-dev-1")]);
        Services.AddSingleton(api);

        var cut = Render<Home>();
        cut.WaitForElement("tbody tr button");

        cut.Find("tbody tr button").Click();

        cut.WaitForAssertion(() => Assert.Contains("swarmsandbox-dev-1", cut.Markup));
        await api.DidNotReceiveWithAnyArgs().DeleteAsync(default!, default);
    }

    [Fact]
    public async Task Home_delete_removes_the_row_after_confirmation()
    {
        var api = Substitute.For<ISandboxApiClient>();
        // NB: `Returns(x, [])` would bind [] to an empty params array — pass the empty
        // second list explicitly so the queue advances to it on the second call.
        api.ListAsync().Returns(
            new List<SandboxInfo> { Info("dev-1", SandboxState.Running, "swarmsandbox-dev-1") },
            new List<SandboxInfo>());
        Services.AddSingleton(api);

        var cut = Render<Home>();
        cut.WaitForElement("tbody tr button");
        JSInterop.Setup<bool>("confirm", _ => true).SetResult(true);

        cut.Find("tbody tr button").Click();

        await api.Received(1).DeleteAsync("dev-1", Arg.Any<CancellationToken>());
        JSInterop.VerifyInvoke("confirm");
        cut.Render();
        Assert.Contains("No sandboxes yet.", cut.Markup);
    }

    [Fact]
    public async Task Home_delete_failure_surfaces_an_error_banner()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.ListAsync().Returns([Info("dev-1", SandboxState.Running, "swarmsandbox-dev-1")]);
        api.DeleteAsync("dev-1", Arg.Any<CancellationToken>())
            .Returns(Task.FromException(new ApiException(HttpStatusCode.InternalServerError, "docker refused")));
        Services.AddSingleton(api);

        var cut = Render<Home>();
        cut.WaitForElement("tbody tr button");
        JSInterop.Setup<bool>("confirm", _ => true).SetResult(true);

        cut.Find("tbody tr button").Click();

        cut.WaitForAssertion(() => Assert.Contains("docker refused", cut.Markup));
    }

    [Fact]
    public void Home_renders_distinct_badges_for_every_state()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.ListAsync().Returns(
        [
            Info("stopping", SandboxState.Stopping, "swarmsandbox-stopping"),
            Info("stopped", SandboxState.Stopped, "swarmsandbox-stopped"),
            Info("removed", SandboxState.Removed, "swarmsandbox-removed"),
            Info("faulted", SandboxState.Faulted, "swarmsandbox-faulted"),
        ]);
        Services.AddSingleton(api);

        var cut = Render<Home>();

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("text-bg-warning", cut.Markup);
            Assert.Contains("text-bg-secondary", cut.Markup);
            Assert.Contains("text-bg-danger", cut.Markup);
        });
    }

    [Fact]
    public async Task Home_polls_while_a_sandbox_is_creating_and_stops_when_provisioned()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.ListAsync().Returns(
            [Info("dev-1", SandboxState.Creating, "swarmsandbox-dev-1")],
            [Info("dev-1", SandboxState.Running, "swarmsandbox-dev-1")]);
        Services.AddSingleton(api);

        var cut = Render<Home>();
        cut.WaitForAssertion(() => Assert.Contains("Creating", cut.Markup));

        // The first poll tick fires after the 5s PollInterval baked into Home (the poll's
        // refresh does not re-render, so wait in real time).
        await Task.Delay(6500);
        Assert.Equal(2, api.ReceivedCalls().Count(c => c.GetMethodInfo().Name == nameof(ISandboxApiClient.ListAsync)));

        // The state is Running now, so polling stops: no further ticks.
        await Task.Delay(5500);
        Assert.Equal(2, api.ReceivedCalls().Count(c => c.GetMethodInfo().Name == nameof(ISandboxApiClient.ListAsync)));
    }

    private static SandboxInfo Info(string id, SandboxState state, string containerName) => new(
        id, $"cid-{id}", state, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddHours(1), containerName);
}
