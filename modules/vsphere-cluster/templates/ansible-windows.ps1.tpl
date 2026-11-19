$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'ansible-first-boot.log'
Start-Transcript -Path $log -Append | Out-Null

function Get-AnsibleValue {
  param([string]$Encoded)
  if ([string]::IsNullOrEmpty($Encoded)) { return '' }
  return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Encoded))
}

$repo          = Get-AnsibleValue '${repo_b64}'
$playbook      = Get-AnsibleValue '${playbook_b64}'
$branch        = Get-AnsibleValue '${branch_b64}'
$directory     = Get-AnsibleValue '${directory_b64}'
$requirements  = Get-AnsibleValue '${requirements_b64}'
$packageName   = Get-AnsibleValue '${package_b64}'
$extraVarsJson = Get-AnsibleValue '${extra_vars_b64}'

Write-Host "ansible-first-boot: starting $(Get-Date -Format o)"

if ('${install_packages}' -eq 'true') {
  if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'Python is required to install ansible-core on Windows. Install Python first or set ansible.install_packages to false.'
  }
  & python -m pip install --upgrade pip
  if ($LASTEXITCODE -ne 0) { throw 'pip upgrade failed' }
  & python -m pip install $packageName
  if ($LASTEXITCODE -ne 0) { throw "installing $packageName failed" }
}

if ('${run_pull}' -eq 'true') {
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  $extraVarsPath = Join-Path $directory '.ansible-extra-vars.json'
  [IO.File]::WriteAllText($extraVarsPath, $extraVarsJson, (New-Object Text.UTF8Encoding($false)))

  $pull = $null
  try {
    $pull = (Get-Command ansible-pull -ErrorAction Stop).Source
  }
  catch {
    $scripts = & python -c "import sysconfig; print(sysconfig.get_path('scripts'))"
    $pull = Join-Path $scripts 'ansible-pull.exe'
  }

  $pullArgs = @('-U', $repo, '-b', $branch, '-d', $directory, '-i', 'localhost,', '-e', "@$extraVarsPath")
  if (-not [string]::IsNullOrEmpty($requirements)) {
    $pullArgs += @('-r', $requirements)
  }
  $pullArgs += $playbook

  & $pull @pullArgs
  if ($LASTEXITCODE -ne 0) { throw 'ansible-pull failed' }
}

Write-Host "ansible-first-boot: complete $(Get-Date -Format o)"
Stop-Transcript
