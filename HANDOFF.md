# Handoff: Task #4 — Review System

Everything buildable for this task has been built and pushed. What's left is the same one-time, unavoidably-manual integration step every prior roadmap batch in this repo has needed — the agent is permanently denied write access to `ops/` and `.claude/`, in every repo it touches, including this one, whose actual product is a set of files living at exactly those paths.

## What got built

| Item | Where it lives | Tested? |
|---|---|---|
| `REVIEW_PROMPT.md` (the reviewing agent's instructions) | `repo/REVIEW_PROMPT.md` (live now — a brand-new filename isn't a protected path yet) | Structural/prose review only — this is a prompt, not code; its actual behavior needs a live run against a real issue/PR. |
| `nightshift review [on\|off\|status]` toggle | `repo/proposed/runner/mode.sh`, knob in `repo/proposed/runner/config.env` (`REVIEW_MODE`, default `off`) | Yes — ran `on`/`off`/`status`/a bad argument against a scratch install in `$TMPDIR`; all four behaved correctly. |
| Review sub-loop after the normal task loop | `repo/proposed/runner/night-shift.sh` | Partial. `bash -n` syntax-checked. The completion-logging, pending-candidate computation, and model-escalation ladder are small pure functions — each was extracted and unit-tested in isolation against fixtures (see DESIGN.md's Review System entry for exact cases). The full `claude -p` review invocation itself was not exercised — that needs live GitHub issues/PRs and a real budget-gated run, neither available in this sandbox. |
| Protecting `REVIEW_PROMPT.md` the same way `RUNNER_PROMPT.md` is | `repo/proposed/agent-settings/settings.json`, `repo/proposed/runner/runner-settings.json` | JSON-validated; mirrors the existing `RUNNER_PROMPT.md`/`CONTROL.md` deny-list entries exactly, same shape as the precedent. |
| `apply-roadmap.sh` (recreated — it was removed after the last batch was applied) | `repo/apply-roadmap.sh` | Yes — dry-run against a scratch copy of `repo/`: confirmed it backs up `ops/`/`.claude/`, copies `proposed/runner/*` and `proposed/agent-settings/settings.json` into place, leaves untouched `ops/` files (e.g. `check_budget.py`) alone, and the resulting `ops/night-shift.sh`/`ops/mode.sh` still pass `bash -n`. |
| README.md / DESIGN.md | Updated in place (not staged — these aren't protected paths) | Documents the design and toggle; also corrected a few stale "staged, not yet applied" references left over from the *previous* roadmap batch (which had in fact already been folded into `ops/`/`.claude/` on `main` before this task started) — those were pre-existing doc drift, fixed here since I was already touching the same section. |

## Why no `RUNNER_PROMPT.md` patch is needed this time

Unlike the secret-scanner batch (which needed a manual two-line edit to the existing, protected `RUNNER_PROMPT.md`), the review pass is invoked with a wholly separate prompt file. `REVIEW_PROMPT.md` is new, so it could ship live directly — the same way `CONTROL.md` did originally, before its own protection was staged and applied.

## What you need to do

1. **Run the integration script** from your hub repo clone (wherever you copied `repo/` into):
   ```bash
   bash apply-roadmap.sh
   ```
   This backs up `ops/` and `.claude/` to `*.bak-<timestamp>`, copies `proposed/runner/*` and `proposed/agent-settings/settings.json` into place, and shows you a `git diff --stat` to review.
2. **Review the diff, commit, push, and re-run `ops/install.sh`** (or `install.ps1` on Windows) to pick up the new scripts on your machine. No manual prompt-file patch is needed this time (see above).
3. **Turn it on when you want it:** `nightshift review on`. It's off by default — review passes spend idle end-of-queue budget on a second opinion, which only makes sense once you've watched a normal week or two of runs and have a sense of your actual weekly headroom.
4. **Watch the first real review pass closely.** The wrapper logic (completion logging, candidate selection, model escalation, the `MAX_TASKS_PER_RUN` shared cap) is unit-tested; the actual `claude -p` review invocation — finding the right PR by branch-name prefix, reading its diff, deciding whether to push a fix — has only been reviewed for correctness, not run end-to-end. Treat the first one as a dry run to watch, the same way this repo already asks for the first Linux/Windows scheduled run.

## Definition of done: where it stands after all of the above

- **Toggle in the command line** — done: `nightshift review [on|off|status]`.
- **Triggers only when all available tasks have been completed and a review hasn't already been performed on that issue** — done: gated on a `queue_empty` flag set only by the loop's `NO_ACTIONABLE_TASKS` break (not budget/timeout/cap exits), and on a `$LOG_DIR/reviewed.csv` marker file so a given issue is never reviewed twice.
- **A better model reviews the code, in priority order, and fixes bugs/errors** — done: escalation ladder `sonnet`/default `-> opus -> fable`, priority-ordered selection delegated to the reviewing agent itself (same pattern as normal task selection), fix-or-comment behavior described in `REVIEW_PROMPT.md`.
- **Changes to the general Night Shift repo** — done, this PR.
- **Changes to "my personal claude-tasks repo" and "my local claude-tasks folder"** — out of scope for what this agent can do directly. The hub repo (`claude-tasks`) and the local install both need the *exact same* `ops/`/`.claude/` update this repo's own `ops/`/`.claude/` needs, and the agent is denied write access to those paths in every repo it touches, including the hub repo itself — that's the same structural rule, not a new one. The existing, already-documented path for this is: pull the updated `repo/` template into your hub repo (steps above), then `bash ~/claude-night-shift/tasks-repo/ops/install.sh` to refresh the local install — precisely the workflow README.md's "Update the runner itself" bullet already describes for any `ops/` change, staged or not.

Net: this task cannot reach a clean `status:in-review` PR that's *fully* done, because the actual definition of done isn't satisfied until you run `apply-roadmap.sh` here, and separately update your own hub repo and local install the same way. That last part was never something an agent run could do on its own — it's true of every prior `ops/`-touching change in this repo's history, not specific to this task.
