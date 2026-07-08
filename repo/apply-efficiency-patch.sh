#!/bin/bash
# One-time manual step: folds proposed/check_queue.py and proposed/night-shift.sh
# into ops/, where the live runner actually reads from.
#
# Why this can't be done by the agent itself: ops/ is a permanently
# write-denied path to the Night Shift agent, in every repo it touches --
# including this one, whose product happens to be a set of files that live
# at exactly that path. See HANDOFF.md and Task #7 for the full story. This
# script exists so a human can do the one copy the agent structurally can't.
#
# Usage: run from wherever you copied repo/ into (i.e. this file's own
# directory), then review the diff it prints, commit, push, and re-run
# ops/install.sh (or install.ps1) so the installed copy picks up the change.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f proposed/check_queue.py ] || [ ! -f proposed/night-shift.sh ]; then
    echo "Run this from the directory containing proposed/ (repo root)." >&2
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
cp ops/night-shift.sh "ops/night-shift.sh.bak-$STAMP"
cp proposed/check_queue.py ops/check_queue.py
cp proposed/night-shift.sh ops/night-shift.sh
chmod +x ops/check_queue.py

echo "Backed up ops/night-shift.sh -> ops/night-shift.sh.bak-$STAMP"
echo "Copied proposed/check_queue.py -> ops/check_queue.py (new)"
echo "Copied proposed/night-shift.sh -> ops/night-shift.sh"
echo
echo "--- diff: old night-shift.sh vs new -------------------------------------"
diff "ops/night-shift.sh.bak-$STAMP" ops/night-shift.sh || true
echo "--------------------------------------------------------------------------"
echo
echo "Review the diff above, then:"
echo "  git add ops/check_queue.py ops/night-shift.sh"
echo "  git commit -m 'Skip claude invocation when the task queue is provably empty'"
echo "  git push"
echo "  bash ops/install.sh   # (or install.ps1 on Windows) to update the installed copy"
