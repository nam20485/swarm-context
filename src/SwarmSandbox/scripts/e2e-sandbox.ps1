#!/usr/bin/env pwsh
<#
.SYNOPSIS
    End-to-end sandbox provisioning proof (module M5): drives the REAL
    DockerSandboxProvisioner class (no DB, no Aspire, no API host).

.DESCRIPTION
    Loads the built SwarmSandbox.Api.dll (src/SwarmSandbox/SwarmSandbox.Api/bin/
    Debug/net10.0/, building it first if missing) into this pwsh process
    (pwsh 7.6 runs on .NET 10, so the net10.0 assemblies load in-process) and
    instantiates DockerSandboxProvisioner via reflection with SandboxOptions:

        ImageName       = swarmsandbox-workspace:latest
        SeedSourcePath  = ''        (seed-skip path)
        RepoUrl         = see PATH DECISION below
        WorkspaceBranch = development
        DefaultTtl      = 00:05:00
        NetworkName     = swarmsandbox (created if absent)

    PATH DECISION (per the M5 task): the provisioner adds no host binds, so the
    smoke-test's "-v bare-repo:/seedrepo:ro" trick cannot be used through it.
    Therefore, at runtime:

      1. If the repo's public GitHub URL resolves anonymously (checked with a
         scrubbed credential config), RepoUrl points at it. The provisioner
         then clones the real 'development' branch into /workspace and the
         happy-path "marker file" is a known committed repo file
         (validation.ps1), the honest equivalent of the bare-repo marker.
      2. Otherwise the provisioner is exercised with a deliberately broken
         RepoUrl; the script asserts graceful behavior (container still
         Running, /workspace-clone-error.txt present) AND additionally proves
         the happy path by invoking the image directly with the bare-repo
         bind, exactly like sandbox/smoke-test.ps1 does.

    In both paths, assertions on the provisioner-created container run via
    docker exec: state Running per GetStatusAsync, `sh -lc 'echo ok'`, uname,
    tar/gzip/git/pwsh present, HOME=/home/sandbox; then StopAsync + RemoveAsync
    and GetStatusAsync must report Removed. Containers, the (script-created)
    network and the temp repo are always cleaned up in `finally`; any failed
    assertion exits non-zero with a clear message. On success a PASS summary
    is printed.

.PARAMETER Tag
    Sandbox image tag to provision. Must already exist locally
    (run src/SwarmSandbox/sandbox/build-sandbox-image.ps1).

.PARAMETER NetworkName
    Docker network to attach provisioned containers to (created if absent).

.PARAMETER Branch
    Workspace branch the provisioner clones.

.PARAMETER CloneTimeoutSeconds
    How long to wait for the container's entrypoint clone to finish.

.PARAMETER PublicRepoUrl
    Public clone URL used for the anonymous-resolution happy path.

.EXAMPLE
    pwsh ../sandbox/build-sandbox-image.ps1
    pwsh ./e2e-sandbox.ps1
#>
param(
    [string]$Tag = 'swarmsandbox-workspace:latest',
    [string]$NetworkName = 'swarmsandbox',
    [string]$Branch = 'development',
    [int]$CloneTimeoutSeconds = 180,
    [string]$PublicRepoUrl = 'https://github.com/nam20485/swarm-context.git'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$seedRoot = Join-Path ([System.IO.Path]::GetTempPath()) "swarmsandbox-e2e-$runId"
$bareDir = Join-Path $seedRoot 'seed-repo.git'
$workDir = Join-Path $seedRoot 'seed-work'
$markerName = 'seed-marker.txt'
$markerValue = 'swarmsandbox-e2e-marker'
$brokenRepoUrl = 'https://swarmsandbox-e2e.invalid/nonexistent.git'

$script:ProvisionerContainer = $null
$script:DirectContainer = $null
$script:NetworkCreated = $false

function Assert-Equal {
    param([string]$Name, [string]$Actual, [string]$Expected)
    if ($Actual -ne $Expected) {
        throw "ASSERTION FAILED [$Name]: expected '$Expected' but got '$Actual'"
    }
    Write-Host "PASS: $Name"
}

function Assert-Contains {
    param([string]$Name, [string]$Actual, [string]$Needle)
    if ($Actual -notlike "*$Needle*") {
        throw "ASSERTION FAILED [$Name]: output does not contain '$Needle'; got '$Actual'"
    }
    Write-Host "PASS: $Name"
}

function Invoke-ContainerExec {
    param([string]$Container, [string]$Command)
    $out = & docker exec $Container sh -lc $Command
    if ($LASTEXITCODE -ne 0) {
        throw "docker exec on '$Container' failed (exit $LASTEXITCODE): sh -lc '$Command'"
    }
    return (($out | Out-String).TrimEnd())
}

function Wait-ForWorkspaceFile {
    param([string]$Container, [string]$ContainerPath, [string]$Description)
    $deadline = [DateTime]::UtcNow.AddSeconds($CloneTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        & docker inspect -f '{{.State.Running}}' $Container *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "Container '$Container' disappeared while waiting for $Description. Check: docker logs $Container"
        }
        & docker exec $Container sh -lc "test -e $ContainerPath" *> $null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Milliseconds 500
    }
    throw "$Description never appeared in container '$Container' within $CloneTimeoutSeconds seconds."
}

