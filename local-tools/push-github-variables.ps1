# push-github-variables.ps1
#
# Uploads the 11 NEXT_PUBLIC_* variables required by
# repo/.github/workflows/update-fix-1306.yml (the "build-release" job reads
# them via ${{ vars.* }}) to your fork as GitHub Actions Variables
# (Settings -> Secrets and variables -> Actions -> Variables tab). The target
# owner/repo is auto-detected from the `fork` remote (fallback below).
# Variables (Settings -> Secrets and variables -> Actions -> Variables tab).
#
# Auth: uses the stored git credential for github.com (the same one
# `git push` uses). No `gh` CLI, no PAT to create or paste.
#
# Values: read live from repo/.env.local (single source of truth, never
# hardcoded), so re-running after an .env.local change just works.
#
# Safe to re-run: missing variables are created (POST -> 201), existing ones
# are updated (PATCH after 409 -> 204). Exits 0 only if all 11 succeed.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File push-github-variables.ps1
$ErrorActionPreference = 'Stop'

# TLS 1.2 for Windows PowerShell 5.1; harmless on PowerShell 7.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# Avoid interactive credential prompts (no helper -> fail fast instead).
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'never'

# --- read the stored git credential -----------------------------------------
$credOut = 'protocol=https', 'host=github.com', '' | git credential fill
$token = ($credOut | Where-Object { $_ -like 'password=*' }) -replace '^password=', ''
$token = $token.Trim()
if (-not $token) {
  Write-Output 'No stored GitHub credential found. Run "git fetch" once in the repo (stores it), then retry.'
  exit 1
}

$repoOwnerFallback = 'dvelm'
$repoNameFallback = 'freebuff'
$repo = "$repoOwnerFallback/$repoNameFallback"
# Auto-detect from the `fork` remote of the sibling repo checkout (same
# stderr-capture care as elsewhere: native stderr becomes error records).
$oldEAPr2 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$forkRaw = git -C (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'repo') remote get-url fork 2>&1
$ErrorActionPreference = $oldEAPr2
$forkLines = @($forkRaw | Where-Object { $_ -is [string] } | Where-Object { $_ -match 'github\.com' })
if ($forkLines.Count -gt 0) {
  $u = $forkLines[0].Trim()
  if ($u -match 'github\.com[:/]([^/]+)/([^/]+?)(\.git)?\s*$') {
    $repo = $Matches[1] + '/' + $Matches[2]
  }
}
Write-Output "Target repo: $repo"
$apiBase = "https://api.github.com/repos/$repo/actions/variables"
$headers = @{
  'Authorization' = "Bearer $token"
  'Accept' = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
}

# --- values live from repo/.env.local ---------------------------------------
$envFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'repo\.env.local'
$wanted = @(
  'NEXT_PUBLIC_CB_ENVIRONMENT', 'NEXT_PUBLIC_CODEBUFF_APP_URL',
  'NEXT_PUBLIC_FREEBUFF_APP_URL', 'NEXT_PUBLIC_SUPPORT_EMAIL',
  'NEXT_PUBLIC_POSTHOG_API_KEY', 'NEXT_PUBLIC_POSTHOG_HOST_URL',
  'NEXT_PUBLIC_GRAVITY_PIXEL_ID', 'NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY',
  'NEXT_PUBLIC_STRIPE_CUSTOMER_PORTAL', 'NEXT_PUBLIC_WEB_PORT',
  'NEXT_PUBLIC_TURNSTILE_SITE_KEY'
)
$map = @{}
foreach ($raw in (Get-Content -LiteralPath $envFile)) {
  $line = $raw.Trim()
  if (-not $line -or $line.StartsWith('#')) { continue }
  $parts = $line -split '=', 2
  $val = ''
  if ($parts.Count -gt 1 -and $null -ne $parts[1]) { $val = $parts[1].Trim() }
  $map[$parts[0].Trim()] = $val
}

function Get-HttpCode($errRecord) {
  try { return [int]$errRecord.Exception.Response.StatusCode }
  catch { return -1 }
}

$created = 0; $updated = 0; $failed = 0
foreach ($name in $wanted) {
  $value = $map[$name]
  if ([string]::IsNullOrEmpty($value)) {
    $failed++
    Write-Output "$name -> SKIPPED (not found in .env.local)"
    continue
  }
  $body = @{ name = $name; value = $value } | ConvertTo-Json -Compress
  try {
    Invoke-RestMethod -Uri $apiBase -Method Post -Headers $headers -Body $body `
      -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    $created++
    Write-Output "$name -> created"
    continue
  }
  catch {
    if ((Get-HttpCode $_) -ne 409) {
      $failed++
      Write-Output "$name -> FAILED (HTTP $(Get-HttpCode $_))"
      continue
    }
  }
  try {
    Invoke-RestMethod -Uri "$apiBase/$name" -Method Patch -Headers $headers -Body $body `
      -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    $updated++
    Write-Output "$name -> updated"
  }
  catch {
    $failed++
    Write-Output "$name -> FAILED (HTTP $(Get-HttpCode $_))"
  }
}

Write-Output "---- summary: created=$created updated=$updated failed=$failed ----"
if ($failed -eq 0) {
  Write-Output "Variables now on ${repo}:"
  $list = Invoke-RestMethod -Uri "$apiBase`?per_page=100" -Headers $headers -TimeoutSec 30
  foreach ($v in $list.variables) { Write-Output $v.name }
  exit 0
}
exit 1
