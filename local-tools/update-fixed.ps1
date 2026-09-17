# Update fixed freebuff build, fully automatic: sync fix-1306 from the fork
# (a GitHub workflow there keeps it rebased onto latest upstream main and only
# pushes when rebase + tests pass), then retest, rebuild (skipped when already
# current), reinstall freeb, verify.
#
# Usage: double-click update-fixed.bat (same folder), or run:
#   powershell -ExecutionPolicy Bypass -File C:\AI-Programmi\freebuff\update-fixed.ps1
#
# Afterwards just use it:  freeb --cwd <project>
#
# --- CONFIG: machine-specific paths (edit these 2 lines to adopt this script)
$repo = 'C:\AI-Programmi\freebuff\repo'   # local clone of your fork (branch fix-1306)
$installDir = 'C:\Tools\freebuff-fixed'   # where the fixed exe + wasm get installed
# --- end CONFIG --------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$env:Path = "$env:USERPROFILE\.bun\bin;" + $env:Path
$fixedExe = "$installDir\freebuff-fixed.exe"
$fixedWasm = "$installDir\tree-sitter.wasm"
$stampFile = "$installDir\.built-commit"
# Render captured native output (stdout strings + stderr ErrorRecords) as text.
# NOTE: "$record" on an ErrorRecord yields only the type name; the real stderr
# line lives in .Exception.Message (verified by probe).
function Out-NativeText($items) {
  $items | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
  }
}
Set-Location -LiteralPath $repo

# --- preflight -------------------------------------------------------------
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) { throw 'bun not found. Install Bun (validated with 1.3.14) or fix PATH (expected at $env:USERPROFILE\.bun\bin). Aborting.' }
$bunVer = (bun --version).Trim()
if ($bunVer -ne '1.3.14') { Write-Warning "bun is $bunVer; this flow was validated with 1.3.14. Continuing anyway." }
if ((Test-Path -LiteralPath "$repo\.git\rebase-merge") -or (Test-Path -LiteralPath "$repo\.git\rebase-apply")) { throw 'A previous rebase is still in progress. Resolve it first (git status, then git rebase --continue / --abort) and re-run.' }

# 0. Must be on fix-1306 with a clean tree (commit your own edits first).
# NOTE: content diffs, not `git status --porcelain`: with core.autocrlf=true
# this repo re-flags common/src/mcp/__tests__/mapping-contract-server.ts as M
# on pure stat refreshes (blob identical to HEAD, empty `git diff`), which
# falsely aborted every run after a rebase. `-c core.autocrlf=false` silences
# git's LF/CRLF warning at the source: in this shell native-command stderr
# redirection (even 2>$null) still surfaces as error records, which would
# otherwise terminate under Stop (see step 2 note).
$branch = (git branch --show-current).Trim()
if ($branch -ne 'fix-1306') { throw "Run from fix-1306 branch (now on $branch). Aborting." }
$dirtyUnstaged = git -c core.autocrlf=false diff --numstat --ignore-cr-at-eol
$dirtyStaged = git -c core.autocrlf=false diff --cached --numstat --ignore-cr-at-eol
if ($dirtyUnstaged -or $dirtyStaged) { throw "Working tree has uncommitted content changes. Commit them first. Aborting.`n$dirtyStaged`n$dirtyUnstaged" }
# 0b. Normalize phantom-modified entries. `git rebase` uses `git status`
# (not content diffs) for its clean-tree check, and with core.autocrlf=true
# status keeps flagging e.g. mapping-contract-server.ts as ' M' after every
# rebase even though its content diff is empty (worktree bytes hash exactly to
# the HEAD blob; the flag is only the CRLF-roundtrip stat expectation -
# "LF will be replaced by CRLF the next time Git touches it"). Checking out a
# content-clean file cannot lose work (diff is empty by the gate above); it
# just refreshes stat and materializes CRLF per repo policy, letting rebase
# proceed. Only ' M' (unstaged modification) entries with empty content diffs
# are touched; anything else is left for rebase to report.
$oldEAP0 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$flagged = git status --porcelain --untracked-files=no 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match '^ M ' }
$ErrorActionPreference = $oldEAP0
foreach ($line in @($flagged)) {
  $f = $line.Substring(3).Trim().Trim('"')
  if ($f -match ' -> ') { continue }
  $u = git -c core.autocrlf=false diff --numstat --ignore-cr-at-eol -- $f
  $s = git -c core.autocrlf=false diff --cached --numstat --ignore-cr-at-eol -- $f
  if (-not $u -and -not $s) { git checkout -- $f }
}

