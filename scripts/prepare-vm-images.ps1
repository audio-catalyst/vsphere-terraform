<#
.SYNOPSIS
Downloads, verifies and registers Linux VM images as vCenter templates.

.DESCRIPTION
Reads images/catalog.json plus the cluster machine JSON files and works out
which OS images are needed. For every Linux image it:

  1. downloads the LinuxVMImages 7z archive (SourceForge),
  2. verifies the published MD5 and SHA-1, caching a locally computed SHA-256,
  3. extracts the VMware VM (VMX + VMDK),
  4. uploads it to a datastore folder with govc, and
  5. registers it as a vCenter template with `govc vm.register -template`.

Templates that are already registered are skipped, so the script is safe to
re-run. Windows images are never downloaded: the script only verifies that the
template named in the catalog already exists in vCenter.

Required tools: govc (https://github.com/vmware/govmomi/releases) and 7z
(p7zip-full on Linux, 7-Zip on Windows). Paths can be supplied with -GovcPath
and -SevenZipPath. Connection settings come from environment variables:
VSPHERE_SERVER, VSPHERE_USER, TF_VAR_vsphere_password, DATACENTER_NAME and
DATASTORE_NAME.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\prepare-vm-images.ps1 -ClusterName CLUSTER-PROD-01

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\prepare-vm-images.ps1 -All -DryRun
#>
[CmdletBinding()]
param(
  [string] $CatalogPath = '',
  [string] $ClustersPath = '',
  [string] $CachePath = '',
  [string] $ClusterName = '',
  [switch] $All,
  [switch] $DryRun,
  [string] $GovcPath = '',
  [string] $SevenZipPath = '',
  [string] $VSphereServer = $env:VSPHERE_SERVER,
  [string] $VSphereUser = $env:VSPHERE_USER,
  [string] $VSpherePassword = $env:TF_VAR_vsphere_password,
  [string] $DatacenterName = $env:DATACENTER_NAME,
  [string] $DatastoreName = $env:DATASTORE_NAME,
  [string] $TemplateFolder = '',
  [string] $TemplateHost = $env:VSPHERE_TEMPLATE_HOST,
  [switch] $AllowUnverifiedSsl
)

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

if ([string]::IsNullOrWhiteSpace($CatalogPath)) { $CatalogPath = Join-Path (Join-Path $root 'images') 'catalog.json' }
if ([string]::IsNullOrWhiteSpace($ClustersPath)) { $ClustersPath = Join-Path $root 'clusters' }
if ([string]::IsNullOrWhiteSpace($CachePath)) { $CachePath = Join-Path (Join-Path $root 'images') '.cache' }
if (-not (Test-Path $CatalogPath)) { throw "Missing image catalog: $CatalogPath" }
if (-not (Test-Path $ClustersPath)) { throw "Missing clusters folder: $ClustersPath" }

$catalog = Get-Content -Path $CatalogPath -Raw | ConvertFrom-Json
if (-not $catalog.images) { throw "No 'images' array in $CatalogPath" }

$imageMap = @{}
foreach ($image in @($catalog.images)) {
  $variant = if ($image.variant) { [string]$image.variant } else { 'default' }
  $key = "$($image.os)|$($image.version)|$variant"
  $imageMap[$key] = $image
}

# Build the set of catalog keys referenced by the cluster JSON files.
$keys = @()
if ($All) {
  $keys = @($imageMap.Keys)
} else {
  if ($ClusterName) {
    $clusterDirs = @(Get-Item -Path (Join-Path $ClustersPath $ClusterName) -ErrorAction Stop)
  } else {
    $clusterDirs = @(Get-ChildItem -Path $ClustersPath -Directory)
  }

  foreach ($clusterDir in $clusterDirs) {
    $machineDir = Join-Path $clusterDir.FullName 'machines'
    $clusterConfigPath = Join-Path $clusterDir.FullName 'cluster.json'

    # A template registration needs a host. Reuse the first host of each
    # cluster unless one was supplied explicitly.
    if (-not $TemplateHost -and (Test-Path $clusterConfigPath)) {
      $clusterConfig = Get-Content -Path $clusterConfigPath -Raw | ConvertFrom-Json
      if ($clusterConfig.esxi_hosts -and @($clusterConfig.esxi_hosts).Count -gt 0) {
        $TemplateHost = [string]@($clusterConfig.esxi_hosts)[0]
      }
    }

    if (-not (Test-Path $machineDir)) { continue }
    foreach ($file in Get-ChildItem -Path $machineDir -Filter '*.json' -File) {
      $machine = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
      if (-not $machine.os) { continue }
      $variant = if ($machine.variant) { [string]$machine.variant } else { 'default' }
      $key = "$($machine.os)|$($machine.version)|$variant"
      if (-not $imageMap.ContainsKey($key)) {
        throw "Machine $($machine.name) requests '$key' but it is not in images/catalog.json."
      }
      if ($keys -notcontains $key) { $keys += $key }
    }
  }
}

if ($keys.Count -eq 0) {
  Write-Host 'No OS images are referenced by the selected clusters. Nothing to do.'
  return
}

if ([string]::IsNullOrWhiteSpace($TemplateFolder)) {
  $TemplateFolder = if ($catalog.defaults -and $catalog.defaults.templateFolder) { [string]$catalog.defaults.templateFolder } else { 'TerraformTemplates' }
}
$TemplateFolder = $TemplateFolder.Replace('\', '/').Trim('/')
if ([string]::IsNullOrWhiteSpace($TemplateFolder)) { throw 'Template folder must not be empty.' }

$archiveDir = Join-Path $CachePath 'archives'
$extractDir = Join-Path $CachePath 'extracted'
if (-not $DryRun) {
  New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
  New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
}

function Resolve-Tool {
  param(
    [string] $Explicit,
    [string[]] $Names,
    [string[]] $ExtraPaths
  )
  if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
    if (Test-Path $Explicit) { return (Resolve-Path -Path $Explicit).Path }
    $found = Get-Command $Explicit -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    throw "Tool not found: $Explicit"
  }
  foreach ($name in $Names) {
    $found = Get-Command $name -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
  }
  foreach ($path in $ExtraPaths) {
    if ($path -and (Test-Path $path)) { return (Resolve-Path -Path $path).Path }
  }
  return $null
}

$toolsDir = Join-Path $root 'tools'
$resolvedGovc = $null
$resolved7z = $null
if (-not $DryRun) {
  foreach ($required in @(
      @{ Name = 'VSPHERE_SERVER'; Value = $VSphereServer },
      @{ Name = 'VSPHERE_USER'; Value = $VSphereUser },
      @{ Name = 'TF_VAR_vsphere_password'; Value = $VSpherePassword },
      @{ Name = 'DATACENTER_NAME'; Value = $DatacenterName },
      @{ Name = 'DATASTORE_NAME'; Value = $DatastoreName },
      @{ Name = 'template host'; Value = $TemplateHost })) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
      throw "Missing required setting: $($required.Name). Pass it as a parameter or environment variable."
    }
  }

  $resolvedGovc = Resolve-Tool -Explicit $GovcPath -Names @('govc') -ExtraPaths @(
    (Join-Path $toolsDir 'govc'), (Join-Path $toolsDir 'govc.exe'))
  if (-not $resolvedGovc) {
    throw 'govc not found. Install it from https://github.com/vmware/govmomi/releases or pass -GovcPath.'
  }

  $resolved7z = Resolve-Tool -Explicit $SevenZipPath -Names @('7z', '7zz', '7za') -ExtraPaths @(
    (Join-Path $toolsDir '7z'), (Join-Path $toolsDir '7z.exe'),
    (Join-Path ${env:ProgramFiles} '7-Zip\7z.exe'))
  if (-not $resolved7z) {
    throw '7z not found. Install p7zip-full (Linux) or 7-Zip (Windows), or pass -SevenZipPath.'
  }

  $env:GOVC_URL = "https://$VSphereServer/sdk"
  $env:GOVC_USERNAME = $VSphereUser
  $env:GOVC_PASSWORD = $VSpherePassword
  $env:GOVC_INSECURE = if ($AllowUnverifiedSsl) { '1' } else { '0' }
  $env:GOVC_DATACENTER = $DatacenterName
  $env:GOVC_DATASTORE = $DatastoreName
}

