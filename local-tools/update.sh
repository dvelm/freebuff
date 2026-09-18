#!/bin/bash
# update.sh - fixed-freebuff updater for bash (git-bash, Linux, macOS).
# Bash port of update-fixed.ps1 (same flow): sync fix-1306 from your fork
# (a GitHub workflow there keeps it rebased onto latest upstream main and only
# pushes green states), then retest, rebuild (skipped when already current),
# reinstall freeb, verify.
#
# --- CONFIG: machine-specific paths (edit these to adopt this script) -------
REPO_DIR="C:/AI-Programmi/freebuff/repo"
INSTALL_DIR="C:/Tools/freebuff-fixed"
# --- end CONFIG ---------------------------------------------------------------
#
# Afterwards just use it:  freeb --cwd <project>
set -u
FIXED_EXE="$INSTALL_DIR/freebuff-fixed.exe"
FIXED_WASM="$INSTALL_DIR/tree-sitter.wasm"
STAMP_FILE="$INSTALL_DIR/.built-commit"
die() { echo "ERROR: $1" >&2; exit 1; }
note() { echo "$1"; }
file_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
proc_running() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*|Windows*) tasklist 2>/dev/null | grep -qi freebuff-fixed ;;
    *) pgrep -f freebuff-fixed >/dev/null 2>&1 ;;
  esac
}
export PATH="$HOME/.bun/bin:$PATH"
cd "$REPO_DIR" || die "cannot cd to $REPO_DIR."
# --- preflight ---------------------------------------------------------------
command -v bun >/dev/null 2>&1 || die "bun not found (expected on PATH, e.g. ~/.bun/bin). Aborting."
BUN_VER="$(bun --version 2>/dev/null | tr -d '[:space:]')"
[ "$BUN_VER" = "1.3.14" ] || echo "WARNING: bun is $BUN_VER; validated with 1.3.14. Continuing anyway."
if [ -d "$REPO_DIR/.git/rebase-merge" ] || [ -d "$REPO_DIR/.git/rebase-apply" ]; then
  die "A previous rebase is still in progress. Resolve it first (git status, then git rebase --continue / --abort) and re-run."
fi
# 0. Must be on fix-1306 with a clean tree (commit your own edits first).
# NOTE: content diffs, not `git status --porcelain`: with core.autocrlf=true
# git can flag files as modified on pure stat refreshes while the content
# diff is empty. `-c core.autocrlf=false` also silences git's LF/CRLF warnings.
branch="$(git branch --show-current | tr -d '[:space:]')"
[ "$branch" = "fix-1306" ] || die "Run from fix-1306 branch (now on $branch). Aborting."
dirty_unstaged="$(git -c core.autocrlf=false diff --numstat --ignore-cr-at-eol)"
dirty_staged="$(git -c core.autocrlf=false diff --cached --numstat --ignore-cr-at-eol)"
if [ -n "$dirty_unstaged" ] || [ -n "$dirty_staged" ]; then
  die "Working tree has uncommitted content changes. Commit them first. Aborting."
fi
# 0b. Normalize phantom-modified entries: `git rebase` uses `git status` (not
# content diffs) for its clean-tree check, and with core.autocrlf=true status
# can flag a file as ' M' after a rebase even though its content diff is empty
# (worktree bytes hash exactly to the HEAD blob). Checking out a content-clean
# file cannot lose work; it just refreshes stat. Anything else is left alone.
flagged="$(git status --porcelain --untracked-files=no | grep -E '^ M ' || true)"
printf '%s\n' "$flagged" | while IFS= read -r line; do
  [ -z "$line" ] && continue
  f="$(printf '%s' "$line" | cut -c4-)"
  f="$(printf '%s' "$f" | sed 's/^"//;s/"$//')"
  case "$f" in *-\>*) continue ;; esac
  u="$(git -c core.autocrlf=false diff --numstat --ignore-cr-at-eol -- "$f")"
  s="$(git -c core.autocrlf=false diff --cached --numstat --ignore-cr-at-eol -- "$f")"
  if [ -z "$u" ] && [ -z "$s" ]; then git checkout -- "$f"; fi
done
# 1. Sync local fix-1306 from the fork branch (the update-fix-1306 workflow
# keeps it rebased onto latest upstream main and pushes only green states,
# opening an issue on the fork on any incompatibility instead).
git fetch fork || die "git fetch fork failed (offline?). Aborting."
git fetch origin || die "git fetch origin failed (offline?). Aborting."
# Retire check: if upstream main already contains the fix, the fork branch is
# obsolete - say so instead of building stale code.
if git cat-file -e "origin/main:packages/agent-runtime/src/util/zod-safe-clone.ts" 2>/dev/null; then
  die "Upstream main now contains the MCP schema fix (marker file present). The fork branch is obsolete: switch to plain upstream (git checkout main) and use the release build. Aborting."