function New-SandboxProvisioner {
    param([hashtable]$Settings)

    $binDir = Join-Path $script:RepoRoot 'src/SwarmSandbox/SwarmSandbox.Api/bin/Debug/net10.0'
    $apiDll = Join-Path $binDir 'SwarmSandbox.Api.dll'
    if (-not (Test-Path $apiDll)) {
        Write-Host 'SwarmSandbox.Api.dll not found; building SwarmSandbox.Api...' -ForegroundColor Gray
        & dotnet build (Join-Path $script:RepoRoot 'src/SwarmSandbox/SwarmSandbox.Api/SwarmSandbox.Api.csproj')
        if ($LASTEXITCODE -ne 0) { throw "dotnet build of SwarmSandbox.Api failed (exit $LASTEXITCODE)" }
    }

    # Load the built Api assembly and its dependencies into this process.
    foreach ($dll in (Get-ChildItem $binDir -Filter '*.dll')) {
        try { [System.Reflection.Assembly]::LoadFrom($dll.FullName) | Out-Null } catch { }
    }

    # The Api is a Web SDK app: Microsoft.Extensions.* core assemblies
    # (Logging.Abstractions, Options) come from the ASP.NET Core shared
    # framework and are NOT copied to bin/. Probe shared-framework and NuGet
    # cache locations for them.
    $runtimeDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    $sharedRoot = Split-Path (Split-Path $runtimeDir -Parent) -Parent
    $fxVersion = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription -replace '^.*?(\d+\.\d+\.\d+)$', '$1'
    $frameworkDirs = @(
        (Join-Path $sharedRoot "Microsoft.AspNetCore.App/$fxVersion"),
        (Join-Path $sharedRoot 'Microsoft.AspNetCore.App'),
        $runtimeDir
    ) | Where-Object { Test-Path $_ }
    $nugetRoot = Join-Path $HOME '.nuget/packages'
    foreach ($name in @('Microsoft.Extensions.Logging.Abstractions', 'Microsoft.Extensions.Options')) {
        $candidates = @()
        foreach ($dir in $frameworkDirs) { $candidates += (Join-Path $dir "$name.dll") }
        # The hardcoded 10.0.11 below is version-coupled to the Microsoft.Extensions.*
        # package pins in SwarmSandbox.Api/Tests csproj — update the two together.
        $candidates += (Join-Path $nugetRoot "$($name.ToLowerInvariant())/10.0.11/lib/net10.0/$name.dll")
        foreach ($candidate in $candidates) {
            if (Test-Path $candidate) {
                try { [System.Reflection.Assembly]::LoadFrom($candidate) | Out-Null; break } catch { }
            }
        }
    }

    $optionsType = [SwarmSandbox.Api.Provisioning.SandboxOptions]
    $provisionerType = [SwarmSandbox.Api.Provisioning.DockerSandboxProvisioner]

    $options = [System.Activator]::CreateInstance($optionsType)
    foreach ($key in $Settings.Keys) {
        $optionsType.GetProperty($key).SetValue($options, $Settings[$key])
    }

    # ILogger<DockerSandboxProvisioner> = NullLogger<DockerSandboxProvisioner>.Instance
    # (Instance is a public static readonly field; older shapes had a property.)
    $nullLoggerGeneric = [Microsoft.Extensions.Logging.Abstractions.NullLogger].Assembly.GetType(
        'Microsoft.Extensions.Logging.Abstractions.NullLogger`1')
    $loggerType = $nullLoggerGeneric.MakeGenericType($provisionerType)
    $bindingFlags = [System.Reflection.BindingFlags]'Public,Static'
    $instanceMember = $loggerType.GetField('Instance', $bindingFlags)
    if ($instanceMember) { $logger = $instanceMember.GetValue($null) }
    else { $logger = $loggerType.GetProperty('Instance', $bindingFlags).GetValue($null) }

    # IOptions<SandboxOptions> = Options.Create(options)
    $create = [Microsoft.Extensions.Options.Options].GetMethods() |
        Where-Object { $_.Name -eq 'Create' -and $_.IsGenericMethod } |
        Select-Object -First 1
    $ioptions = $create.MakeGenericMethod($optionsType).Invoke($null, @($options))

    # Public DI ctor: DockerSandboxProvisioner(IOptions<SandboxOptions>, ILogger<...>)
    return [System.Activator]::CreateInstance($provisionerType, @($ioptions, $logger))
}