function Invoke-Govc {
  param([string[]] $Arguments)
  $output = & $resolvedGovc @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "govc $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  return $output
}

function Test-TemplateExists {
  param([string] $Name)
  $output = @(& $resolvedGovc find -type m -name $Name 2>$null)
  if ($LASTEXITCODE -ne 0) { return $false }
  $suffix = "/$Name"
  foreach ($line in $output) {
    if ([string]$line -ne '' -and ([string]$line).TrimEnd().EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }
  return $false
}

function Save-Archive {
  param([string] $Url, [string] $Destination)
  $temporary = "$Destination.part"
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      Invoke-WebRequest -Uri $Url -OutFile $temporary -MaximumRedirection 20 -TimeoutSec 3600 -ErrorAction Stop
      break
    } catch {
      if (Test-Path $temporary) { Remove-Item -Path $temporary -Force }
      if ($attempt -eq 3) { throw }
      Write-Host "    download attempt $attempt failed; retrying..."
    }
  }

  # A SourceForge mirror can return an HTML page instead of the archive.
  $stream = [System.IO.File]::OpenRead($temporary)
  try {
    $magic = New-Object byte[] 6
    [void]$stream.Read($magic, 0, 6)
  } finally {
    $stream.Dispose()
  }
  $signature = [System.BitConverter]::ToString($magic)
  if ($signature -ne '37-7A-BC-AF-27-1C') {
    Remove-Item -Path $temporary -Force
    throw "Downloaded file is not a 7z archive (signature $signature). Check downloadUrl in the catalog."
  }
  Move-Item -Path $temporary -Destination $Destination -Force
}

