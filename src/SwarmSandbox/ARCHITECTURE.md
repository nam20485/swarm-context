# SwarmSandbox Architecture

## Product

SwarmSandbox is an Aspire-hosted service that provisions Docker containers pre-seeded with a git clone of
this repo's `development` branch as the container's `/workspace`, and — as an **optional accelerator** —
the zcode remote server runtime uploaded from the host into `$HOME/.zcode/server`.

The service keeps containers **running** so the user's **local ZCode desktop** connects to the container via the
conventional Docker remote-development workflow: the desktop itself drives `docker exec` / `docker cp` against the
running container (`docker exec -i <name> sh -lc '<cmd>'`; the desktop deploys its server into `$HOME/.zcode` on
first connect). The container only needs to be running with a POSIX shell, the workspace cloned, and `pwsh` on PATH.

The service owns **container lifecycle ONLY** (see the superseded-design note below for what this rules out).

> **SUPERSEDED DESIGN:** The earlier bridge-shim approach — a Node bridge shim inside each sandbox on port 8787,
> host-side `IZCodeBridgeClient`/`ISwarmRunCoordinator` driving zcode sessions from the API, and a SignalR
> `/hubs/sandbox` stream of agent output — is **superseded** by the remote-development workflow described above:
> there is no shim, no host-side session driving, and no SignalR streaming. Any references to those components
> are historical; do not reimplement them.

## Milestone status (as-built)

- **M1 — DockerSandboxProvisioner**: implemented (`Api/Provisioning/`).
- **M2 — Sandbox image**: implemented (`sandbox/`); image built and smoke-tested.
- **M3 — API composition**: implemented (`Api/Services/`, `Program.cs`, `Endpoints/`).
- **M4 — Web UI**: implemented (`SwarmSandbox.Web/`).
- **M5 — Validation + CI + e2e**: implemented (repo-root `validation.ps1` dotnet branch with the ≥85% coverage
  gate, the `setup-dotnet` version pin in `.github/workflows/ci.yml`, and `scripts/e2e-sandbox.ps1`).

## Solution layout (`src/SwarmSandbox/`)

| Project | Purpose |
| --- | --- |
| `SwarmSandbox.AppHost` | Aspire app host: declares the Postgres container, the Api, and the Web resources. Passes configuration to the Api via `SANDBOX__*` environment variables. |
| `SwarmSandbox.Api` | ASP.NET Core minimal API owning sandbox lifecycle (Docker provisioning + EF persistence on Postgres). |
| `SwarmSandbox.ServiceDefaults` | Aspire shared defaults (OTel, health checks, resilience, service discovery). |
| `SwarmSandbox.Web` | Blazor WebAssembly standalone UI (polling only; does NOT reference Api). |
| `SwarmSandbox.Tests` | xUnit + bUnit tests (46 tests across provisioning, services, Web, and solution-structure checks). |
| `sandbox/` | M2 container image: `Dockerfile`, `entrypoint.sh`, `build-sandbox-image.ps1`, `smoke-test.ps1`. |

## API surface (implemented)

- `POST /api/sandboxes` — body `{ "branch": "..." }` (branch optional, defaults to `development` via
  `SandboxRequest.NormalizeBranch`) → `202 { sandboxId, branch, containerName }`.
- `GET /api/sandboxes` — `200` list of sandbox records.
- `GET /api/sandboxes/{id}` — `200 { info, lastError }` (live Docker state merged over the persisted record)
  or `404`.
- `DELETE /api/sandboxes/{id}` — `204` after force-removing the container addressed by its `ContainerName`
  (falling back to its recorded `ContainerId`; the sandbox record id is never used as a Docker identity), or `404`.

Contracts (`Api/Contracts`):

- `ISandboxProvisioner` — `CreateSandboxAsync(SandboxRequest, ct) -> SandboxInfo`, `GetStatusAsync`,
  `GetLogsAsync(id, tail)`, `StopAsync`, `RemoveAsync`. Implemented by `DockerSandboxProvisioner`.
- `Dtos.cs` — `SandboxRequest(string Branch)` (+ `NormalizeBranch` static helper), `SandboxState`
  { Creating, Running, Stopping, Stopped, Faulted, Removed }, `SandboxInfo(Id, ContainerId, State, CreatedAt,
  ExpiresAt, ContainerName)`, `SandboxStatus(Info, LastError)`.

Services (`Api/Services`):

- `ISandboxStore` — persistence seam for sandbox records (Add / Find / List / Update / `FindExpiredAsync`).
  Production implementation: `EfSandboxStore` (EF Core on Postgres). Tests substitute an in-memory fake.
- `ISandboxManager` / `SandboxManager` — persists a record (`Creating`), drives the provisioner, marks the record
  `Running` (or `Faulted` + `SandboxProvisioningException` on failure), merges live Docker status over the
  persisted record for `GET /{id}`, and removes containers on delete.
- `SandboxReaper` — hosted service; every tick (`ReaperOptions.ReapInterval`, default 60s, key
  `Sandbox:ReapInterval`) it stops/removes records whose `ExpiresAt` has passed (state Running/Faulted).
  The sandbox TTL itself lives in `SandboxOptions.DefaultTtl`; `ReaperOptions` holds only the tick interval.

