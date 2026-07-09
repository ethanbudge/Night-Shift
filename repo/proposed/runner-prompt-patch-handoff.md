# Patch for the real RUNNER_PROMPT.md — hand-off README

Same reason as `runner-prompt-patch.md`: `RUNNER_PROMPT.md` is itself one of
the protected paths, so even this staging copy can't ship as a drop-in
replacement — a human applies these two edits by hand, then copies
`runner/update_handoff.py` into `ops/update_handoff.py`.

This wires up task #10 ("Shift Hand-off"): a `README.md` at the hub repo
root that always reflects, in one glance, every task currently waiting on
the owner — a PR to review, questions to answer, or a HANDOFF.md checklist
to work through. It's maintained by `ops/update_handoff.py` (staged at
`runner/update_handoff.py` in this proposal), a small stdlib-only script
that rewrites one marked block in `README.md` from a JSON comment it keeps
as the source of truth — no LLM tokens spent regenerating prose each run.

## 1. Prune stale entries during task selection

At the end of `## Select one task`, after the `Depends on #N` paragraph,
add:

```
Before picking, reconcile the hub repo's hand-off README against the open issues you just
fetched: `python3 ops/update_handoff.py README.md sync --keep <comma-separated numbers of every
currently-open issue>`. This runs every time, even when nothing is actionable — it's what clears
an entry once the owner has merged a PR or closed an issue elsewhere.
```

## 2. Record a hand-off entry when reaching an end state

Each of the four end-state bullets in `## End states` gets one sentence
appended, all pointing at the same `README.md` in the hub repo root
(never the target repo's — the owner's to-do list lives in one place
regardless of where the code went):

**A. Finished**, append after "...comment a short summary.":
```
Then run `python3 ops/update_handoff.py README.md upsert --issue <n> --repo $GITHUB_REPO --title
"<title>" --kind review --action "Review PR #<pr-number>"`.
```

**B. Needs human input**, append after "...Set `status:needs-human`.":
```
Then run `python3 ops/update_handoff.py README.md upsert --issue <n> --repo $GITHUB_REPO --title
"<title>" --kind needs-human --action "Answer <k> questions"`.
```

**C. Blocked**, append after "...post a checklist comment, set `status:needs-human`.":
```
Then run `python3 ops/update_handoff.py README.md upsert --issue <n> --repo $GITHUB_REPO --title
"<title>" --kind handoff --action "Work through HANDOFF.md checklist"`.
```

**D. Genuinely infeasible**, append after "...recommend closing or reshaping the task.":
```
Then run `python3 ops/update_handoff.py README.md upsert --issue <n> --repo $GITHUB_REPO --title
"<title>" --kind infeasible --action "Decide: close or reshape"`.
```

If any of these four `update_handoff.py` calls fails (e.g. `README.md`
doesn't parse the way the script expects), don't let it block reaching the
end state — the labels and issue comment are the source of truth; the
README is a convenience mirror of them and losing sync for one run is
harmless, since the very next run's `sync` step in step 1 above will catch
up as soon as issues close.

## 3. Document it in CLAUDE.md

Add a short paragraph near the top of CLAUDE.md, after the labels table,
so future agents (and the owner) know the README exists and why:

```
## Hand-off README

`README.md` at this repo's root always reflects every task currently
waiting on the owner — a PR to review, questions to answer, or a
HANDOFF.md checklist to work through — regardless of which repo the work
actually landed in. It's maintained by `ops/update_handoff.py`; see
`## End states` in RUNNER_PROMPT.md for when it's called. Don't hand-edit
between the `<!-- NIGHT-SHIFT-HANDOFF:START/END -->` markers — it's
regenerated from a JSON comment on every run.
```

## Integration steps for the owner

```bash
cd claude-tasks-hub-repo-clone
cp path/to/Night-Shift/repo/proposed/runner/update_handoff.py ops/update_handoff.py
chmod +x ops/update_handoff.py
```

Then apply the three edits above to `RUNNER_PROMPT.md` and `CLAUDE.md` by
hand, review the diff, commit, and push. No `install.sh` re-run needed —
`update_handoff.py` only runs inside agent sessions, not on the scheduler
host.