function Test-ArchiveChecksum {
  param([string] $Path, $Image)
  $sidecar = "$Path.sha256"
  $sha256 = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()

  if (Test-Path $sidecar) {
    $cached = (Get-Content -Path $sidecar -Raw).Trim().ToLowerInvariant()
    if ($cached -eq $sha256) {
      Write-Host '    SHA-256 cache hit; skipping published MD5/SHA-1.'
      return
    }
    Write-Host '    SHA-256 cache is stale; re-checking published MD5/SHA-1.'
  }

  $md5 = (Get-FileHash -Algorithm MD5 -Path $Path).Hash.ToLowerInvariant()
  $sha1 = (Get-FileHash -Algorithm SHA1 -Path $Path).Hash.ToLowerInvariant()
  $expectedMd5 = ([string]$Image.md5).ToLowerInvariant()
  $expectedSha1 = ([string]$Image.sha1).ToLowerInvariant()

  if ($md5 -ne $expectedMd5 -or $sha1 -ne $expectedSha1) {
    Remove-Item -Path $Path -Force
    if (Test-Path $sidecar) { Remove-Item -Path $sidecar -Force }
    throw "Checksum mismatch for $([string]$Image.fileName). Expected MD5 $expectedMd5 / SHA-1 $expectedSha1, got MD5 $md5 / SHA-1 $sha1."
  }

  Set-Content -Path $sidecar -Value $sha256 -NoNewline
  Write-Host '    MD5 and SHA-1 verified against catalog; SHA-256 cached.'
}

function Get-ArchiveFiles {
  param([string] $Archive, [string] $Destination)
  $output = & $resolved7z x -y "-o$Destination" $Archive 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "7z extraction failed: $($output -join [Environment]::NewLine)"
  }
  $vmx = @(Get-ChildItem -Path $Destination -Recurse -File -Filter '*.vmx' | Select-Object -First 1)
  if ($vmx.Count -eq 0) { throw "No .vmx file found in $Archive" }
  $disks = @(Get-ChildItem -Path $Destination -Recurse -File -Filter '*.vmdk')
  if ($disks.Count -eq 0) { throw "No .vmdk file found in $Archive" }
  return $vmx[0]
}