# 1. Sync local fix-1306 from the fork branch (the update-fix-1306 workflow
# keeps it rebased onto latest upstream main and pushes only green states,
# opening an issue on the fork on any incompatibility instead).
git fetch fork
if ($LASTEXITCODE -ne 0) { throw 'git fetch fork failed (offline?). Aborting.' }
git fetch origin
if ($LASTEXITCODE -ne 0) { throw 'git fetch origin failed (offline?). Aborting.' }
# Retire check: if upstream main already contains the fix, the fork branch is
# obsolete - say so instead of building stale code. (Captured silently: the
# not-present case prints a fatal to stderr, which must not pollute the log.)
$oldEAPr = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$null = git cat-file -e origin/main:packages/agent-runtime/src/util/zod-safe-clone.ts 2>&1
$retired = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $oldEAPr
if ($retired) {
  [console]::beep(880, 350); [console]::beep(660, 350); [console]::beep(880, 550)
  throw '*** UPSTREAM MERGED THE FIX - good news *** Upstream main now contains the MCP schema fix. The fork branch is obsolete: switch to plain upstream (git checkout main) and use the release build instead of freeb. Aborting.'
}
$forkTip = (git rev-parse fork/fix-1306).Trim()
$head = (git rev-parse HEAD).Trim()
if ($head -ne $forkTip) {
  git merge-base --is-ancestor HEAD fork/fix-1306
  $forkAhead = ($LASTEXITCODE -eq 0)
  git merge-base --is-ancestor fork/fix-1306 HEAD
  $localAhead = ($LASTEXITCODE -eq 0)
  if ($forkAhead) {
    git merge --ff-only fork/fix-1306
    if ($LASTEXITCODE -ne 0) { throw 'Fast-forward to fork/fix-1306 failed unexpectedly. Aborting.' }
    Write-Output "Synced to fork fix-1306 ($forkTip)."
  }
  elseif ($localAhead) {
    $n = @(git log --oneline 'fork/fix-1306..HEAD').Count
    Write-Output "Local branch is $n commit(s) ahead of the fork; keeping local (push them to the fork if they should be shared)."
  }
  else {
    # Diverged: the normal case after any upstream update, because the workflow
    # force-pushes the rebased stack (same content, new hashes). If the local
    # side adds no unique patch (git cherry shows no '+' lines), every local
    # commit is already contained in the fork tip, so resetting is lossless
    # (abandoned duplicates stay in the reflog). Anything truly unique aborts.
    # Safe: step 0 already guaranteed no uncommitted worktree changes.
    $cherry = git cherry fork/fix-1306 HEAD
    $unique = @($cherry | Where-Object { $_ -match '^\+ ' })
    if ($unique.Count -eq 0) {
      git reset --hard fork/fix-1306
      if ($LASTEXITCODE -ne 0) { throw 'Reset to fork/fix-1306 failed. Aborting.' }
      Write-Output "Synced to fork fix-1306 ($forkTip) - local replay matched the rebased stack."
    }
    else {
      throw "Local fix-1306 has $($unique.Count) unique commit(s) not in fork/fix-1306. Reconcile manually (git log --oneline --graph HEAD fork/fix-1306) and re-run. Aborting."
    }
  }
}
else {
  Write-Output "Already synced with fork fix-1306 ($head)."
}

# 2. Rebuild SDK (sources may have moved) + quick regression check (no session)
bun run build:sdk
if ($LASTEXITCODE -ne 0) { throw 'build:sdk failed. Aborting.' }
# NOTE: bun writes test progress to stderr. Windows PowerShell 5.1 turns each
# stderr line piped via 2>&1 into an error record, which is terminating under
# $ErrorActionPreference='Stop' above. So capture to a variable with stderr
# merged while relaxed, snapshot $LASTEXITCODE immediately (a later cmdlet
# pipeline must not come between), then render the tail for the log.
$oldEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$agentOut = & bun test packages/agent-runtime/src/__tests__/prompts-schema-handling.test.ts packages/agent-runtime/src/__tests__/mcp-schema-store.test.ts packages/agent-runtime/src/tools/__tests__/parse-raw-custom-tool-call.test.ts packages/agent-runtime/src/tools/__tests__/serve-input-schema.test.ts packages/agent-runtime/src/util/__tests__/json-safe-state.test.ts packages/agent-runtime/src/util/__tests__/to-json-schema.test.ts packages/agent-runtime/src/util/__tests__/zod-safe-clone.test.ts 2>&1
$agentTestsCode = $LASTEXITCODE
Out-NativeText $agentOut | Select-Object -Last 5
Set-Location -LiteralPath "$repo\common"
$mcpOut = & bun test src/mcp/__tests__/mcp-content-mapping.test.ts src/mcp/__tests__/call-mcp-tool-resources.test.ts 2>&1
$mcpTestsCode = $LASTEXITCODE
Out-NativeText $mcpOut | Select-Object -Last 4
Set-Location -LiteralPath $repo
$ErrorActionPreference = $oldEAP
if ($agentTestsCode -ne 0) { throw 'Regression tests failed. Aborting before rebuild.' }
if ($mcpTestsCode -ne 0) { throw 'MCP mapping tests failed. Aborting before rebuild.' }

