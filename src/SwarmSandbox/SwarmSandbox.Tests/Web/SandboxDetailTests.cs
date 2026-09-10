using System.Net;
using System.Reflection;
using Bunit;
using Microsoft.AspNetCore.Components;
using Microsoft.Extensions.DependencyInjection;
using NSubstitute;
using SwarmSandbox.Web.Models;
using SwarmSandbox.Web.Pages;
using SwarmSandbox.Web.Services;

namespace SwarmSandbox.Tests.Web;

public class SandboxDetailTests : BunitContext
{
    public SandboxDetailTests() => JSInterop.Mode = JSRuntimeMode.Loose;

    [Fact]
    public void SandboxDetail_shows_container_name_in_instructions_panel()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.GetAsync("dev-1").Returns(new SandboxStatus(
            Info("dev-1", SandboxState.Running, "swarmsandbox-dev-1"), LastError: null));
        Services.AddSingleton(api);

        var cut = Render<SandboxDetail>(ps => ps.Add(p => p.Id, "dev-1"));

        cut.WaitForAssertion(() =>
        {
            var panel = cut.Find(".connect-instructions");
            Assert.Contains("swarmsandbox-dev-1", panel.TextContent);
            Assert.Contains("Remote Connection", panel.TextContent);
            Assert.Contains("/workspace", panel.TextContent);
        });
        Assert.Contains("swarmsandbox-dev-1", cut.Find(".status-card").TextContent);
    }

    [Fact]
    public void SandboxDetail_shows_last_error_when_faulted()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.GetAsync("dev-2").Returns(new SandboxStatus(
            Info("dev-2", SandboxState.Faulted, "swarmsandbox-dev-2"), LastError: "docker daemon unreachable"));
        Services.AddSingleton(api);

        var cut = Render<SandboxDetail>(ps => ps.Add(p => p.Id, "dev-2"));

        cut.WaitForAssertion(() => Assert.Contains("docker daemon unreachable", cut.Markup));
    }

    [Fact]
    public void SandboxDetail_404_shows_a_not_found_banner()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.GetAsync("missing").Returns(Task.FromException<SandboxStatus>(
            new ApiException(HttpStatusCode.NotFound, "sandbox missing not found")));
        Services.AddSingleton(api);

        var cut = Render<SandboxDetail>(ps => ps.Add(p => p.Id, "missing"));

        cut.WaitForAssertion(() => Assert.Contains("Sandbox 'missing' not found — it may have been removed.", cut.Markup));
    }

    [Fact]
    public void SandboxDetail_unexpected_api_errors_show_the_message()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.GetAsync("dev-3").Returns(Task.FromException<SandboxStatus>(
            new ApiException(HttpStatusCode.InternalServerError, "backend exploded")));
        Services.AddSingleton(api);

        var cut = Render<SandboxDetail>(ps => ps.Add(p => p.Id, "dev-3"));

        cut.WaitForAssertion(() => Assert.Contains("backend exploded", cut.Markup));
    }

    [Fact]
    public void SandboxDetail_connection_failures_show_an_unreachable_message()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.GetAsync("dev-4").Returns(Task.FromException<SandboxStatus>(
            new HttpRequestException("connection refused")));
        Services.AddSingleton(api);

        var cut = Render<SandboxDetail>(ps => ps.Add(p => p.Id, "dev-4"));

        cut.WaitForAssertion(() => Assert.Contains("Sandbox API unreachable: connection refused", cut.Markup));
    }

    [Fact]
    public async Task SandboxDetail_delete_aborts_when_confirmation_is_declined()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.GetAsync("dev-1").Returns(new SandboxStatus(
            Info("dev-1", SandboxState.Running, "swarmsandbox-dev-1"), LastError: null));
        Services.AddSingleton(api);

        var cut = Render<SandboxDetail>(ps => ps.Add(p => p.Id, "dev-1"));
        cut.WaitForElement(".btn-outline-danger");

        cut.Find(".btn-outline-danger").Click();

        await api.DidNotReceiveWithAnyArgs().DeleteAsync(default!, default);
    }

    [Fact]
    public async Task SandboxDetail_delete_confirmed_navigates_back_to_the_list()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.GetAsync("dev-1").Returns(new SandboxStatus(
            Info("dev-1", SandboxState.Running, "swarmsandbox-dev-1"), LastError: null));
        Services.AddSingleton(api);

        var cut = Render<SandboxDetail>(ps => ps.Add(p => p.Id, "dev-1"));
        cut.WaitForElement(".btn-outline-danger");
        JSInterop.Setup<bool>("confirm", _ => true).SetResult(true);

        cut.Find(".btn-outline-danger").Click();

        await api.Received(1).DeleteAsync("dev-1", Arg.Any<CancellationToken>());
        Assert.Equal("http://localhost/", cut.Services.GetRequiredService<NavigationManager>().Uri);
    }

    [Fact]
    public async Task SandboxDetail_delete_failure_surfaces_an_error_banner()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.GetAsync("dev-1").Returns(new SandboxStatus(
            Info("dev-1", SandboxState.Running, "swarmsandbox-dev-1"), LastError: null));
        api.DeleteAsync("dev-1", Arg.Any<CancellationToken>())
            .Returns(Task.FromException(new ApiException(HttpStatusCode.Conflict, "container busy")));
        Services.AddSingleton(api);

        var cut = Render<SandboxDetail>(ps => ps.Add(p => p.Id, "dev-1"));
        cut.WaitForElement(".btn-outline-danger");
        JSInterop.Setup<bool>("confirm", _ => true).SetResult(true);

        cut.Find(".btn-outline-danger").Click();

        cut.WaitForAssertion(() => Assert.Contains("container busy", cut.Markup));
    }

    [Fact]
    public void SandboxDetail_delete_when_api_unreachable_shows_banner_instead_of_crashing()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.GetAsync("dev-1").Returns(new SandboxStatus(
            Info("dev-1", SandboxState.Running, "swarmsandbox-dev-1"), LastError: null));
        api.DeleteAsync("dev-1", Arg.Any<CancellationToken>())
            .Returns(Task.FromException(new HttpRequestException("connection refused")));
        Services.AddSingleton(api);

        var cut = Render<SandboxDetail>(ps => ps.Add(p => p.Id, "dev-1"));
        cut.WaitForElement(".btn-outline-danger");
        JSInterop.Setup<bool>("confirm", _ => true).SetResult(true);

        cut.Find(".btn-outline-danger").Click();

        cut.WaitForAssertion(() => Assert.Contains("Sandbox API unreachable: connection refused", cut.Markup));
    }

    [Fact]
    public void SandboxDetail_renders_badges_for_stopping_and_default_states()
    {
        var api = Substitute.For<ISandboxApiClient>();
        api.GetAsync("stopped-1").Returns(new SandboxStatus(
            Info("stopped-1", SandboxState.Stopped, "swarmsandbox-stopped-1"), LastError: null));
        api.GetAsync("stopping-1").Returns(new SandboxStatus(
            Info("stopping-1", SandboxState.Stopping, "swarmsandbox-stopping-1"), LastError: null));
        Services.AddSingleton(api);

        var cut = Render<SandboxDetail>(ps => ps.Add(p => p.Id, "stopped-1"));
        cut.WaitForAssertion(() => Assert.Contains("text-bg-secondary", cut.Markup));

        var cut2 = Render<SandboxDetail>(ps => ps.Add(p => p.Id, "stopping-1"));
        cut2.WaitForAssertion(() => Assert.Contains("text-bg-warning", cut2.Markup));
    }

    [Fact]
    public async Task SandboxDetail_polls_for_status_on_each_tick()
    {
        var api = Substitute.For<ISandboxApiClient>();
        var status = new SandboxStatus(Info("dev-1", SandboxState.Running, "swarmsandbox-dev-1"), LastError: null);
        api.GetAsync("dev-1").Returns(status, status);
        Services.AddSingleton(api);

        var cut = Render<SandboxDetail>(ps => ps.Add(p => p.Id, "dev-1"));

        // The second call arrives on the first poll tick (5s PollInterval baked into the page).
        cut.WaitForAssertion(
            () => Assert.Equal(2, api.ReceivedCalls().Count(c => c.GetMethodInfo().Name == nameof(ISandboxApiClient.GetAsync))),
            TimeSpan.FromSeconds(9));
    }

    private static SandboxInfo Info(string id, SandboxState state, string containerName) => new(
        id, $"cid-{id}", state, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddHours(1), containerName);
}