Data (`Api/Data`): `SandboxRecord` EF entity, `SwarmSandboxDbContext` (sandboxes only), PostgreSQL via Npgsql.
Connection string: Aspire-injected `ConnectionStrings:postgres`, falling back to
`ConnectionStrings:swarmsandbox` for non-Aspire runs.

## Configuration (AppHost → Api)

The Api binds `SandboxOptions` from the `Sandbox` configuration section (`SANDBOX__*` environment variables).
The AppHost passes the first seven; `NetworkName` and `ContainerUser` use their in-code defaults.

| Environment variable | Parameter | Default |
| --- | --- | --- |
| `SANDBOX__DOCKERHOST` | `dockerHost` | `unix:///var/run/docker.sock` |
| `SANDBOX__IMAGENAME` | `imageName` | `swarmsandbox-workspace:latest` |
| `SANDBOX__SEEDSOURCEPATH` | `seedSourcePath` | `/opt/ZCode/resources` (host dir with `zcode-server.cjs` + `node`; **optional** — absent/invalid seed is skipped and the desktop provisions on first connect) |
| `SANDBOX__REPOURL` | `repoUrl` | `https://github.com/nam20485/swarm-context.git` |
| `SANDBOX__GITTOKEN` | `gitToken` (secret) | supplied via user secrets / `Parameters__gitToken` |
| `SANDBOX__WORKSPACEBRANCH` | `workspaceBranch` | `development` |
| `SANDBOX__DEFAULTTTL` | `defaultTtl` | `01:00:00` |
| — (not passed by AppHost) | `networkName` | `swarmsandbox` (dedicated Docker network for sandboxes) |
| — (not passed by AppHost) | `containerUser` | `1000:1000` (numeric uid:gid, validated with `SandboxOptions.Validate` before use — the value is interpolated into a container exec command) |
| `SANDBOX__REAPINTERVAL` (optional) | `ReaperOptions.ReapInterval` | `00:01:00` |

The Web receives the Api base URL as `SANDBOX_API_URL`. Because Blazor WebAssembly configuration cannot come
from environment variables (Aspire `WithEnvironment` does not reach the browser runtime), the Web ships a
`wwwroot/appsettings.json` placeholder whose `SANDBOX_API_URL` value **must be set at publish/serve time**;
empty/missing falls back to the WASM host origin.

## Database schema bootstrap

`Program.cs` runs `Database.EnsureCreated()` on startup (best-effort: failures are logged and startup
continues) so a first run against a fresh Postgres does not 500 with "relation Sandboxes does not exist".
This is a deliberate **dev-grade choice (Simplicity First)**; EF migrations are the production follow-up.

## M1 — DockerSandboxProvisioner (`Api/Provisioning/`) — implemented

Files: `DockerSandboxProvisioner.cs`, `SandboxOptions.cs`.

- Builds the client via `DockerClientBuilder().WithEndpoint(...)` (Docker.DotNet.Enhanced, pinned `4.3.3`).
- `CreateSandboxAsync`: creates a hardened container (`swarmsandbox-` + 8 hex chars) from
  `SANDBOX__IMAGENAME` with `REPO_URL` / `GIT_TOKEN` / `WORKSPACE_BRANCH` env, starts it, then best-effort
  seeds; returns `Running` info with `ExpiresAt = now + DefaultTtl`.
- Hardening: `CapDrop=ALL`, `no-new-privileges`, memory 4 GiB, 2 cores (`NanoCPUs`), `PidsLimit=512`,
  dedicated network (`NetworkMode`), `RestartPolicy=No`, and **no host binds/mounts** (never mounts the
  Docker socket). No published ports (the desktop talks to Docker directly).
- Status/logs/stop/remove map Docker states to `SandboxState`; a missing container reports `Removed`
  (status) or is a no-op (stop/remove) instead of throwing.
- **Seeding is host-side and optional** (research finding: no linux-x64 zcode server runtime exists on the
  host and the CDN manifests 404, so first-connect provisioning by the desktop is the reliable path; the
  seed is a pure accelerator). `TrySeedAsync` skips (logs, provisioning succeeds) when
  `SeedSourcePath` is unset, the directory is missing, or `zcode-server.cjs`/`node` are absent. When valid:
  exec `printf %s "$HOME"` to resolve the container home, exec `mkdir -p $HOME/.zcode/server` (the image
  ships no `~/.zcode` and PutArchive 404s on a missing destination), tar the seed directory (entries 0755 so
  executables survive), upload with `ExtractArchiveToContainerAsync` to `$HOME/.zcode/server`, then exec
  `chown -R <containerUser>` + `chmod +x`. Any seed failure is logged as a warning and never fails provisioning.

### Docker.DotNet.Enhanced API divergences (recorded by M1)

Docker.DotNet.Enhanced `4.3.3` differs from the classic Docker.DotNet surface in the ways M1 hit:

