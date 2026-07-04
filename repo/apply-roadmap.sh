#!/bin/bash
# Integrates the roadmap items staged under proposed/ into their real
# locations (ops/, .claude/). Run this yourself, from a normal (non-Night
# Shift) shell -- it exists because Night Shift's own agent is permanently
# denied write access to ops/ and .claude/ (see RUNNER_PROMPT.md's hard
# rules), by the same rule that stops it from loosening its own gates. That
# rule can't tell "an end-user hub repo's guard config" from "this repo's
# own shipped template for that config" apart, so a human has to make this
# one copy.
#
# What this does:
#   1. Backs up the current ops/ and .claude/ to *.bak-<timestamp>
#   2. Copies proposed/runner/*      -> ops/
#   3. Copies proposed/agent-settings/settings.json -> .claude/settings.json
#   4. Prints the two-line manual patch still needed for RUNNER_PROMPT.md
#      (see proposed/runner-prompt-patch.md -- that file itself can't be
#      applied automatically for the same reason as everything else here:
#      editing RUNNER_PROMPT.md is exactly the write this protection exists
#      to deny)
#   5. Shows `git diff --stat` so you can review before committing
#
# CONTROL.md is NOT copied by this script -- it isn't a protected path, so a
# prior Night Shift run already added it directly at the repo root.
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

echo "==> Copying proposed/runner/* -> ops/"
cp -R "$BASE/proposed/runner/." "$BASE/ops/"
chmod +x "$BASE/ops/"*.sh 2>/dev/null || true

echo "==> Copying proposed/agent-settings/settings.json -> .claude/settings.json"
cp "$BASE/proposed/agent-settings/settings.json" "$BASE/.claude/settings.json"

echo ""
echo "==> Still needed: a manual two-part edit to RUNNER_PROMPT.md"
echo "    (this script won't touch it -- see proposed/runner-prompt-patch.md for the exact text)"
echo ""

echo "==> Diff summary (review before committing):"
cd "$BASE" && git diff --stat -- ops .claude 2>/dev/null || true

echo ""
echo "==> Once you're happy with the diff:"
echo "    git add ops .claude CONTROL.md && git commit -m 'Apply Night Shift roadmap: cross-platform install, CONTROL.md, secret scan, CLI polish'"
echo "    Then apply the RUNNER_PROMPT.md patch above by hand, review, and commit that separately."
echo "    Backups (ops.bak-$STAMP, .claude.bak-$STAMP) are safe to delete once you're satisfied."
