#!/usr/bin/env python3
"""Cheap pre-check: is the task queue provably empty?

night-shift.sh invokes this before the (expensive) `claude -p` call. It
answers only the coarsest version of RUNNER_PROMPT.md's task selection:
"does any open issue in the hub repo carry an actionable status label at
all?" It deliberately does NOT reimplement the full selection logic
(Depends-on chains, the 3-hour abandoned-work window, human-reply detection)
-- that stays exclusively the agent's judgment call, made with full context.

This asymmetry is the safety property: a false "empty" here would silently
skip real work, so the script fails toward "run claude" on anything short of
certainty (missing env vars, network error, non-zero curl exit, unexpected
response shape all return "proceed"). A false "not empty" just costs one
ordinary `claude -p` invocation, i.e. today's status quo -- never worse.

On most nights the backlog is fully drained (nothing ready, nothing
in-progress, nothing needs-human), and this script is the only thing that
runs: three small REST calls instead of a full `claude -p` invocation that
loads CLAUDE.md/RUNNER_PROMPT.md and still has to conclude the same thing.

Shells out to `curl` rather than urllib: this sandbox's network proxy has
been observed to truncate urllib's read of larger GitHub API responses
(http.client.IncompleteRead) while curl handles the same request cleanly --
consistent with DESIGN.md's existing rationale for using curl over other
HTTP clients for GitHub REST calls in this project.

Exit codes:
  0 = at least one open issue carries a status:ready / status:in-progress /
      status:needs-human label, or the check could not complete -- proceed
      to invoke claude, unchanged from today's behavior.
  1 = zero open issues across all three labels -- provably nothing to do,
      safe to skip the claude invocation entirely this run.
"""
import json
import os
import subprocess
import sys

LABELS = ("status:ready", "status:in-progress", "status:needs-human")
TIMEOUT_SECONDS = 15


def label_has_open_issue(repo, token, label):
    query = f'repo:{repo} is:issue is:open label:"{label}"'
    result = subprocess.run(
        [
            "curl", "-sS", "--fail",
            "-H", f"Authorization: Bearer {token}",
            "-H", "Accept: application/vnd.github+json",
            "https://api.github.com/search/issues",
            "--data-urlencode", f"q={query}",
            "-G",
        ],
        capture_output=True, text=True, timeout=TIMEOUT_SECONDS, check=True,
    )
    data = json.loads(result.stdout)
    return data.get("total_count", 1) > 0  # unexpected shape -> assume nonzero, proceed


def main():
    repo = os.environ.get("GITHUB_REPO")
    token = os.environ.get("GH_TOKEN")
    if not repo or not token:
        print("check_queue: missing GITHUB_REPO/GH_TOKEN; proceeding", file=sys.stderr)
        return 0

    try:
        for label in LABELS:
            if label_has_open_issue(repo, token, label):
                return 0
    except (subprocess.SubprocessError, OSError, ValueError, KeyError) as exc:
        print(f"check_queue: error checking queue ({exc}); proceeding", file=sys.stderr)
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
