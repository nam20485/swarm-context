using System.Net;
using System.Text;
using SwarmSandbox.Web.Models;
using SwarmSandbox.Web.Services;

namespace SwarmSandbox.Tests.Web;

public class SandboxApiClientTests
{
    [Fact]
    public async Task Create_sends_POST_with_branch_and_parses_202_body()
    {
        var handler = new StubHandler(_ => StubHandler.JsonResponse(HttpStatusCode.Accepted,
            """{"sandboxId":"development-1a2b3c","branch":"development","containerName":"swarmsandbox-development-1a2b3c"}"""));
        var client = new SandboxApiClient(new HttpClient(handler) { BaseAddress = new Uri("http://localhost/") });

        var response = await client.CreateAsync("feature-x");

        Assert.Equal(HttpMethod.Post, handler.Request!.Method);
        Assert.Equal("http://localhost/api/sandboxes", handler.Request.RequestUri!.ToString());
        Assert.Equal("""{"branch":"feature-x"}""", handler.Body);
        Assert.Equal("development-1a2b3c", response.SandboxId);
        Assert.Equal("development", response.Branch);
        Assert.Equal("swarmsandbox-development-1a2b3c", response.ContainerName);
    }

    [Fact]
    public async Task Get_surfaces_404_as_typed_not_found()
    {
        var handler = new StubHandler(_ => StubHandler.TextResponse(HttpStatusCode.NotFound, "sandbox sbx-x not found"));
        var client = new SandboxApiClient(new HttpClient(handler) { BaseAddress = new Uri("http://localhost/") });

        var ex = await Assert.ThrowsAsync<ApiException>(() => client.GetAsync("sbx-x"));

        Assert.Equal(HttpStatusCode.NotFound, ex.StatusCode);
        Assert.Equal("sandbox sbx-x not found", ex.Body);
        Assert.Equal("http://localhost/api/sandboxes/sbx-x", handler.Request!.RequestUri!.ToString());
    }

    [Fact]
    public async Task List_parses_sandbox_rows_from_a_200_body()
    {
        var handler = new StubHandler(_ => StubHandler.JsonResponse(HttpStatusCode.OK,
            """[{"id":"dev-1","containerId":"cid-1","state":"running","createdAt":"2026-01-01T00:00:00Z","expiresAt":null,"containerName":"swarmsandbox-dev-1"}]"""));
        var client = new SandboxApiClient(new HttpClient(handler) { BaseAddress = new Uri("http://localhost/") });

        var list = await client.ListAsync();

        Assert.Equal(HttpMethod.Get, handler.Request!.Method);
        Assert.Equal("http://localhost/api/sandboxes", handler.Request.RequestUri!.ToString());
        var row = Assert.Single(list);
        Assert.Equal("dev-1", row.Id);
        Assert.Equal("cid-1", row.ContainerId);
        Assert.Equal(SandboxState.Running, row.State);
        Assert.Equal("swarmsandbox-dev-1", row.ContainerName);
    }

    [Fact]
    public async Task Delete_sends_DELETE_and_accepts_204()
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.NoContent));
        var client = new SandboxApiClient(new HttpClient(handler) { BaseAddress = new Uri("http://localhost/") });

        await client.DeleteAsync("dev-1");

        Assert.Equal(HttpMethod.Delete, handler.Request!.Method);
        Assert.Equal("http://localhost/api/sandboxes/dev-1", handler.Request.RequestUri!.ToString());
    }

    [Fact]
    public async Task Get_surfaces_an_empty_200_body_as_a_typed_error()
    {
        var handler = new StubHandler(_ => StubHandler.JsonResponse(HttpStatusCode.OK, "null"));
        var client = new SandboxApiClient(new HttpClient(handler) { BaseAddress = new Uri("http://localhost/") });

        var ex = await Assert.ThrowsAsync<ApiException>(() => client.GetAsync("dev-1"));

        Assert.Equal(HttpStatusCode.OK, ex.StatusCode);
        Assert.Equal("Empty body.", ex.Body);
    }

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public HttpRequestMessage? Request { get; private set; }

        public string? Body { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Request = request;
            if (request.Content is not null)
            {
                Body = await request.Content.ReadAsStringAsync(cancellationToken);
            }

            return respond(request);
        }

        public static HttpResponseMessage JsonResponse(HttpStatusCode statusCode, string json) => new(statusCode)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json")
        };

        public static HttpResponseMessage TextResponse(HttpStatusCode statusCode, string text) => new(statusCode)
        {
            Content = new StringContent(text, Encoding.UTF8, "text/plain")
        };
    }
}
