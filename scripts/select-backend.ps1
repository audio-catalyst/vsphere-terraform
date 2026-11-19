<#
.SYNOPSIS
Selects the remote state backend (Amazon S3 or AzureRM) for every cluster folder.

.DESCRIPTION
Generates backend.tf (with the chosen backend type) and backend.hcl (with the
shared values plus a unique state key) in each folder under -ClustersPath.
Re-run this script whenever you switch cloud providers, then run
`terraform init -reconfigure -backend-config=backend.hcl` in each cluster folder.

.EXAMPLE
Copy-Item backend\aws.hcl.example backend\aws.hcl
.\scripts\select-backend.ps1 -Cloud aws

.EXAMPLE
Copy-Item backend\azure.hcl.example backend\azure.hcl
.\scripts\select-backend.ps1 -Cloud azure -KeyPrefix vsphere
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('aws', 'azure')]
  [string] $Cloud,

  [string] $ClustersPath = '',

  [string] $BackendConfig = '',

  [string] $KeyPrefix = 'vsphere'
)

$ErrorActionPreference = 'Stop'

# Some hosts (and nested invocations) do not populate $PSScriptRoot.
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
  $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
  throw 'Cannot determine the script directory. Pass -ClustersPath and -BackendConfig explicitly.'
}

if ([string]::IsNullOrWhiteSpace($ClustersPath)) {
  $ClustersPath = Join-Path $scriptDir '..\clusters'
}

if ([string]::IsNullOrWhiteSpace($BackendConfig)) {
  $BackendConfig = Join-Path $scriptDir "..\backend\$Cloud.hcl"
}

if (-not (Test-Path $BackendConfig)) {
  throw "Backend config '$BackendConfig' not found. Copy backend\$Cloud.hcl.example to backend\$Cloud.hcl and edit it first."
}

if (-not (Test-Path $ClustersPath)) {
  throw "Clusters path '$ClustersPath' not found."
}

$backendType = switch ($Cloud) {
  'aws'   { 's3' }
  'azure' { 'azurerm' }
}

$shared = (Get-Content $BackendConfig -Raw) -split "`r?`n" |
  Where-Object { $_ -notmatch '^\s*key\s*=' }

$clusters = Get-ChildItem -Path $ClustersPath -Directory

foreach ($cluster in $clusters) {
  $terraformBlock = @"
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    vsphere = {
      source  = "vmware/vsphere"
      version = "~> 2.13"
    }
  }

  backend "$backendType" {}
}
"@

  $key = if ($Cloud -eq 'aws') {
    "$KeyPrefix/$($cluster.Name)/terraform.tfstate"
  }
  else {
    "$KeyPrefix/$($cluster.Name).tfstate"
  }

  Set-Content -Path (Join-Path $cluster.FullName 'backend.tf') -Value $terraformBlock -Encoding utf8
  Set-Content -Path (Join-Path $cluster.FullName 'backend.hcl') `
    -Value (($shared -join "`n") + "`nkey = `"$key`"`n") -Encoding utf8

  Write-Host "[$($cluster.Name)] backend=$backendType key=$key"
}

Write-Host "`nNext, in each cluster folder run:"
Write-Host "  terraform init -reconfigure -backend-config=backend.hcl"
