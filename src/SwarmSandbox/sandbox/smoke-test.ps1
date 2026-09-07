#!/usr/bin/env pwsh
<#
.SYNOPSIS
    End-to-end smoke test for the SwarmSandbox sandbox image (module M2).

.DESCRIPTION
    Requires no GitHub credentials: creates a temporary bare git repo under the
    system temp directory with a `development` branch and a marker file, then
    runs the image twice against it via a read-only bind mount:

      1. Plain clone: REPO_URL=/seedrepo WORKSPACE_BRANCH=development.
      2. Token scrub: same, plus GIT_TOKEN=secret123; asserts the token never
         appears in /workspace/.git/config, /workspace/.git/FETCH_HEAD (removed),
         the container logs, or PID1's environ (entrypoint re-execs without it).

    Asserts, via `docker exec ... sh -lc` (the ZCode desktop's entry mode):
    marker file, sh, tar, gzip, git, pwsh 7, uname, $HOME=/home/sandbox
    (writable, no .zcode seeded), id -u 1000, and a running container.
    Cleans up containers and the temp repo always; exits non-zero with a clear
    message on any failed assertion.

.PARAMETER Tag
    Image tag to test. Must already exist locally (run build-sandbox-image.ps1).

.PARAMETER CloneTimeoutSeconds
    How long to wait for the entrypoint clone to finish.

.EXAMPLE
    pwsh ./build-sandbox-image.ps1; pwsh ./smoke-test.ps1
#>
param(
    [string]$Tag = 'swarmsandbox-workspace:latest',
    [int]$CloneTimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$seedRoot = Join-Path ([System.IO.Path]::GetTempPath()) "swarmsandbox-smoke-$runId"
$workDir = Join-Path $seedRoot 'seed-work'
$bareDir = Join-Path $seedRoot 'seed-repo.git'
$markerName = 'seed-marker.txt'
$markerValue = 'swarmsandbox-smoke-marker'
$container1 = "swarmsandbox-smoke-clone-$runId"
$container2 = "swarmsandbox-smoke-token-$runId"

function Invoke-ContainerExec {
    param([string]$Container, [string]$Command)
    $out = & docker exec $Container sh -lc $Command
    if ($LASTEXITCODE -ne 0) {
        throw "docker exec on '$Container' failed (exit $LASTEXITCODE): sh -lc '$Command'"
    }
    return (($out | Out-String).TrimEnd())
}

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

function Assert-NotContains {
    param([string]$Name, [string]$Actual, [string]$Needle)
    if ($Actual -like "*$Needle*") {
        throw "ASSERTION FAILED [$Name]: output unexpectedly contains '$Needle'"
    }
    Write-Host "PASS: $Name"
}

function Wait-ForClone {
    param([string]$Container)
    $deadline = [DateTime]::UtcNow.AddSeconds($CloneTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        & docker inspect -f '{{.State.Running}}' $Container *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "Container '$Container' disappeared while waiting for its clone (crashed entrypoint?). Check: docker logs $Container"
        }
        & docker exec $Container sh -lc 'test -f /workspace/.git/config' *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "PASS: container '$Container' cloned its workspace"
            return
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Clone in container '$Container' did not complete within $CloneTimeoutSeconds seconds."
}

try {
    & docker image inspect $Tag *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Image '$Tag' not found locally; run build-sandbox-image.ps1 first."
    }

    # --- Seed: temp working repo with a development branch + marker, then a bare clone.
    New-Item -ItemType Directory -Path $workDir | Out-Null
    & git init -q -b development $workDir
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    Set-Content -Path (Join-Path $workDir $markerName) -Value $markerValue -NoNewline
    & git -C $workDir add $markerName
    & git -C $workDir -c user.name=smoke -c user.email=smoke@example.invalid -c commit.gpgsign=false commit -q -m 'smoke seed'
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
    & git clone -q --bare $workDir $bareDir
    if ($LASTEXITCODE -ne 0) { throw 'git clone --bare failed' }
    Write-Host "Seeded bare repo at '$bareDir' (branch 'development')."

    # --- Container 1: plain clone from the mounted seed repo.
    & docker run -d --name $container1 `
        -e REPO_URL=/seedrepo -e WORKSPACE_BRANCH=development `
        -v "$($bareDir):/seedrepo:ro" `
        $Tag | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker run failed for '$container1'" }
    Wait-ForClone -Container $container1

    Assert-Equal -Name 'workspace cloned: marker file exists' `
        -Actual (Invoke-ContainerExec -Container $container1 -Command "cat /workspace/$markerName") `
        -Expected $markerValue
    Assert-Equal -Name 'sh -lc echo ok' `
        -Actual (Invoke-ContainerExec -Container $container1 -Command 'echo ok') `
        -Expected 'ok'
    Assert-Contains -Name 'tar available' `
        -Actual (Invoke-ContainerExec -Container $container1 -Command 'tar --version') `
        -Needle 'tar'
    Assert-Contains -Name 'gzip available' `
        -Actual (Invoke-ContainerExec -Container $container1 -Command 'gzip --version') `
        -Needle 'gzip'
    Assert-Contains -Name 'git available' `
        -Actual (Invoke-ContainerExec -Container $container1 -Command 'git --version') `
        -Needle 'git version'
    Assert-Contains -Name 'pwsh 7 available' `
        -Actual (Invoke-ContainerExec -Container $container1 -Command 'pwsh --version') `
        -Needle 'PowerShell 7.'
    Assert-Equal -Name 'uname reports Linux' `
        -Actual (Invoke-ContainerExec -Container $container1 -Command 'uname') `
        -Expected 'Linux'
    Assert-Equal -Name 'login-shell HOME is /home/sandbox' `
        -Actual (Invoke-ContainerExec -Container $container1 -Command 'printf %s "$HOME"') `
        -Expected '/home/sandbox'
    Assert-Equal -Name 'user id is 1000' `
        -Actual (Invoke-ContainerExec -Container $container1 -Command 'id -u') `
        -Expected '1000'
    Assert-Equal -Name 'HOME is writable' `
        -Actual (Invoke-ContainerExec -Container $container1 -Command 'test -w "$HOME" && echo writable') `
        -Expected 'writable'
    Assert-Equal -Name 'HOME/.zcode not pre-seeded by image' `
        -Actual (Invoke-ContainerExec -Container $container1 -Command 'test ! -e "$HOME/.zcode" && echo absent') `
        -Expected 'absent'
    Assert-Equal -Name 'container is running (sleep infinity)' `
        -Actual (& docker inspect -f '{{.State.Running}}' $container1) `
        -Expected 'true'

    # --- Container 2: GIT_TOKEN=secret123 must never leak into config or logs.
    & docker run -d --name $container2 `
        -e REPO_URL=/seedrepo -e WORKSPACE_BRANCH=development -e GIT_TOKEN=secret123 `
        -v "$($bareDir):/seedrepo:ro" `
        $Tag | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker run failed for '$container2'" }
    Wait-ForClone -Container $container2

    Assert-Contains -Name 'token scrub ran (entrypoint log)' `
        -Actual (& docker logs $container2 | Out-String) `
        -Needle 'Scrubbed credentials'
    Assert-NotContains -Name 'token absent from /workspace/.git/config' `
        -Actual (Invoke-ContainerExec -Container $container2 -Command 'cat /workspace/.git/config') `
        -Needle 'secret123'
    Assert-Equal -Name 'origin remote is token-free' `
        -Actual (Invoke-ContainerExec -Container $container2 -Command 'git -C /workspace remote get-url origin') `
        -Expected '/seedrepo'
    Assert-NotContains -Name 'token absent from container logs' `
        -Actual (& docker logs $container2 | Out-String) `
        -Needle 'secret123'
    Assert-Equal -Name 'FETCH_HEAD (credentialed clone artifact) is removed' `
        -Actual (Invoke-ContainerExec -Container $container2 -Command 'test ! -e /workspace/.git/FETCH_HEAD && echo absent') `
        -Expected 'absent'
    Assert-Equal -Name 'GIT_TOKEN absent from PID1 environ' `
        -Actual (Invoke-ContainerExec -Container $container2 -Command 'tr "\0" "\n" < /proc/1/environ | grep -c GIT_TOKEN || true') `
        -Expected '0'

    Write-Host ''
    Write-Host 'SMOKE TEST: PASS - all sandbox image assertions succeeded.'
}
catch {
    Write-Host "SMOKE TEST FAILED: $($_.Exception.Message)"
    Write-Host "Container logs ($container1):"
    & docker logs $container1 2>$null
    Write-Host "Container logs ($container2):"
    & docker logs $container2 2>$null
    exit 1
}
finally {
    foreach ($name in @($container1, $container2)) {
        & docker rm -f $name *> $null
    }
    if (Test-Path $seedRoot) {
        Remove-Item -Recurse -Force $seedRoot
    }
}