function Invoke-ProvisionerMethod {
    param($Provisioner, [string]$Method, [object[]]$Arguments)
    $task = $Provisioner.GetType().GetMethod($Method).Invoke($Provisioner, $Arguments)
    return $task.GetAwaiter().GetResult()
}

function Test-AnonymousCloneUrl {
    # Truly anonymous: empty credential helpers + no prompts + no terminal.
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GIT_ASKPASS = 'echo'
    $refs = & git -c credential.helper= -c credential.helper= ls-remote $PublicRepoUrl "refs/heads/$Branch" 2>$null
    return ($LASTEXITCODE -eq 0 -and @($refs).Count -gt 0)
}

function Assert-ContainerBasics {
    param([string]$Container)
    Assert-Equal -Name 'sh -lc echo ok' `
        -Actual (Invoke-ContainerExec -Container $Container -Command 'echo ok') -Expected 'ok'
    Assert-Equal -Name 'uname reports Linux' `
        -Actual (Invoke-ContainerExec -Container $Container -Command 'uname') -Expected 'Linux'
    Assert-Contains -Name 'tar available' `
        -Actual (Invoke-ContainerExec -Container $Container -Command 'tar --version') -Needle 'tar'
    Assert-Contains -Name 'gzip available' `
        -Actual (Invoke-ContainerExec -Container $Container -Command 'gzip --version') -Needle 'gzip'
    Assert-Contains -Name 'git available' `
        -Actual (Invoke-ContainerExec -Container $Container -Command 'git --version') -Needle 'git version'
    Assert-Contains -Name 'pwsh 7 available' `
        -Actual (Invoke-ContainerExec -Container $Container -Command 'pwsh --version') -Needle 'PowerShell 7.'
    Assert-Equal -Name 'login-shell HOME is /home/sandbox' `
        -Actual (Invoke-ContainerExec -Container $Container -Command 'printf %s "$HOME"') -Expected '/home/sandbox'
}

# =============================================================================
# Main
# =============================================================================
try {
    & docker image inspect $Tag *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Image '$Tag' not found locally; run src/SwarmSandbox/sandbox/build-sandbox-image.ps1 first."
    }

    & docker network inspect $NetworkName *> $null
    if ($LASTEXITCODE -ne 0) {
        & docker network create $NetworkName | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "docker network create $NetworkName failed" }
        $script:NetworkCreated = $true
        Write-Host "Created docker network '$NetworkName'."
    }

    $useGitHub = Test-AnonymousCloneUrl
    $repoUrl = if ($useGitHub) { $PublicRepoUrl } else { $brokenRepoUrl }
    Write-Host ''
    if ($useGitHub) {
        Write-Host "PATH: public GitHub URL '$PublicRepoUrl' resolves anonymously -> provisioning against it (happy path through the real provisioner)."
    }
    else {
        Write-Host "PATH: '$PublicRepoUrl' does NOT resolve anonymously -> provisioning with a deliberately broken RepoUrl (graceful-failure assertions) + direct docker run happy-path proof with a bind-mounted bare repo."
    }

    $options = @{
        DockerHost      = 'unix:///var/run/docker.sock'
        ImageName       = $Tag
        SeedSourcePath  = ''
        RepoUrl         = $repoUrl
        GitToken        = ''
        WorkspaceBranch = $Branch
        DefaultTtl      = [TimeSpan]::FromMinutes(5)
        NetworkName     = $NetworkName
        ContainerUser   = '1000:1000'
    }
    $provisioner = New-SandboxProvisioner -Settings $options
    Write-Host "DockerSandboxProvisioner instantiated via reflection from SwarmSandbox.Api.dll."

    $request = [System.Activator]::CreateInstance(
        [SwarmSandbox.Api.Contracts.SandboxRequest], @($Branch))
    $ct = [System.Threading.CancellationToken]::None

    $info = Invoke-ProvisionerMethod -Provisioner $provisioner -Method 'CreateSandboxAsync' -Arguments @($request, $ct)
    $script:ProvisionerContainer = $info.Id
    Assert-Equal -Name 'CreateSandboxAsync returned Running' -Actual "$($info.State)" -Expected 'Running'
    Write-Host "Provisioned container '$($info.Id)' (container id $($info.ContainerId))."

    $status = Invoke-ProvisionerMethod -Provisioner $provisioner -Method 'GetStatusAsync' -Arguments @($script:ProvisionerContainer, $ct)
    Assert-Equal -Name 'GetStatusAsync reports Running' -Actual "$($status.Info.State)" -Expected 'Running'

    Assert-ContainerBasics -Container $script:ProvisionerContainer

    if ($useGitHub) {
        Wait-ForWorkspaceFile -Container $script:ProvisionerContainer -ContainerPath '/workspace/.git/config' -Description 'workspace clone'
        Assert-Equal -Name 'workspace cloned: marker file (committed validation.ps1) exists' `
            -Actual (Invoke-ContainerExec -Container $script:ProvisionerContainer -Command 'test -f /workspace/validation.ps1 && echo present') `
            -Expected 'present'
        Assert-Equal -Name 'workspace is on the development branch' `
            -Actual (Invoke-ContainerExec -Container $script:ProvisionerContainer -Command 'git -C /workspace branch --show-current') `
            -Expected $Branch
    }
    else {
        # Graceful failure: entrypoint records the clone error and stays alive.
        Wait-ForWorkspaceFile -Container $script:ProvisionerContainer -ContainerPath '/workspace-clone-error.txt' -Description 'clone error file'
        Assert-Contains -Name 'clone error file records the broken REPO_URL' `
            -Actual (Invoke-ContainerExec -Container $script:ProvisionerContainer -Command 'cat /workspace-clone-error.txt') `
            -Needle $brokenRepoUrl
        Assert-Equal -Name 'container still Running after failed clone' `
            -Actual (& docker inspect -f '{{.State.Running}}' $script:ProvisionerContainer) `
            -Expected 'true'

        # Happy-path proof without the provisioner: direct docker run with the
        # bare-repo bind (the provisioner itself cannot mount binds).
        New-Item -ItemType Directory -Path $workDir | Out-Null
        & git init -q -b $Branch $workDir
        if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
        Set-Content -Path (Join-Path $workDir $markerName) -Value $markerValue -NoNewline
        & git -C $workDir add $markerName
        & git -C $workDir -c user.name=e2e -c user.email=e2e@example.invalid -c commit.gpgsign=false commit -q -m 'e2e seed'
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
        & git clone -q --bare $workDir $bareDir
        if ($LASTEXITCODE -ne 0) { throw 'git clone --bare failed' }

        $script:DirectContainer = "swarmsandbox-e2e-direct-$runId"
        & docker run -d --name $script:DirectContainer `
            -e REPO_URL=/seedrepo -e "WORKSPACE_BRANCH=$Branch" `
            -v "$($bareDir):/seedrepo:ro" `
            $Tag | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "docker run failed for '$($script:DirectContainer)'" }
        Wait-ForWorkspaceFile -Container $script:DirectContainer -ContainerPath '/workspace/.git/config' -Description 'direct-run workspace clone'
        Assert-Equal -Name 'direct docker run happy path: marker file exists in workspace' `
            -Actual (Invoke-ContainerExec -Container $script:DirectContainer -Command "cat /workspace/$markerName") `
            -Expected $markerValue
    }

    # Lifecycle: stop, remove, and confirm the provisioner reports Removed.
    Invoke-ProvisionerMethod -Provisioner $provisioner -Method 'StopAsync' -Arguments @($script:ProvisionerContainer, $ct) | Out-Null
    Write-Host 'PASS: StopAsync completed'
    Invoke-ProvisionerMethod -Provisioner $provisioner -Method 'RemoveAsync' -Arguments @($script:ProvisionerContainer, $ct) | Out-Null
    Write-Host 'PASS: RemoveAsync completed'
    $final = Invoke-ProvisionerMethod -Provisioner $provisioner -Method 'GetStatusAsync' -Arguments @($script:ProvisionerContainer, $ct)
    Assert-Equal -Name 'GetStatusAsync after RemoveAsync reports Removed' -Actual "$($final.Info.State)" -Expected 'Removed'

    Write-Host ''
    Write-Host 'E2E SANDBOX PROVISIONING: PASS - all assertions succeeded.'
}
catch {
    Write-Host "E2E SANDBOX PROVISIONING FAILED: $($_.Exception.Message)"
    if ($script:ProvisionerContainer) {
        Write-Host "Container logs ($($script:ProvisionerContainer)):"
        & docker logs $script:ProvisionerContainer 2>$null
    }
    if ($script:DirectContainer) {
        Write-Host "Container logs ($($script:DirectContainer)):"
        & docker logs $script:DirectContainer 2>$null
    }
    exit 1
}
finally {
    foreach ($name in @($script:ProvisionerContainer, $script:DirectContainer)) {
        if ($name) { & docker rm -f $name *> $null }
    }
    if ($script:NetworkCreated) { & docker network rm $NetworkName *> $null }
    if (Test-Path $seedRoot) { Remove-Item -Recurse -Force $seedRoot }
}
