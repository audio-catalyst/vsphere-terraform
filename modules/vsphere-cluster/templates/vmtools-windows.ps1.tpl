$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'vmtools-first-boot.log'
Start-Transcript -Path $log -Append | Out-Null

function Get-AnsibleValue {
  param([string]$Encoded)
  if ([string]::IsNullOrEmpty($Encoded)) { return '' }
  return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Encoded))
}

$installerArgs = Get-AnsibleValue '${installer_args_b64}'
if ([string]::IsNullOrWhiteSpace($installerArgs)) {
  $installerArgs = '/S /v"/qn REBOOT=ReallySuppress"'
}

Write-Host "vmtools-first-boot: starting $(Get-Date -Format o)"

# The Tools ISO is attached as a CD-ROM by Terraform. Find the setup binary
# regardless of the drive letter Windows assigns during Sysprep.
$setup = $null
foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
  foreach ($name in @('setup64.exe', 'setup.exe')) {
    $candidate = Join-Path $drive.Root $name
    if (Test-Path -LiteralPath $candidate) {
      $setup = $candidate
      break
    }
  }
  if ($null -ne $setup) { break }
}

if ($null -eq $setup) {
  throw 'VMware Tools installer (setup64.exe or setup.exe) was not found on any CD/DVD drive.'
}

$proc = Start-Process -FilePath $setup -ArgumentList $installerArgs -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -notin @(0, 3010)) {
  throw "VMware Tools installer exited with code $($proc.ExitCode)."
}

Write-Host "vmtools-first-boot: complete $(Get-Date -Format o)"
Stop-Transcript
