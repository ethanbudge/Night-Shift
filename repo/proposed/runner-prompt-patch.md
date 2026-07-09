# Manual patch for Task #12 (Shift Model Tags)

Two small hand-edits to protected files, the same "one human copy" step every
prior roadmap batch in this repo has needed (`apply-roadmap.sh` deliberately
doesn't touch these two files, for the same reason the agent can't: they're
the files `apply-roadmap.sh` itself would need write access to protect).

## 1. `CLAUDE.md` -- add the `model:*` label row, and fix a label-clobbering bug

Add a row to the Labels table (after the `priority:*` row):

```markdown
| `model:<name>` | Requests a specific model for this task (`model:opus`, `model:sonnet`, `model:haiku`, `model:fable`). Falls back to the baseline model if absent or unrecognized. | Owner |
```

Then fix the "Replace labels" example curl block -- it currently only
mentions preserving the priority label:

```markdown
# Replace labels (send the complete new set, e.g. keep the priority label):
```

This is a real bug once `model:*` labels exist: every `PUT .../labels` call
in `RUNNER_PROMPT.md`'s "Claim it" step and the end-state transitions sends
the *complete* label set, so an agent run that doesn't know to preserve a
`model:<tag>` label will silently delete it the first time it touches the
issue's labels -- breaking model routing for any later run that resumes the
same issue (a `status:in-progress` pickup, or a `status:needs-human` reply).
Change the comment (and the worked examples right below it) to:

```markdown
# Replace labels (send the complete new set, e.g. keep the priority and any model:* label):
```

and add `"model:opus"` (or whatever was actually on the issue) to the
worked-example label arrays so a future reader copies the right pattern.

## 2. `RUNNER_PROMPT.md` -- note that model selection happens before the agent starts

Add one sentence near the "Claim it" step (or the top of "Work the task"):

```markdown
The model this invocation is running under was already chosen before you
started (`night-shift.sh` resolves it from CONTROL.md's `model:` line, the
picked issue's `model:<tag>` label, or the baseline `MODEL` in config.env, in
that precedence order -- see DESIGN.md). Nothing you need to do differently;
this is FYI so an unfamiliar `model:*` label on an issue doesn't look like
stray owner metadata.
```

No other `RUNNER_PROMPT.md` change is needed -- the task-selection algorithm
in "Select one task" is unchanged; `check_budget.py`'s `select_next_task()`
(in `proposed/runner/check_budget.py`) is a best-effort *mirror* of it, kept
side by side deliberately so the two are easy to compare. **If "Select one
task" ever changes, `select_next_task()` must change with it** -- that's a
maintenance note for you, not something `apply-roadmap.sh` can enforce.
