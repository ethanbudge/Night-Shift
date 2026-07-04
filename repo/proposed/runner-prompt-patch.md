# Patch for the real RUNNER_PROMPT.md

This describes two small edits to apply to `RUNNER_PROMPT.md` at the repo
root. It isn't shipped as a full replacement file because a file literally
named `RUNNER_PROMPT.md` anywhere in the tree is itself one of the
protected paths Night Shift's own tools refuse to write -- so even this
staging copy has to describe the change in prose rather than being a
drop-in replacement the agent could have written directly.

## 1. Add a secret-scan step, right after cloning, before any edit

In `## Work the task`, insert a new step 2 (renumber the rest), so the
sequence reads:

```
2. **Scan for leaked secrets.** After cloning/fetching the target repo (or
   before touching this repo's own tree for a standalone task), run
   `python3 ops/secret_scan.py <path>` against the working tree. A nonzero
   exit means real or plausible credentials are sitting in the repo,
   accidentally committed. Do not read the flagged lines' contents further
   and do not make any other edits to that repo/task: post one comment
   naming the file and pattern (never the matched value), recommend the
   owner rotate/remove it, set `status:needs-human`, and stop -- this is a
   hard stop, not a judgment call.
3. **Locate the work:** ...  (renumber old step 2 onward)
```

## 2. Add `CONTROL.md` to the hard-rules protected list

In `## Hard rules`, the line currently reading:

```
- Never modify `.claude/`, `ops/`, `.github/`, `CLAUDE.md`, `RUNNER_PROMPT.md`, or git config/hooks (in this repo or any workspace clone). These are governance files; changes to them are denied by policy and must not be attempted by any route.
```

becomes:

```
- Never modify `.claude/`, `ops/`, `.github/`, `CLAUDE.md`, `RUNNER_PROMPT.md`, `CONTROL.md`, or git config/hooks (in this repo or any workspace clone). These are governance files; changes to them are denied by policy and must not be attempted by any route.
```

`CONTROL.md` needs the same treatment as `CLAUDE.md`/`RUNNER_PROMPT.md`: the
agent can only be trusted to read its effect (via `check_budget.py`, which
runs outside the agent's own session) if the agent's own tools categorically
cannot edit it. The corresponding deny-list entries are already staged in
`repo/proposed/agent-settings/settings.json` and
`repo/proposed/runner/runner-settings.json`.

Both edits are copy-pasteable; `apply-roadmap.sh` prints them as a reminder
but does not apply them automatically, since editing `RUNNER_PROMPT.md`
itself is exactly the write this whole repo's protection exists to deny --
by design, this one step needs a human hand even after everything else is
copied into place.
