#!/bin/bash
# Integrates whatever is currently staged under proposed/ into its real
# locations (ops/, .claude/). Run this yourself, from a normal (non-Night
# Shift) shell -- it exists because Night Shift's own agent is permanently
# denied write access to ops/ and .claude/ (see RUNNER_PROMPT.md's hard
# rules), by the same rule that stops it from loosening its own gates. That
# rule can't tell "an end-user hub repo's guard config" from "this repo's
# own shipped template for that config" apart, so a human has to make this
# one copy.
#
# This is a durable, reusable script, not a one-shot: every time a Night
# Shift task adds new content under proposed/ (because finishing it required
# touching ops/ or .claude/), run this again to fold it in.
#
# What this does:
#   1. Backs up the current ops/ and .claude/ to *.bak-<timestamp>
#   2. Copies proposed/runner/*      -> ops/
#   3. Copies proposed/agent-settings/settings.json -> .claude/settings.json
#   4. Prints any manual patch notes still needed (files named
#      proposed/*-patch.md -- these can't be applied automatically for the
#      same reason as everything else here: the file they'd edit is exactly
#      the write this protection exists to deny)
#   5. Shows `git diff --stat` so you can review before committing
#
# New root-level files a prior Night Shift run may have added directly (e.g.
# CONTROL.md, REVIEW_PROMPT.md) are NOT copied by this script -- they aren't
# protected paths, so the agent already wrote them in place.
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

if [ ! -d "$BASE/proposed" ]; then
    echo "ERROR: $BASE/proposed not found. Run this from the repo root that has it."
    exit 1
fi

echo "==> Backing up ops/ -> ops.bak-$STAMP, .claude/ -> .claude.bak-$STAMP"
cp -R "$BASE/ops" "$BASE/ops.bak-$STAMP"
cp -R "$BASE/.claude" "$BASE/.claude.bak-$STAMP"

if [ -d "$BASE/proposed/runner" ]; then
    echo "==> Copying proposed/runner/* -> ops/"
    cp -R "$BASE/proposed/runner/." "$BASE/ops/"
    chmod +x "$BASE/ops/"*.sh 2>/dev/null || true
fi

if [ -f "$BASE/proposed/agent-settings/settings.json" ]; then
    echo "==> Copying proposed/agent-settings/settings.json -> .claude/settings.json"
    cp "$BASE/proposed/agent-settings/settings.json" "$BASE/.claude/settings.json"
fi

patches=("$BASE"/proposed/*-patch.md)
if [ -e "${patches[0]}" ]; then
    echo ""
    echo "==> Still needed: manual edits described in the following file(s):"
    for p in "${patches[@]}"; do
        echo "    - ${p#"$BASE"/}"
    done
    echo "    (this script won't touch them -- see each file for the exact text)"
fi

echo ""
echo "==> Diff summary (review before committing):"
cd "$BASE" && git diff --stat -- ops .claude 2>/dev/null || true

echo ""
echo "==> Once you're happy with the diff:"
echo "    git add ops .claude && git commit -m 'Apply staged Night Shift roadmap items'"
echo "    Apply any manual patch notes above by hand, review, and commit those separately."
echo "    Backups (ops.bak-$STAMP, .claude.bak-$STAMP) are safe to delete once you're satisfied."
