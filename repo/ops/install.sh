#!/bin/bash
# Installs (or updates) the Night Shift runner on this machine.
# Copies the ops scripts OUTSIDE the repo clone so the sandboxed agent can
# never modify the code that governs it. Re-run after changing ops/ files.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/claude-night-shift"
PLIST_DEST="$HOME/Library/LaunchAgents/com.claude.nightshift.plist"

echo "==> Checking prerequisites"
command -v git >/dev/null || { echo "ERROR: git not found"; exit 1; }
command -v /usr/bin/python3 >/dev/null || { echo "ERROR: python3 not found"; exit 1; }
if [ ! -x "$HOME/.local/bin/claude" ] && ! command -v claude >/dev/null; then
    echo "ERROR: claude CLI not found. Install it first:"
    echo "  curl -fsSL https://claude.ai/install.sh | bash   # then: claude -> /login"
    exit 1
fi

echo "==> Installing to $DEST"
mkdir -p "$DEST/logs" "$DEST/secrets"
chmod 700 "$DEST/secrets"
for f in night-shift.sh check_budget.py runner-settings.json mode.sh; do
    cp "$SRC/$f" "$DEST/$f"
done
chmod +x "$DEST/mode.sh"
# Convenience command: `nightshift status|normal|day-off|vacation`
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
chmod +x "$DEST/night-shift.sh"

echo "==> Installing launchd job"
sed "s|__HOME__|$HOME|g" "$SRC/com.claude.nightshift.plist" > "$PLIST_DEST"
launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load "$PLIST_DEST"

echo "==> Done. Next steps if this is a first install:"
echo "  1. printf '%s' 'github_pat_...' > $DEST/secrets/github-token && chmod 600 \$_"
echo "  2. Edit $DEST/config.env"
echo "  3. bash $SRC/setup-labels.sh   (with GH_TOKEN exported)"
echo "  4. cd into the repo clone, run 'claude' once to accept the folder trust prompt"
echo "  5. Test: python3 $DEST/check_budget.py --mode start; echo \$?"