- **Exec lives on a separate `IExecOperations`**, reachable as `IDockerClient.Exec`
  (`CreateContainerExecAsync` / `StartContainerExecAsync`) — not on `IContainerOperations`.
- **Archive upload takes `CopyToContainerParameters`** (destination in its `Path` property) for
  `IContainerOperations.ExtractArchiveToContainerAsync(containerId, parameters, stream, ct)`.
- **Response IDs are the `ID` property** (e.g. `CreateContainerResponse.ID`,
  `ContainerExecCreateResponse.ID` — capital D, not `Id`).

## M2 — Sandbox image (`sandbox/`) — implemented

Design: **`debian:trixie-slim` (pinned by digest) + pinned PowerShell** — deliberately not a node base image,
and **no in-image seeding** (seeding is host-side M1 `PutArchive`/`ExtractArchiveToContainerAsync` only;
this supersedes the earlier M2 sketch that assumed a node base, `curl`/`sha256sum`, and in-image seed steps).

`Dockerfile`:

- `FROM debian:trixie-slim@sha256:d7e1218...` (digest-pinned).
- Adds `ca-certificates`, `coreutils`, `curl`, `git`, `gzip`, `libicu76` (ICU runtime required by
  .NET/pwsh, absent from trixie-slim), `tar` — POSIX shell, tar/gzip/coreutils are already in debian-slim.
- PowerShell 7 pinned to `7.5.2` (`ARG POWERSHELL_VERSION`) from the official release tarball, symlinked to
  `/usr/bin/pwsh`; telemetry opted out.
- Non-root user `sandbox` (uid 1000, shell `/bin/sh`), `HOME=/home/sandbox`; `/workspace` and
  `/workspace-clone-error.txt` pre-created and owned by `sandbox`. Runs as `sandbox`, `WORKDIR /workspace`.

`entrypoint.sh` (runs as non-root): clones `REPO_URL` branch `WORKSPACE_BRANCH` (`--single-branch --depth 1`)
into `/workspace`; when `GIT_TOKEN` is set it clones via `https://x-access-token:<token>@...` and then scrubs
the credential with `git remote set-url` (also deleting `.git/FETCH_HEAD`, where clone wrote the credentialed
URL; token never echoed or logged) and re-execs PID1 via `env -u GIT_TOKEN sleep infinity` so the token never
lives in the init environment. **Always `exec sleep infinity` — even on clone failure** (failure details go to
`/workspace-clone-error.txt`; the container must stay up so the desktop can connect for debugging). A
pre-existing non-empty `/workspace` skips the clone.

`build-sandbox-image.ps1` and `smoke-test.ps1` build the image and verify the spec (20/20 smoke checks pass).

## M3 — API composition (`Api/Services/`, `Program.cs`, `Endpoints/`) — implemented

- `Program.cs` DI: `Configure<SandboxOptions>` + `Configure<ReaperOptions>` (both from the `Sandbox` section),
  `TimeProvider.System`, `AddDbContext<SwarmSandboxDbContext>` (Npgsql; `ConnectionStrings:postgres` →
  `swarmsandbox` fallback), `ISandboxStore` → `EfSandboxStore` (scoped), `ISandboxProvisioner` →
  `DockerSandboxProvisioner` (singleton), `ISandboxManager` → `SandboxManager` (scoped),
  `AddHostedService<SandboxReaper>`, `AddProblemDetails` + `AddExceptionHandler<ProvisioningExceptionHandler>`
  (provisioning failures become 502 ProblemDetails), and `ConfigureHttpJsonOptions` with a
  `JsonStringEnumConverter` so enum states serialize as camelCase strings (matching Web's `SandboxApiClient`).
- `SandboxEndpoints.MapSandboxEndpoints` wires the four real endpoints listed above to `ISandboxManager`
  (the original 202/501 stubs are gone).
- The `ISandboxStore` seam exists so tests run without a database (`InMemorySandboxStore`); `FixedTimeProvider`
  drives deterministic reaper/manager tests.

## M4 — Web UI (`SwarmSandbox.Web/`) — implemented

- `Services/SandboxApiClient.cs` — typed client over the four endpoints; registered against
  `SANDBOX_API_URL` (falls back to the WASM host origin).
- `Pages/Home.razor` — sandbox list, create form with branch field, delete.
- `Pages/SandboxDetail.razor` — status/logs polling plus the "Connect with ZCode desktop" panel (6-step
  desktop-connect instructions, desktop-verified).
- Web keeps its own DTO copies in `Models/` and must NOT reference the Api project.

## M5 — Validation + CI + e2e — implemented

As-built: the repo-root `validation.ps1` has a `-Step dotnet` branch (solution build + test with XPlat Code
Coverage + ≥85% line-coverage gate), `.github/workflows/ci.yml` pins the .NET SDK via `setup-dotnet`, and
`scripts/e2e-sandbox.ps1` drives the real `DockerSandboxProvisioner` against the local Docker daemon
(reflection-loaded from the built Api DLL, no DB/Aspire host).

## Build & test

```sh
dotnet build src/SwarmSandbox/SwarmSandbox.sln
dotnet test  src/SwarmSandbox/SwarmSandbox.sln
```