Write-Host "=== Preparing OS images (template folder: $TemplateFolder) ==="
if ($DryRun) { Write-Host 'DRY RUN - no downloads, uploads or registrations will be performed.' }

$failures = 0
foreach ($key in ($keys | Sort-Object)) {
  $image = $imageMap[$key]
  $templateName = [string]$image.templateName
  Write-Host ""
  Write-Host "--- $key -> $templateName ---"

  if ($DryRun) {
    if ($image.kind -eq 'windows') {
      Write-Host "  WOULD VERIFY WINDOWS TEMPLATE: $templateName"
    } else {
      Write-Host "  WOULD DOWNLOAD: $([string]$image.downloadUrl)"
      Write-Host "  WOULD VERIFY:   MD5 $([string]$image.md5) / SHA-1 $([string]$image.sha1)"
      Write-Host "  WOULD REGISTER: $TemplateFolder/$templateName from $([string]$image.fileName)"
    }
    continue
  }

  try {
    if (-not (Test-TemplateExists -Name $templateName)) {
      if ($image.kind -eq 'windows') {
        throw "Windows template '$templateName' does not exist in vCenter. Create it yourself and update images/catalog.json if you use a different name."
      }

      $archivePath = Join-Path $archiveDir ([string]$image.fileName)
      if (-not (Test-Path $archivePath)) {
        Write-Host '  downloading archive...'
        Save-Archive -Url ([string]$image.downloadUrl) -Destination $archivePath
      } else {
        Write-Host "  using cached archive: $archivePath"
      }
      Test-ArchiveChecksum -Path $archivePath -Image $image

      $safeKey = ($key -replace '[^A-Za-z0-9_.-]', '-')
      $destination = Join-Path $extractDir $safeKey
      if (-not (Test-Path $destination)) {
        Write-Host '  extracting VM...'
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        $vmx = Get-ArchiveFiles -Archive $archivePath -Destination $destination
      } else {
        $vmx = @(Get-ChildItem -Path $destination -Recurse -File -Filter '*.vmx' | Select-Object -First 1)
        if ($vmx.Count -eq 0) { throw "Extracted folder $destination has no .vmx file; delete it and re-run." }
        $vmx = $vmx[0]
      }

      $vmxDirectory = Split-Path -Parent $vmx.FullName
      $remoteRoot = "$TemplateFolder/$templateName"
      Write-Host "  uploading VM files to [$DatastoreName] $remoteRoot ..."
      Invoke-Govc @('datastore.mkdir', '-p', $remoteRoot) | Out-Null
      foreach ($file in Get-ChildItem -Path $vmxDirectory -Recurse -File) {
        $relative = $file.FullName.Substring($vmxDirectory.Length).TrimStart('\', '/').Replace('\', '/')
        Invoke-Govc @('datastore.upload', "-ds=$DatastoreName", $file.FullName, "$remoteRoot/$relative") | Out-Null
      }

      $vmxRelative = $vmx.FullName.Substring($vmxDirectory.Length).TrimStart('\', '/').Replace('\', '/')
      Write-Host '  registering template...'
      Invoke-Govc @('vm.register', '-template', "-host=$TemplateHost", "-ds=$DatastoreName", "-name=$templateName", "$remoteRoot/$vmxRelative") | Out-Null
      Write-Host '  template registered.'
    } else {
      Write-Host '  template already registered; skipping.'
    }
  } catch {
    $failures++
    Write-Host "  FAILED: $($_.Exception.Message)"
  }
}

Write-Host ""
Write-Host "=== Done. $($keys.Count) image(s) processed, $failures failure(s). ==="
if ($failures -gt 0) { exit 1 }
