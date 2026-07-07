#!/bin/bash
# Installs (or updates) the Night Shift runner on this machine (macOS or
# Linux -- see install.ps1 for native Windows). Copies the runner scripts
# OUTSIDE the repo clone so the sandboxed agent can never modify the code
# that governs it. Re-run after changing these scripts.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/claude-night-shift"
PLATFORM="$(uname -s)"

echo "==> Checking prerequisites"
command -v git >/dev/null || { echo "ERROR: git not found"; exit 1; }
PYTHON3="$(command -v python3 || true)"
[ -n "$PYTHON3" ] || { echo "ERROR: python3 not found on PATH"; exit 1; }
if [ ! -x "$HOME/.local/bin/claude" ] && ! command -v claude >/dev/null; then
    echo "ERROR: claude CLI not found. Install it first:"
    echo "  curl -fsSL https://claude.ai/install.sh | bash   # then: claude -> /login"
    exit 1
fi
case "$PLATFORM" in
    Darwin|Linux) ;;
    *)
        echo "ERROR: unrecognized platform '$PLATFORM'."
        echo "On Windows, run install.ps1 instead (native PowerShell, no WSL needed)."
        exit 1
        ;;
esac

echo "==> Installing to $DEST"
mkdir -p "$DEST/logs" "$DEST/secrets"
chmod 700 "$DEST/secrets"
for f in night-shift.sh check_budget.py runner-settings.json mode.sh secret_scan.py; do
    cp "$SRC/$f" "$DEST/$f"
done
chmod +x "$DEST/mode.sh" "$DEST/night-shift.sh"
# Convenience command: `nightshift status|normal|day-off|vacation|model|logs`
if [ -d "$HOME/.local/bin" ]; then
    ln -sf "$DEST/mode.sh" "$HOME/.local/bin/nightshift"
fi
# Never clobber an existing, user-edited config.
if [ ! -f "$DEST/config.env" ]; then
    cp "$SRC/config.env" "$DEST/config.env"
    echo "    NOTE: edit $DEST/config.env (GITHUB_REPO at minimum)"
else
    echo "    keeping existing config.env (compare against ops/config.env for new knobs)"
fi

case "$PLATFORM" in
    Darwin)
        echo "==> Installing launchd job"
        PLIST_DEST="$HOME/Library/LaunchAgents/com.claude.nightshift.plist"
        sed "s|__HOME__|$HOME|g" "$SRC/com.claude.nightshift.plist" > "$PLIST_DEST"
        launchctl unload "$PLIST_DEST" 2>/dev/null || true
        launchctl load "$PLIST_DEST"
        ;;
    Linux)
        echo "==> Installing systemd --user timer"
        command -v systemctl >/dev/null || {
            echo "ERROR: systemctl not found. This installer needs systemd --user support"
            echo "(e.g. not available by default under WSL1; WSL2 with systemd enabled works)."
            exit 1
        }
        UNIT_DIR="$HOME/.config/systemd/user"
        mkdir -p "$UNIT_DIR"
        sed "s|__HOME__|$HOME|g" "$SRC/nightshift.service" > "$UNIT_DIR/nightshift.service"
        cp "$SRC/nightshift.timer" "$UNIT_DIR/nightshift.timer"
        systemctl --user daemon-reload
        systemctl --user enable --now nightshift.timer
        # Lets the user timer fire even when nobody is logged in over SSH.
        loginctl enable-linger "$USER" 2>/dev/null || \
            echo "    NOTE: 'loginctl enable-linger $USER' failed -- the timer may only" \
                 "run while you have an active session. Run it manually if this matters to you."
        ;;
esac

echo "==> Done. Next steps if this is a first install:"
echo "  1. printf '%s' 'github_pat_...' > $DEST/secrets/github-token && chmod 600 \$_"
echo "  2. Edit $DEST/config.env"
echo "  3. bash $SRC/setup-labels.sh   (with GH_TOKEN exported)"
echo "  4. cd into the repo clone, run 'claude' once to accept the folder trust prompt"
echo "  5. Test: $PYTHON3 $DEST/check_budget.py --mode start; echo \$?"
echo "  6. (optional) copy CONTROL.md into your tasks repo root for phone-based remote control"
