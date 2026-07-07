#!/bin/bash
# Creates the Night Shift label taxonomy on the tasks repo.
# Usage: GH_TOKEN=... GITHUB_REPO=owner/repo bash setup-labels.sh
#        (or source config.env first and export GH_TOKEN)
set -euo pipefail

: "${GH_TOKEN:?export GH_TOKEN first}"
: "${GITHUB_REPO:?export GITHUB_REPO (owner/repo) first}"

make_label() {  # name color description
    curl -sS -o /dev/null -w "  %{http_code} $1\n" -X POST \
        -H "Authorization: Bearer $GH_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$GITHUB_REPO/labels" \
        -d "{\"name\":\"$1\",\"color\":\"$2\",\"description\":\"$3\"}"
}

echo "Creating labels on $GITHUB_REPO (422 = already exists, fine):"
make_label "status:ready"       "0e8a16" "Defined and available for the agent"
make_label "status:in-progress" "fbca04" "Agent is working on this"
make_label "status:needs-human" "d93f0b" "Waiting on your reply -- see latest agent comment"
make_label "status:in-review"   "1d76db" "PR open, awaiting your review"
make_label "priority:high"      "b60205" "Work on this first"
make_label "priority:medium"    "d4c5f9" "Normal priority"
make_label "priority:low"       "c2e0c6" "When nothing better to do"