fi
fork_tip="$(git rev-parse fork/fix-1306 | tr -d '[:space:]')"
head="$(git rev-parse HEAD | tr -d '[:space:]')"
if [ "$head" != "$fork_tip" ]; then
  if git merge-base --is-ancestor HEAD fork/fix-1306 2>/dev/null; then fork_ahead=1; else fork_ahead=0; fi
  if git merge-base --is-ancestor fork/fix-1306 HEAD 2>/dev/null; then local_ahead=1; else local_ahead=0; fi
  if [ "$fork_ahead" = 1 ]; then
    git merge --ff-only fork/fix-1306 || die "Fast-forward to fork/fix-1306 failed unexpectedly. Aborting."
    note "Synced to fork fix-1306 ($fork_tip)."
  elif [ "$local_ahead" = 1 ]; then
    n="$(git log --oneline 'fork/fix-1306..HEAD' | wc -l | tr -d ' ')"
    note "Local branch is $n commit(s) ahead of the fork; keeping local (push them to the fork if they should be shared)."
  else
    # Diverged: the normal case after any upstream update, because the workflow
    # force-pushes the rebased stack (same content, new hashes). If the local
    # side adds no unique patch (no '+' lines), every local commit is already
    # contained in the fork tip, so resetting is lossless (abandoned duplicates
    # stay in the reflog). Anything truly unique aborts.
    uniq="$(git cherry fork/fix-1306 HEAD | grep -c -E '^\+ ' || true)"
    if [ "$uniq" = "0" ]; then
      git reset --hard fork/fix-1306 || die "Reset to fork/fix-1306 failed. Aborting."
      note "Synced to fork fix-1306 ($fork_tip) - local replay matched the rebased stack."
    else
      die "Local fix-1306 has $uniq unique commit(s) not in fork/fix-1306. Reconcile manually (git log --oneline --graph HEAD fork/fix-1306) and re-run. Aborting."
    fi
  fi
else
  note "Already synced with fork fix-1306 ($head)."
fi
# 2. Rebuild SDK (sources may have moved) + quick regression check (no session)
bun run build:sdk || die "build:sdk failed. Aborting."
bun test packages/agent-runtime/src/__tests__/prompts-schema-handling.test.ts packages/agent-runtime/src/__tests__/mcp-schema-store.test.ts packages/agent-runtime/src/tools/__tests__/parse-raw-custom-tool-call.test.ts packages/agent-runtime/src/tools/__tests__/serve-input-schema.test.ts packages/agent-runtime/src/util/__tests__/json-safe-state.test.ts packages/agent-runtime/src/util/__tests__/to-json-schema.test.ts packages/agent-runtime/src/util/__tests__/zod-safe-clone.test.ts || die "Regression tests failed. Aborting before rebuild."
(cd common && bun test src/mcp/__tests__/mcp-content-mapping.test.ts src/mcp/__tests__/call-mcp-tool-resources.test.ts) || die "MCP mapping tests failed. Aborting before rebuild."
# 3. Rebuild fixed binary unless the installed one is already current, then
# install to the stable path.
mkdir -p "$INSTALL_DIR"
head="$(git rev-parse HEAD | tr -d '[:space:]')"
env_stamp=""
for ef in "$REPO_DIR/.env.local" "$REPO_DIR/cli/.env.local"; do
  if [ -f "$ef" ]; then env_stamp="$env_stamp$(file_hash "$ef")"; fi
done
stamp="$head|$env_stamp"
stamped=""
if [ -f "$STAMP_FILE" ]; then stamped="$(cat "$STAMP_FILE")"; fi
if [ "$stamped" = "$stamp" ] && [ -f "$FIXED_EXE" ] && [ -f "$FIXED_WASM" ]; then
  note "Already current ($head). Skipping binary rebuild."
else
  # Version tracks the latest upstream release (e.g. 0.0.175-dev), so
  # freeb --version matches the newest official build plus our fix.
  ver="$(bun -e "fetch('https://registry.npmjs.org/freebuff/latest').then(function(r){return r.json()}).then(function(j){console.log(j.version)}).catch(function(){console.log('0.0.0')})" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$ver" ] || ver="0.0.0"
  build_ver="$ver-dev"
  note "Building fixed binary as v$build_ver."
  bun freebuff/cli/build.ts "$build_ver" || die "build:freebuff failed. Aborting."
  [ -f "$REPO_DIR/cli/bin/freebuff.exe" ] || die "Build did not produce cli/bin/freebuff.exe. Aborting."
  [ -f "$REPO_DIR/cli/bin/tree-sitter.wasm" ] || die "Build did not produce cli/bin/tree-sitter.wasm. Aborting."
  # The installed exe is locked while freeb runs. Wait for it to be exited
  # instead of failing: the script continues by itself afterwards.
  waited=0
  while proc_running; do
    if [ "$waited" = 0 ]; then note "freeb is still running: exit it (/exit or Ctrl+C) and this script will continue automatically..."; fi
    waited=1
    sleep 5
  done
  cp -f "$REPO_DIR/cli/bin/freebuff.exe" "$FIXED_EXE"
  cp -f "$REPO_DIR/cli/bin/tree-sitter.wasm" "$FIXED_WASM"
  [ "$(file_hash "$REPO_DIR/cli/bin/freebuff.exe")" = "$(file_hash "$FIXED_EXE")" ] || die "Exe copy verification failed. Aborting."
  [ "$(file_hash "$REPO_DIR/cli/bin/tree-sitter.wasm")" = "$(file_hash "$FIXED_WASM")" ] || die "Wasm copy verification failed. Aborting."
  printf '%s' "$stamp" > "$STAMP_FILE"
fi
# 4. Confirm the installed build actually works from any folder
"$FIXED_EXE" --version || die "Installed freeb failed its --version check. Aborting."
smoke_out="$("$FIXED_EXE" --smoke-tree-sitter 2>&1)"
smoke_code=$?
case "$smoke_out" in
  *"smoke ok"*) smoke_ok=1 ;;
  *) smoke_ok=0 ;;
esac
if [ "$smoke_code" != "0" ] || [ "$smoke_ok" != "1" ]; then
  die "Installed freeb FAILED its tree-sitter smoke test. Aborting."
fi
note "tree-sitter smoke ok."
command -v freeb >/dev/null 2>&1 || echo "WARNING: freeb launcher not found on PATH. Put freeb on PATH, or run the installed freebuff-fixed.exe directly."
note "OK: fix-1306 synced from fork, tested, rebuilt, installed. Restart any running freeb session."
note "Use it: freeb --cwd <project>"
