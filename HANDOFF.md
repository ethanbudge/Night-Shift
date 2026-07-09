# Handoff: Task #7 — More Efficient Night Shift

## TL;DR

One manual copy step, then done. Everything else is built, tested, and already in this branch.

## What's blocked, and why (same structural wall as before)

`ops/` is permanently write-denied to the Night Shift agent, in every repo it touches — including this one, whose product is a set of files that live at exactly that path. This is by design (it's the same rule that stops the agent from loosening its own budget gates), and it applied here too: the fix for this task is a change to `ops/night-shift.sh` and a new `ops/check_queue.py`, both unreachable by the agent's own tools. Task #1's `HANDOFF.md` (superseded by this one) hit the identical wall and resolved it with a staged `proposed/` + one-time apply script; this run reused that exact pattern rather than re-deriving it.

## What this change does

Right now, every hourly wake-up that passes the budget gates invokes a full `claude -p` call — even on the (typical) night when the backlog is fully drained and the only possible outcome is `NO_ACTIONABLE_TASKS`. That invocation still has to load `CLAUDE.md`/`RUNNER_PROMPT.md` and make a few GitHub API calls before it can conclude there's nothing to do. This is the concrete "credits spent checking if there's work to be done" problem described in the task.

The fix: `ops/check_queue.py`, a small stdlib-only script `night-shift.sh` now runs *before* the `claude -p` invocation. It asks only the coarsest possible question — "does any open issue carry `status:ready`, `status:in-progress`, or `status:needs-human` at all?" — via three small GitHub REST calls, no LLM involved. If all three come back empty, the run logs `queue empty (pre-check); skipping claude invocation this run` and exits, exactly as if `claude` had run and printed `NO_ACTIONABLE_TASKS` — just without paying for the invocation.

**It deliberately does not replicate the full selection logic** (`Depends on #N` chains, the 3-hour abandoned-work window, human-reply detection). That asymmetry is the safety property: this script only needs to answer "could there possibly be a candidate," and it fails toward "run claude" on any doubt — missing `GH_TOKEN`/`GITHUB_REPO`, a network error, a rate limit, or an unexpected response shape all fall through to invoking claude exactly as today. A false "not empty" costs one ordinary invocation (today's status quo, never worse); a false "empty" would silently skip real work, which is why the check only ever answers "empty" when it's certain. When there *is* a candidate — even one that later turns out to be blocked by a dependency — the run proceeds unchanged, and the agent's own (unmodified) selection logic decides what happens next.

**Tested:** `check_queue.py`'s logic was unit-tested (all-empty → skip, one-label-nonzero → proceed, network error → proceed, missing env vars → proceed, malformed response → proceed) and live-tested against the real `claude-tasks` repo, which currently has multiple open issues — correctly returned "proceed." The `night-shift.sh` integration diff was verified with `bash -n` and by isolating just the new conditional in a harness (queue-empty path confirmed to skip without invoking a stand-in `claude`); the unmodified rest of the script is byte-for-bit identical to before, confirmed by diff. Note: the script shells out to `curl` rather than using Python's `urllib` for the GitHub REST call — this sandbox's network proxy was observed truncating `urllib`'s read of the `/search/issues` response (`http.client.IncompleteRead`) while `curl` handled the identical request cleanly, consistent with `DESIGN.md`'s existing rationale for preferring `curl` over other HTTP clients here.

## What you need to do

1. From wherever you copied `repo/` into (your hub repo clone):
   ```bash
   bash apply-efficiency-patch.sh
   ```
   This backs up `ops/night-shift.sh` to `ops/night-shift.sh.bak-<timestamp>`, copies `proposed/check_queue.py` and `proposed/night-shift.sh` into `ops/`, and prints a diff to review.
2. Review the diff, then:
   ```bash
   git add ops/check_queue.py ops/night-shift.sh
   git commit -m "Skip claude invocation when the task queue is provably empty"
   git push
   ```
3. Re-run `bash ops/install.sh` (or `install.ps1` on Windows) so your installed copy at `~/claude-night-shift/` picks up the new script.
4. Do the same in your `claude-tasks` hub repo clone — its `ops/` is a byte-for-byte copy of this repo's, and this task staged the identical patch there too (see that repo's own `HANDOFF.md`).

## What I'll do once it's in place

Nothing further is needed from the agent — this is a one-shot change, not an ongoing integration. A future run can verify it's live by checking `~/claude-night-shift/logs/night-shift.log` for a `queue empty (pre-check)` line on the next fully-idle night.

## Recommendations for further efficiency (not implemented this run — see README's new "Efficiency" section for the full list and why each was deferred)

- Route the "is there work?" pass through a cheaper model, reserving Sonnet/Opus for confirmed task execution — deliberately deferred since issue #12 ("Shift Model Tags") is already scoped to build per-task model routing; folding a triage-specific model choice in ahead of that would likely conflict with its design.
- Auto-calibrate `PCT_PER_WORK_HOUR` from `usage-log.csv` (already on DESIGN.md's roadmap list, unrelated to this task's specific ask).
- Trim `RUNNER_PROMPT.md`/`CLAUDE.md` token footprint further — looked at this; both are already fairly lean and mostly load-bearing (label taxonomy, curl recipes, end-state rules), so no low-risk cuts were identified.
