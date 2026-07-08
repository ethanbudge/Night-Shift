# Handoff: Task #10 — Shift Hand-off

(This replaces the previous contents of this file, which documented task #1's
now-resolved, now-merged blockers. That history is in git log if you need it —
`git log -- HANDOFF.md` on `main` before this branch.)

## What this task is

A `README.md` at the hub repo root that always reflects, in one glance, every
task currently waiting on the owner — a PR to review, questions to answer, or
a `HANDOFF.md` checklist to work through — regardless of which repo the work
actually landed in.

## What got built this run

Everything except the two edits only a human can make, for the same
structural reason every prior staged item hit this same wall:

| Item | Where it lives | Tested? |
|---|---|---|
| `update_handoff.py` — rewrites a marked block in `README.md` from a JSON comment it keeps as source of truth | `repo/proposed/runner/update_handoff.py` | Yes — ran directly against scratch files in this sandbox: upsert (new entry), upsert (idempotent replace of an existing issue, not a duplicate), remove, sync-to-partial, sync-to-empty (renders "you're caught up"), and first-run against a file with no existing block. |
| `RUNNER_PROMPT.md` patch (prune stale entries during task selection; upsert one entry per end state A/B/C/D) | `repo/proposed/runner-prompt-patch-handoff.md` (prose, not a file — same reason `runner-prompt-patch.md` is prose) | N/A — instructions for a manual edit. |
| `CLAUDE.md` doc paragraph pointing at the new file | Described in the same patch doc | N/A. |
| DESIGN.md / README.md | Updated in place (not staged — not protected paths) | New roadmap entry in DESIGN.md; README's "What's in this repo" table and "Applying staged items" section updated. While in there, also fixed both to stop referencing `repo/apply-roadmap.sh`, which a prior run's integration commit (`11369a4`) already deleted after folding an earlier roadmap batch into place — the docs hadn't caught up. |

## Why this can't go further this run

`ops/`, `.claude/`, `.github/`, `CLAUDE.md`, `RUNNER_PROMPT.md`, and
`CONTROL.md` are permanently write-denied to the agent, in every repo it
touches, including this one — confirmed again this run (`Write` to a new file
under a directory literally named `ops`, anywhere in the tree, including a
scratch attempt outside this repo entirely, is refused by the sandbox itself,
not just by policy). `RUNNER_PROMPT.md` is exactly what step 1 of this task
needs to change. There's no way to retry past this; it's the same
self-protection every previous roadmap item hit.

## What you need to do

1. **Copy the script into place**, from wherever you cloned this repo:
   ```bash
   cd claude-tasks-hub-repo-clone   # your actual hub repo, e.g. ~/claude-night-shift/tasks-repo
   cp path/to/Night-Shift/repo/proposed/runner/update_handoff.py ops/update_handoff.py
   chmod +x ops/update_handoff.py
   ```
2. **Apply the three edits** described in `repo/proposed/runner-prompt-patch-handoff.md` to `RUNNER_PROMPT.md` and `CLAUDE.md` by hand — copy-pasteable prose blocks, no ambiguity.
3. **Review the diff, commit, push.** No `install.sh` re-run needed — `update_handoff.py` only runs inside agent sessions, never on the scheduler host.
4. Once applied, a future run's next end state will start populating `README.md` automatically. See the companion PR on `claude-tasks` for a manually-seeded first version of that README, proving the format end-to-end before the automation is wired up.

## Note on `repo/proposed/` naming

`repo/proposed/runner/` (not `repo/proposed/ops/`) is intentional, matching
the existing convention from the last roadmap batch: the sandbox denies
writes to any directory literally named `ops`, anywhere in the tree, not
just the real `ops/` at repo roots. A directory named `ops` under
`repo/proposed/` would be unwritable for the same reason the real one is.
