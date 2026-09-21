# freeb-launch.ps1 - starts freeb, first checking for updates (like the
# original freebuff updater): compares the installed binary version with the
# latest published release and self-updates exe+wasm (digest-verified) before
# starting. Fail-safe: any check or download failure just starts the local
# build. Override the release repo with FREEB_RELEASE_REPO; test the update
# path with FREEB_FORCE_UPDATE=1.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $dir 'freebuff-fixed.exe'
$wasm = Join-Path $dir 'tree-sitter.wasm'
$repo = if ($env:FREEB_RELEASE_REPO) { $env:FREEB_RELEASE_REPO } else { 'dvelm/freebuff' }
$tag = 'fix-1306-latest'
if (-not (Test-Path -LiteralPath $exe)) {
  Write-Host "freebuff-fixed.exe not found in $dir"
  exit 1
}

function Get-LocalVersion {
  try {
    $v = (& $exe --version 2>$null | Select-Object -First 1)
    if ($null -eq $v) { return '' }
    return $v.ToString().Trim()
  }
  catch { return '' }
}

function Get-ReleaseInfo {
  try {
    $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/tags/$tag" -TimeoutSec 15
    $ver = $null
    if ($null -ne $r.body -and $r.body -match 'Binary version: (\d+\.\d+\.\d+)-dev') {
      $ver = $Matches[1] + '-dev'
    }
    elseif ($null -ne $r.name -and $r.name -match 'v(\d+\.\d+\.\d+)-dev') {
      $ver = $Matches[1] + '-dev'
    }
    $exeAsset = $r.assets | Where-Object { $_.name -eq 'freebuff-fixed.exe' } | Select-Object -First 1
    $wasmAsset = $r.assets | Where-Object { $_.name -eq 'tree-sitter.wasm' } | Select-Object -First 1
    return @{ ver = $ver; exe = $exeAsset; wasm = $wasmAsset }
  }
  catch { return $null }
}

function VersionGreater($a, $b) {
  # true when version string $a is newer than $b (numeric x.y.z compare)
  try {
    $pa = ($a -replace '-dev', '') -split '\.' | ForEach-Object { [int]$_ }
    $pb = ($b -replace '-dev', '') -split '\.' | ForEach-Object { [int]$_ }
    for ($i = 0; $i -lt 3; $i++) {
      $xa = 0; $xb = 0
      if ($pa.Count -gt $i) { $xa = $pa[$i] }
      if ($pb.Count -gt $i) { $xb = $pb[$i] }
      if ($xa -gt $xb) { return $true }
      if ($xa -lt $xb) { return $false }
    }
    return $false
  }
  catch { return $false }
}

# Retire check (like the workflow): is the MCP fix marker now in upstream
# main? Loud only when merged; silent otherwise. Test with
# FREEB_UPSTREAM_MARKER_URL. Fail-safe: offline just starts.
$markerUrl = if ($env:FREEB_UPSTREAM_MARKER_URL) { $env:FREEB_UPSTREAM_MARKER_URL } else { 'https://raw.githubusercontent.com/CodebuffAI/freebuff/main/packages/agent-runtime/src/util/zod-safe-clone.ts' }
try {
  $markerResp = Invoke-WebRequest -Uri $markerUrl -TimeoutSec 15 -UseBasicParsing
  if ($markerResp.StatusCode -eq 200) {
    Write-Host ''
    [console]::beep(880, 350); [console]::beep(660, 350); [console]::beep(880, 550)
    Write-Host '*** UPSTREAM MERGED THE MCP FIX - good news ***'
    Write-Host 'The original repo now contains this fix. You can switch to the official'
    Write-Host 'freebuff build and retire this fork (update-fixed.bat stops building from it).'
    Write-Host ''
  }
}
catch { }

$local = Get-LocalVersion
$rel = Get-ReleaseInfo
$force = ($env:FREEB_FORCE_UPDATE -eq '1')
$needsUpdate = $false
if ($rel -and $rel.ver) {
  if ($force) { $needsUpdate = $true }
  elseif ($local -and (VersionGreater $rel.ver $local)) { $needsUpdate = $true }
}

if ($needsUpdate) {
  Write-Host "Updating freeb: v$local -> v$($rel.ver) ..."
  try {
    $tmp = Join-Path $env:TEMP ("freeb-update-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    Invoke-WebRequest -Uri $rel.exe.browser_download_url -OutFile (Join-Path $tmp 'freebuff-fixed.exe') -TimeoutSec 600
    Invoke-WebRequest -Uri $rel.wasm.browser_download_url -OutFile (Join-Path $tmp 'tree-sitter.wasm') -TimeoutSec 120
    $ok = $true
    foreach ($pair in @(@('freebuff-fixed.exe', $rel.exe), @('tree-sitter.wasm', $rel.wasm))) {
      $name = $pair[0]; $asset = $pair[1]
      if ($null -eq $asset -or $null -eq $asset.digest) { continue }
      $want = ($asset.digest -replace '^sha256:', '').ToUpper()
      $got = (Get-FileHash -LiteralPath (Join-Path $tmp $name) -Algorithm SHA256).Hash
      if ($got -ne $want) {
        Write-Host "Digest mismatch for $name; keeping current build."
        $ok = $false
      }
    }
    if ($ok) {
      Copy-Item -LiteralPath (Join-Path $tmp 'freebuff-fixed.exe') -Destination $exe -Force
      Copy-Item -LiteralPath (Join-Path $tmp 'tree-sitter.wasm') -Destination $wasm -Force
      Write-Host "Updated to v$($rel.ver)."
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  catch {
    Write-Host "Update download failed; starting the current build."
  }
}

& $exe @args
exit $LASTEXITCODE
