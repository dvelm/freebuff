#!/bin/sh
# install.sh - freeb installer for bash (git-bash on Windows, or any POSIX sh).
# Copies this fixed build next to a `freeb` launcher on your PATH.
# No admin rights needed. Re-running updates an existing install.
#
#   bash install.sh [dest-dir]
#
# Default dest-dir: $HOME/.local/bin (override with $1 or $FREEB_DEST).
# A `freeb` shell shim is written next to the binary; the bundled freeb.bat
# is installed too for cmd/PowerShell users sharing the folder.
set -u
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-${FREEB_DEST:-$HOME/.local/bin}}"
EXE=freebuff-fixed.exe
WASM=tree-sitter.wasm
fail() { echo "ERROR: $1" >&2; exit 1; }
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*|Windows*) ;;
  *) echo "WARNING: this release is a Windows build; the exe will not run on $(uname -s)." ;;
esac
[ -f "$SRC_DIR/$EXE" ] || fail "$EXE not found next to install.sh. Unzip the whole release folder first."
[ -f "$SRC_DIR/$WASM" ] || fail "$WASM not found next to install.sh. Unzip the whole release folder first."
mkdir -p "$DEST" || fail "cannot create $DEST."
cp -f "$SRC_DIR/$EXE" "$SRC_DIR/$WASM" "$DEST/" || fail "copy failed (disk space? permissions?)."
[ -f "$SRC_DIR/freeb.bat" ] && cp -f "$SRC_DIR/freeb.bat" "$DEST/"
[ -f "$SRC_DIR/install.bat" ] && cp -f "$SRC_DIR/install.bat" "$DEST/"
[ -f "$SRC_DIR/install.sh" ] && cp -f "$SRC_DIR/install.sh" "$DEST/"
[ -f "$SRC_DIR/freeb-launch.ps1" ] && cp -f "$SRC_DIR/freeb-launch.ps1" "$DEST/"
[ -f "$SRC_DIR/freeb-launch.sh" ] && cp -f "$SRC_DIR/freeb-launch.sh" "$DEST/"
# The freeb command checks for updates on start (like the original freebuff):
# it delegates to the launcher when present, otherwise execs the exe directly.
if [ -f "$DEST/freeb-launch.sh" ]; then
  cat > "$DEST/freeb" <<EOF
#!/bin/sh
exec "$DEST/freeb-launch.sh" "\$@"
EOF
else
  cat > "$DEST/freeb" <<EOF
#!/bin/sh
exec "$DEST/$EXE" "\$@"
EOF
fi
chmod +x "$DEST/freeb"
"$DEST/$EXE" --version >/dev/null 2>&1 || fail "installed binary failed to run."
case ":$PATH:" in
  *":$DEST:"*) echo "freeb is ready in this and future terminals." ;;
  *)
    echo "$DEST is not on PATH yet."
    SHELL_RC="$HOME/.bashrc"
    if grep -qF "$DEST" "$SHELL_RC" 2>/dev/null; then
      echo "Already present in $SHELL_RC."
    else
      printf '\n# added by freeb installer\nexport PATH="$PATH:%s"\n' "$DEST" >> "$SHELL_RC" \
        || fail "cannot write $SHELL_RC."
      echo "Added to $SHELL_RC."
    fi
    echo "Reopen your terminal, then run: freeb --cwd <your-project>"
    ;;
esac
echo "Run: freeb --cwd <your-project>"