# 3. Rebuild fixed binary unless the installed one is already current, then
# install to the stable path (freeb launcher unchanged).
$head = (git rev-parse HEAD).Trim()
$envStamp = ''
foreach ($ef in @("$repo\.env.local", "$repo\cli\.env.local")) {
  if (Test-Path -LiteralPath $ef) { $envStamp += (Get-FileHash -LiteralPath $ef -Algorithm SHA256).Hash }
}
$stamp = "$head|$envStamp"
$stamped = ''
if (Test-Path -LiteralPath $stampFile) { $stamped = (Get-Content -LiteralPath $stampFile -Raw).Trim() }
$exeOk = Test-Path -LiteralPath $fixedExe
$wasmOk = Test-Path -LiteralPath $fixedWasm
if (($stamped -eq $stamp) -and $exeOk -and $wasmOk) {
  Write-Output "Already current ($head). Skipping binary rebuild."
}
else {
  # Version tracks the latest upstream release (e.g. 0.0.175-dev), so
  # freeb --version matches the newest official build plus our fix.
  try {
    $npmLatest = (Invoke-RestMethod -Uri 'https://registry.npmjs.org/freebuff/latest' -TimeoutSec 20).version
  }
  catch { $npmLatest = $null }
  if (-not $npmLatest) { Write-Warning 'npm lookup failed, falling back to 0.0.0-dev.'; $npmLatest = '0.0.0' }
  $buildVer = "$npmLatest-dev"
  Write-Output "Building fixed binary as v$buildVer."
  bun freebuff/cli/build.ts $buildVer
  if ($LASTEXITCODE -ne 0) { throw 'build:freebuff failed. Aborting.' }
  $srcExe = "$repo\cli\bin\freebuff.exe"
  $srcWasm = "$repo\cli\bin\tree-sitter.wasm"
  if (-not (Test-Path -LiteralPath $srcExe)) { throw 'Build did not produce cli\bin\freebuff.exe. Aborting.' }
  if (-not (Test-Path -LiteralPath $srcWasm)) { throw 'Build did not produce cli\bin\tree-sitter.wasm. Aborting.' }
  # The installed exe is locked while freeb runs. Wait for it to be exited
  # instead of failing: the script continues by itself afterwards.
  $waited = $false
  while (Get-Process -Name 'freebuff-fixed' -ErrorAction SilentlyContinue) {
    if (-not $waited) { Write-Output 'freeb is still running: exit it (/exit or Ctrl+C) and this script will continue automatically...' }
    $waited = $true
    Start-Sleep -Seconds 5
  }
  Copy-Item -LiteralPath $srcExe -Destination $fixedExe -Force
  Copy-Item -LiteralPath $srcWasm -Destination $fixedWasm -Force
  if ((Get-FileHash -LiteralPath $srcExe).Hash -ne (Get-FileHash -LiteralPath $fixedExe).Hash) { throw 'Exe copy verification failed. Aborting.' }
  if ((Get-FileHash -LiteralPath $srcWasm).Hash -ne (Get-FileHash -LiteralPath $fixedWasm).Hash) { throw 'Wasm copy verification failed. Aborting.' }
  Set-Content -LiteralPath $stampFile -Value $stamp -NoNewline
}

# 4. Confirm the installed build actually works from any folder
& $fixedExe --version
if ($LASTEXITCODE -ne 0) { throw 'Installed freeb failed its --version check. Aborting.' }
$oldEAP4 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$smokeOut = & $fixedExe --smoke-tree-sitter 2>&1
$smokeCode = $LASTEXITCODE
$ErrorActionPreference = $oldEAP4
$smokeText = (Out-NativeText $smokeOut) -join "`n"
if (($smokeCode -ne 0) -or ($smokeText -notmatch 'smoke ok')) { throw "Installed freeb FAILED its tree-sitter smoke test. Aborting.`n$smokeText" }
Write-Output 'tree-sitter smoke ok.'
if (-not (Get-Command freeb -ErrorAction SilentlyContinue)) { Write-Warning 'freeb launcher not found on PATH. Put freeb.bat on PATH, or run the installed freebuff-fixed.exe directly.' }
Write-Output 'OK: fix-1306 synced from fork, tested, rebuilt, installed. Restart any running freeb session.'
Write-Output 'Use it: freeb --cwd <project>'
