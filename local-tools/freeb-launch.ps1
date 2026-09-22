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
  $tmp = Join-Path $env:TEMP ("freeb-update-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  # Downloads via curl.exe (not Invoke-WebRequest): binary-safe, follows
  # redirects, no PS 5.1 quirks. Same as the sh port.
  $exeTmp = Join-Path $tmp 'freebuff-fixed.exe'
  $wasmTmp = Join-Path $tmp 'tree-sitter.wasm'
  $dlOk = $true
  $code = & curl.exe -sL --max-time 600 -o "$exeTmp" $rel.exe.browser_download_url 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "exe download failed (curl exit $LASTEXITCODE): $code"
    $dlOk = $false
  }
  # tree-sitter.wasm is platform-independent and rarely changes: the update is
  # not failed over it. Download when the loose asset exists; otherwise keep
  # the installed one (that was the bug: a missing wasm asset aborted the
  # whole update).
  $wasmDownloaded = $false
  if ($dlOk -and $null -ne $rel.wasm -and $null -ne $rel.wasm.browser_download_url) {
    $code = & curl.exe -sL --max-time 120 -o "$wasmTmp" $rel.wasm.browser_download_url 2>&1
    if ($LASTEXITCODE -eq 0 -and (Get-Item -LiteralPath $wasmTmp -ErrorAction SilentlyContinue).Length -gt 0) {
      $wasmDownloaded = $true
    }
    else {
      Write-Host "wasm download failed (curl exit $LASTEXITCODE): $code"
      Write-Host 'Keeping the installed tree-sitter.wasm.'
    }
  }
  if ($dlOk) {
    $ok = $true
    $want = ($rel.exe.digest -replace '^sha256:', '').ToUpper()
    $got = (Get-FileHash -LiteralPath $exeTmp -Algorithm SHA256).Hash
    if ($got -ne $want) {
      Write-Host 'Digest mismatch for freebuff-fixed.exe; keeping current build.'
      $ok = $false
    }
    if ($ok -and $wasmDownloaded -and $null -ne $rel.wasm.digest) {
      $wantW = ($rel.wasm.digest -replace '^sha256:', '').ToUpper()
      $gotW = (Get-FileHash -LiteralPath $wasmTmp -Algorithm SHA256).Hash
      if ($gotW -ne $wantW) {
        Write-Host 'Digest mismatch for tree-sitter.wasm; keeping the installed one.'
        $wasmDownloaded = $false
      }
    }
    if ($ok) {
      Copy-Item -LiteralPath $exeTmp -Destination $exe -Force
      if ($wasmDownloaded) { Copy-Item -LiteralPath $wasmTmp -Destination $wasm -Force }
      Write-Host "Updated to v$($rel.ver)."
    }
  }
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
& $exe @args
exit $LASTEXITCODE
