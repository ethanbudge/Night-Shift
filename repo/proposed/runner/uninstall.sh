#!/bin/bash
# Removes the Night Shift runner from this machine. Reverses install.sh:
# unloads the scheduled job and removes the installed copy of the scripts.
# By default, logs/ and secrets/ are left alone (your GitHub token and run
# history aren't something an uninstall should silently delete); pass
# --purge to remove those too.
set -euo pipefail

DEST="$HOME/claude-night-shift"
PLIST_DEST="$HOME/Library/LaunchAgents/com.claude.nightshift.plist"
PURGE=""
[ "${1:-}" = "--purge" ] && PURGE="1"

case "$(uname -s)" in
    Darwin)
        echo "==> Unloading launchd job"
        if [ -f "$PLIST_DEST" ]; then
            launchctl unload "$PLIST_DEST" 2>/dev/null || true
            rm -f "$PLIST_DEST"
        else
            echo "    (no launchd job installed)"
        fi
        ;;
    Linux)
        echo "==> Disabling systemd --user timer"
        systemctl --user disable --now nightshift.timer 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/nightshift.service" "$HOME/.config/systemd/user/nightshift.timer"
        systemctl --user daemon-reload 2>/dev/null || true
        ;;
    *)
        echo "==> Unrecognized platform '$(uname -s)'; skipping scheduler cleanup"
        echo "    (on Windows, run install.ps1's uninstall via: Unregister-ScheduledTask -TaskName NightShift)"
        ;;
esac

echo "==> Removing the nightshift command symlink"
[ -L "$HOME/.local/bin/nightshift" ] && rm -f "$HOME/.local/bin/nightshift"

if [ -n "$PURGE" ]; then
    echo "==> Purging $DEST (logs, secrets, config -- everything)"
    rm -rf "$DEST"
else
    echo "==> Removing installed scripts, keeping logs/ and secrets/"
    for f in night-shift.sh check_budget.py runner-settings.json mode.sh secret_scan.py \
             night-shift.ps1 nightshift.service nightshift.timer; do
        rm -f "$DEST/$f"
    done
    echo "    kept: $DEST/config.env, $DEST/logs/, $DEST/secrets/, $DEST/mode"
    echo "    (re-run with --purge to remove those too)"
fi

echo "==> Done. Night Shift will not run again until install.sh (or install.ps1) is re-run."
