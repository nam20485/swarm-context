#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds the SwarmSandbox sandbox container image (module M2).

.DESCRIPTION
    Runs `docker build` against this script's directory (the build context
    containing Dockerfile + entrypoint.sh) and fails fast on any error.

.PARAMETER Tag
    Image tag to apply. Defaults to the SANDBOX__IMAGENAME default from
    src/SwarmSandbox/ARCHITECTURE.md.

.EXAMPLE
    pwsh ./build-sandbox-image.ps1
    pwsh ./build-sandbox-image.ps1 -Tag swarmsandbox-workspace:dev
#>
param(
    [string]$Tag = 'swarmsandbox-workspace:latest'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$context = $PSScriptRoot
if (-not (Test-Path (Join-Path $context 'Dockerfile'))) {
    throw "Dockerfile not found next to this script (expected at: $context/Dockerfile)"
}

Write-Host "Building sandbox image '$Tag' from context '$context'..."
docker build -t $Tag $context
if ($LASTEXITCODE -ne 0) {
    throw "docker build failed with exit code $LASTEXITCODE"
}

Write-Host "Built sandbox image '$Tag'."
