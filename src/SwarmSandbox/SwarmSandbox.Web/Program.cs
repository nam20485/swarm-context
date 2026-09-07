using Microsoft.AspNetCore.Components.Web;
using Microsoft.AspNetCore.Components.WebAssembly.Hosting;
using SwarmSandbox.Web;

var builder = WebAssemblyHostBuilder.CreateDefault(args);
builder.RootComponents.Add<App>("#app");
builder.RootComponents.Add<HeadOutlet>("head::after");

// Under Aspire the Api base URL arrives via SANDBOX_API_URL. It must be set at
// publish/serve time (wwwroot/appsettings.json placeholder; Aspire WithEnvironment
// cannot reach the WASM browser runtime). Empty falls back to the wwwroot origin.
builder.Services.AddScoped(sp =>
{
    var configured = builder.Configuration["SANDBOX_API_URL"];
    var apiBaseUrl = string.IsNullOrWhiteSpace(configured) ? builder.HostEnvironment.BaseAddress : configured;
    return new HttpClient { BaseAddress = new Uri(apiBaseUrl) };
});
builder.Services.AddScoped<SwarmSandbox.Web.Services.ISandboxApiClient, SwarmSandbox.Web.Services.SandboxApiClient>();

await builder.Build().RunAsync();
