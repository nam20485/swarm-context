using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using SwarmSandbox.Web.Models;

namespace SwarmSandbox.Web.Services;

/// <summary>Failure from the sandbox API, carrying the HTTP status code and the response body.</summary>
public class ApiException(HttpStatusCode statusCode, string? body)
    : Exception($"Sandbox API returned {(int)statusCode} {statusCode}{(string.IsNullOrEmpty(body) ? "" : $": {body}")}")
{
    public HttpStatusCode StatusCode { get; } = statusCode;

    public string? Body { get; } = body;
}

/// <summary>Typed access to the sandbox API surface (see Api/Contracts/Dtos.cs).</summary>
public interface ISandboxApiClient
{
    Task<CreateSandboxResponse> CreateAsync(string? branch, CancellationToken cancellationToken = default);

    Task<List<SandboxInfo>> ListAsync(CancellationToken cancellationToken = default);

    Task<SandboxStatus> GetAsync(string id, CancellationToken cancellationToken = default);

    Task DeleteAsync(string id, CancellationToken cancellationToken = default);
}

/// <summary>HttpClient wrapper for the sandbox API; non-success statuses throw <see cref="ApiException"/>.</summary>
public sealed class SandboxApiClient(HttpClient http) : ISandboxApiClient
{
    // The API serializes enums as camelCase strings; the converter also accepts numbers.
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    public async Task<CreateSandboxResponse> CreateAsync(string? branch, CancellationToken cancellationToken = default)
    {
        // Mirror SandboxRequest.NormalizeBranch on the Api (Web must not reference Api).
        var normalized = string.IsNullOrWhiteSpace(branch) ? "development" : branch;
        using var response = await http.PostAsJsonAsync("api/sandboxes", new SandboxRequest(normalized), JsonOptions, cancellationToken);
        await EnsureSuccessAsync(response);
        return await response.Content.ReadFromJsonAsync<CreateSandboxResponse>(JsonOptions, cancellationToken)
            ?? throw new ApiException(response.StatusCode, "Empty 202 body.");
    }

    public async Task<List<SandboxInfo>> ListAsync(CancellationToken cancellationToken = default)
    {
        using var response = await http.GetAsync("api/sandboxes", cancellationToken);
        await EnsureSuccessAsync(response);
        return await response.Content.ReadFromJsonAsync<List<SandboxInfo>>(JsonOptions, cancellationToken) ?? [];
    }

    public async Task<SandboxStatus> GetAsync(string id, CancellationToken cancellationToken = default)
    {
        using var response = await http.GetAsync($"api/sandboxes/{id}", cancellationToken);
        await EnsureSuccessAsync(response);
        return await response.Content.ReadFromJsonAsync<SandboxStatus>(JsonOptions, cancellationToken)
            ?? throw new ApiException(response.StatusCode, "Empty body.");
    }

    public async Task DeleteAsync(string id, CancellationToken cancellationToken = default)
    {
        using var response = await http.DeleteAsync($"api/sandboxes/{id}", cancellationToken);
        await EnsureSuccessAsync(response);
    }

    private static async Task EnsureSuccessAsync(HttpResponseMessage response)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        var body = await response.Content.ReadAsStringAsync();
        throw new ApiException(response.StatusCode, body);
    }
}
