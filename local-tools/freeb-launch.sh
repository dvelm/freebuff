#!/bin/sh
# freeb-launch.sh - starts freeb, first checking for updates (like the
# original freebuff updater). POSIX sh port of freeb-launch.ps1. Fail-safe:
# any check or download failure just starts the local build. Override the
# release repo with FREEB_RELEASE_REPO; test the update path with
# FREEB_FORCE_UPDATE=1.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
# Auto-detect the platform binary next to this script (release asset names are
# identical to the binary file names, so the auto-update download maps 1:1).
EXE=''
for cand in freebuff-fixed.exe freebuff-fixed-linux-x64 freebuff-fixed-linux-arm64 freebuff-fixed-macos-arm64 freebuff-fixed-darwin-x64 freebuff-fixed-darwin-arm64 freebuff-fixed; do
  if [ -f "$DIR/$cand" ]; then EXE="$cand"; break; fi
done
WASM="$DIR/tree-sitter.wasm"
REPO="${FREEB_RELEASE_REPO:-dvelm/freebuff}"
TAG="fix-1306-latest"
[ -n "$EXE" ] || { echo "freebuff-fixed binary not found in $DIR"; exit 1; }

file_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; fi
}

ver_gt() {
  # true when $1 is a strictly newer version than $2
  command -v sort >/dev/null 2>&1 || return 1
  [ "$1" != "$2" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V 2>/dev/null | tail -1)" = "$1" ] || return 1
  return 0
}

# Retire check (like the workflow): is the MCP fix marker now in upstream
# main? Loud only when merged; silent otherwise. Test with
# FREEB_UPSTREAM_MARKER_URL. Fail-safe: offline just starts.
marker_url="${FREEB_UPSTREAM_MARKER_URL:-https://raw.githubusercontent.com/CodebuffAI/freebuff/main/packages/agent-runtime/src/util/zod-safe-clone.ts}"
marker_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$marker_url" 2>/dev/null || true)"
if [ "$marker_code" = "200" ]; then
  echo ''
  echo '*** UPSTREAM MERGED THE MCP FIX - good news ***'
  echo 'The original repo now contains this fix. You can switch to the official'
  echo 'freebuff build and retire this fork (update.sh stops building from it).'
  echo ''
fi

local_ver="$("$DIR/$EXE" --version 2>/dev/null | head -1 | tr -d '[:space:]')"
rel_json="$(curl -s --max-time 15 "https://api.github.com/repos/$REPO/releases/tags/$TAG" 2>/dev/null || true)"
rel_ver="$(printf '%s\n' "$rel_json" | grep -oE 'Binary version: [0-9]+\.[0-9]+\.[0-9]+' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
if [ -z "$rel_ver" ]; then
  rel_ver="$(printf '%s\n' "$rel_json" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d 'v' || true)"
fi

needs_update=0
if [ -n "$rel_ver" ]; then
  if [ "${FREEB_FORCE_UPDATE:-0}" = "1" ]; then
    needs_update=1
  elif [ -n "$local_ver" ] && ver_gt "$rel_ver" "$local_ver"; then
    needs_update=1
  fi
fi

if [ "$needs_update" = "1" ]; then
  echo "Updating freeb: v${local_ver:-unknown} -> v$rel_ver-dev ..."
  TMP="$(mktemp -d 2>/dev/null || echo "/tmp/freeb-update-$$")"
  mkdir -p "$TMP"
  # NOTE: -L is required - release URLs redirect, and curl without it saves a
  # 0-byte file (that was the bug: silent empty downloads).
  exe_url="$(printf '%s\n' "$rel_json" | grep -oE "\"browser_download_url\": *\"[^\"]*/$EXE\"" | head -1 | sed 's/^"browser_download_url": *"//;s/"$//')"
  wasm_url="$(printf '%s\n' "$rel_json" | grep -oE '"browser_download_url": *"[^"]*tree-sitter\.wasm"' | head -1 | sed 's/^"browser_download_url": *"//;s/"$//')"
  sums_url="$(printf '%s\n' "$rel_json" | grep -oE '"browser_download_url": *"[^"]*SHA256SUMS\.txt"' | head -1 | sed 's/^"browser_download_url": *"//;s/"$//')"
  if curl -sL --max-time 600 "$exe_url" -o "$TMP/freebuff-fixed.exe" 2>/dev/null &&
    curl -sL --max-time 120 "$wasm_url" -o "$TMP/tree-sitter.wasm" 2>/dev/null &&
    [ -s "$TMP/freebuff-fixed.exe" ] && [ -s "$TMP/tree-sitter.wasm" ]; then
    ok=1
    if [ -n "$sums_url" ] && curl -sL --max-time 30 "$sums_url" -o "$TMP/SHA256SUMS.txt" 2>/dev/null && [ -s "$TMP/SHA256SUMS.txt" ]; then
      want_exe="$(grep -E 'freebuff-fixed\.exe' "$TMP/SHA256SUMS.txt" | cut -d' ' -f1 | tr -d '[:space:]')"
      want_wasm="$(grep -E 'tree-sitter\.wasm' "$TMP/SHA256SUMS.txt" | cut -d' ' -f1 | tr -d '[:space:]')"
      got_exe="$(file_hash "$TMP/freebuff-fixed.exe")"
      got_wasm="$(file_hash "$TMP/tree-sitter.wasm")"
      if [ -n "$want_exe" ] && [ "$got_exe" != "$want_exe" ]; then
        echo "Digest mismatch for freebuff-fixed.exe; keeping the current build."
        ok=0
      fi
      if [ -n "$want_wasm" ] && [ "$got_wasm" != "$want_wasm" ]; then
        echo "Digest mismatch for tree-sitter.wasm; keeping the current build."
        ok=0
      fi
    fi
    if [ "$ok" = "1" ]; then
      cp -f "$TMP/freebuff-fixed.exe" "$DIR/$EXE" &&
        cp -f "$TMP/tree-sitter.wasm" "$WASM" &&
        echo "Updated to v$rel_ver-dev."
    fi
  else
    echo "Update download failed; starting the current build."
  fi
  rm -rf "$TMP"
fi

exec "$DIR/$EXE" "$@"
