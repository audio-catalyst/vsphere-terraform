<#
.SYNOPSIS
Mirrors the canonical GitHub Actions sources into the .github/ folders that
GitHub actually reads.

.DESCRIPTION
GitHub only discovers workflows in .github/workflows/ and composite actions in
.github/actions/. The editable sources live in github-actions/ so they sit next
to the Azure pipelines; this script copies them into place. Run it after every
edit under github-actions/.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\sync-github-workflows.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Some hosts (and nested invocations) do not populate $PSScriptRoot.
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
  $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
  throw 'Cannot determine the script directory.'
}

$root = Split-Path -Parent $scriptDir
$source = Join-Path $root 'github-actions'
$workflowsDir = Join-Path $root '.github\workflows'
$actionSource = Join-Path $source 'terraform-init\action.yml'
$actionDir = Join-Path $root '.github\actions\terraform-init'

if (-not (Test-Path $source)) {
  throw "Missing source folder: $source"
}
if (-not (Test-Path $actionSource)) {
  throw "Missing composite action: $actionSource"
}

New-Item -ItemType Directory -Path $workflowsDir -Force | Out-Null
New-Item -ItemType Directory -Path $actionDir -Force | Out-Null

$workflows = Get-ChildItem -Path $source -Filter '*.yml' -File
foreach ($file in $workflows) {
  Copy-Item -Path $file.FullName -Destination (Join-Path $workflowsDir $file.Name) -Force
  Write-Host "workflow: $($file.Name)"
}

Copy-Item -Path $actionSource -Destination (Join-Path $actionDir 'action.yml') -Force
Write-Host 'action:   terraform-init/action.yml'
Write-Host 'GitHub Actions files are in sync.'
