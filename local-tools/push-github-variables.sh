#!/bin/bash
# push-github-variables.sh
#
# Bash port of push-github-variables.ps1 (same behavior): reads the 11
# NEXT_PUBLIC_* values live from repo/.env.local and creates/updates them
# as GitHub Actions Variables on your fork (Settings -> Secrets and
# variables -> Actions -> Variables tab). Auth via the stored git credential
# for github.com (the same one `git push` uses). No `gh` CLI needed.
#
# Owner/repo are auto-detected from the `fork` remote of the repo checkout
# that sits beside this script (folder layout: this script next to `repo/`).
#
# Safe to re-run: missing variables are created (POST), existing ones are
# updated (PATCH after 409). Exits 0 only if all 11 succeed.
#
# Usage (git-bash):  bash push-github-variables.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/repo/.env.local"
WANTED="NEXT_PUBLIC_CB_ENVIRONMENT NEXT_PUBLIC_CODEBUFF_APP_URL NEXT_PUBLIC_FREEBUFF_APP_URL NEXT_PUBLIC_SUPPORT_EMAIL NEXT_PUBLIC_POSTHOG_API_KEY NEXT_PUBLIC_POSTHOG_HOST_URL NEXT_PUBLIC_GRAVITY_PIXEL_ID NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY NEXT_PUBLIC_STRIPE_CUSTOMER_PORTAL NEXT_PUBLIC_WEB_PORT NEXT_PUBLIC_TURNSTILE_SITE_KEY"

export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=never

cred=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null)
token=$(printf '%s\n' "$cred" | sed -n 's/^password=//p' | head -1)
token=$(printf '%s' "$token" | tr -d '\r\n ')
if [ -z "$token" ]; then
  echo "No stored GitHub credential found. Run 'git fetch' once in the repo (stores it), then retry."
  exit 1
fi

REPO="dvelm/freebuff"
if git -C "$SCRIPT_DIR/repo" remote get-url fork >/dev/null 2>&1; then
  url=$(git -C "$SCRIPT_DIR/repo" remote get-url fork)
  parsed=$(printf '%s' "$url" | sed -E 's#.*github\.com[:/]([^/]+)/([^/]+)#\1/\2#')
  parsed=${parsed%.git}
  if [ -n "$parsed" ]; then REPO="$parsed"; fi
fi
echo "Target repo: $REPO"
APIBASE="https://api.github.com/repos/$REPO/actions/variables"
AUTH_H=("Authorization: Bearer $token" "Accept: application/vnd.github+json" "X-GitHub-Api-Version: 2022-11-28")

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE"
  exit 1
fi

created=0; updated=0; failed=0
for name in $WANTED; do
  value=$(grep -E "^${name}=" "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '\r' | sed 's/^ *//;s/ *$//')
  if [ -z "$value" ]; then
    failed=$((failed+1)); echo "$name -> SKIPPED (not found in .env.local)"
    continue
  fi
  payload=$(printf '{"name":"%s","value":"%s"}' "$name" "$value")
  code=$(curl -s -o /tmp/ghvar.json -w '%{http_code}' -X POST \
    -H "${AUTH_H[0]}" -H "${AUTH_H[1]}" -H "${AUTH_H[2]}" \
    "$APIBASE" -d "$payload" --max-time 30)
  if [ "$code" = "409" ]; then
    code=$(curl -s -o /tmp/ghvar.json -w '%{http_code}' -X PATCH \
      -H "${AUTH_H[0]}" -H "${AUTH_H[1]}" -H "${AUTH_H[2]}" \
      "$APIBASE/$name" -d "$payload" --max-time 30)
    if [ "$code" = "204" ]; then code="PATCHED"; fi
  elif [ "$code" = "201" ]; then
    code="CREATED"
  fi
  if [ "$code" = "CREATED" ]; then
    created=$((created+1)); echo "$name -> created"
  elif [ "$code" = "PATCHED" ]; then
    updated=$((updated+1)); echo "$name -> updated"
  else
    failed=$((failed+1)); echo "$name -> FAILED (HTTP $code)"
  fi
done
echo "---- summary: created=$created updated=$updated failed=$failed ----"
if [ "$failed" -eq 0 ]; then
  echo "Variables now on $REPO:"
  curl -s -H "${AUTH_H[0]}" -H "${AUTH_H[1]}" \
    "$APIBASE?per_page=100" --max-time 30 \
    | grep -oE '"name": *"[^"]+"' | sed 's/"name": *//'
  exit 0
fi
exit 1
