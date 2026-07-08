# Handoff: Task #12 — Shift Model Tags

(This replaces the previous contents of this file, which documented task #1's
now-resolved, now-merged blockers. That history is in git log if you need it —
`git log -- HANDOFF.md` on `main` before this branch.)

## What this task is

Instead of one model for the whole night's run, a task issue can now request
its own model via a `model:<tag>` label (`model:opus`, `model:sonnet`,
`model:haiku`, `model:fable`). A fixed baseline model still starts every run
and is what any task without a recognized tag falls back to — never a hard
failure over a missing or bad tag.

## What got built this run

Everything except the same category of manual edit every prior roadmap batch
in this repo has needed — the agent is permanently denied write access to
`ops/`, `.claude/`, `CLAUDE.md`, and `RUNNER_PROMPT.md`, in every repo it
touches, including this one, whose actual product is a set of files at
exactly those paths.

| Item | Where it lives | Tested? |
|---|---|---|
| `model:opus`/`model:sonnet`/`model:haiku`/`model:fable` labels | Live now, directly on the hub repo (`ethanbudge/claude-tasks`) — label creation isn't a protected-path write, so this run just did it. | N/A — a label either exists or doesn't; confirmed via the API response. |
| `select_next_task()` / `resolve_task_model()` (mirrors `RUNNER_PROMPT.md`'s "Select one task" algorithm; resolves the picked issue's `model:<tag>` against `MODEL_ALLOWLIST`) | `repo/proposed/runner/check_budget.py` | Yes — 27 unit tests against fixtures/mocked GitHub responses: `MODEL_ALLOWLIST` parsing (incl. malformed entries, whitespace, case), `priority_rank`, `model_tag`, `is_agent_comment`, the `Depends on #N` regex, and all three selection tiers (owner-replied needs-human over ready; agent's-own-last-comment skipped; stale vs. fresh in-progress; priority-then-age ordering within ready; `Depends on` blocking an open dependency and not blocking a closed one; nothing-actionable → `None`) and `resolve_task_model`'s four outcomes (known tag, no tag, unknown tag, nothing selected). All passed. The live GitHub calls themselves are untested the same way `CONTROL.md`'s existing fetch is — no deployed instance to test against — and fail the same safe way (an error just makes that tier come up empty, never blocks the guard or crashes it). |
| Three-tier model precedence (`CONTROL.md` override > task's `model:<tag>` > baseline `MODEL`) | `repo/proposed/runner/night-shift.sh` (extends the existing `effective_model` resolution — same site that already handled `CONTROL.md`'s override) | `bash -n` syntax-checked; the precedence one-liner itself (a small embedded Python snippet) was run directly against three fixture JSON payloads (override present, tag-only, neither) and returned the right value each time. |
| `MODEL_ALLOWLIST` config knob | `repo/proposed/runner/config.env` | N/A — a config default; exercised indirectly by the `check_budget.py` unit tests above. |
| `nightshift update-models` (checks for new Claude models via a cheap read-only `claude -p` web-search call, creates the corresponding hub labels itself, prints the `MODEL_ALLOWLIST` line to hand-apply) | `repo/proposed/runner/mode.sh` | `bash -n` syntax-checked. The output-parsing logic (`grep`/`sed` extracting `PROPOSE tag=model-id` lines, ignoring stray prose, handling `PROPOSE none`) and the allowlist-accumulation loop were both run directly against fixture text in this sandbox. The actual `claude -p` web-search call and the label-creation `curl` were **not** exercised end-to-end — this sandbox's network allowlist doesn't cover a live multi-repo test of that path, and it would cost real tokens/API calls on every test run regardless. Treat the first real `nightshift update-models` as worth watching. |
| `model:*` labels added to fresh-install setup | `repo/proposed/runner/setup-labels.sh` | `bash -n` syntax-checked; same shape as the existing `status:*`/`priority:*` calls it's alongside. |
| `apply-roadmap.sh` (recreated — removed after the last batch was applied, per task #4's handoff note) | `repo/apply-roadmap.sh` | Not re-tested this run — it's an unmodified copy of the version task #4 already dry-ran against a scratch `repo/` copy (backs up `ops/`/`.claude/`, copies `proposed/runner/*` in, leaves everything else alone). |
| README.md / DESIGN.md | Updated in place (not staged — these aren't protected paths) | Documents the feature, the precedence rules, and what's tested vs. not. |

## Why this needed two manual edits (see `proposed/runner-prompt-patch.md`)

1. **`CLAUDE.md`** needs a `model:*` row in the Labels table, *and* a real bug
   fix: its "replace labels" guidance only mentions preserving the priority
   label. Every label-set `PUT` in `RUNNER_PROMPT.md` (claiming a task, any
   end-state transition) sends the complete label set — so without this fix,
   the first time an agent run touches a tagged issue's labels, it silently
   deletes the `model:<tag>` label, breaking model routing for any later run
   that resumes the same issue. This is worth fixing even before you decide
   whether to keep the rest of this feature.
2. **`RUNNER_PROMPT.md`** gets one FYI sentence: the model this invocation is
   running under was already chosen before the agent started. Nothing
   actionable for the agent — just so an unfamiliar `model:*` label doesn't
   read as stray metadata.

## What you need to do

1. **Run the integration script** from wherever you copied `repo/` into (your
   hub repo clone):
   ```bash
   bash apply-roadmap.sh
   ```
   Backs up `ops/` and `.claude/`, copies everything from `repo/proposed/`
   into place, shows a diff to review.
2. **Apply the two-line patch by hand** — exact text in
   `proposed/runner-prompt-patch.md`: the `CLAUDE.md` labels-table row + the
   label-clobbering fix, and the one-sentence `RUNNER_PROMPT.md` note.
3. **Review the diff, commit, push, re-run `ops/install.sh`** to pick up the
   new scripts.
4. **Try it**: put a `model:opus` label on a `status:ready` issue, trigger a
   run (`nightshift begin-run`), and check `night-shift.log` for the
   `(model: claude-opus-4-8)` note this batch added to the per-task log line.
5. **Optionally**, run `nightshift update-models` once to confirm it runs
   cleanly against your real hub repo and CLI install — this is the one path
   that genuinely couldn't be tested in the sandbox.

## Definition of done: where it stands after all of the above

- **Tag taxonomy covering available models** — done: `model:opus/sonnet/haiku/fable` exist now on the hub repo; `nightshift update-models` keeps it current going forward.
- **Baseline model, used to start runs and as the fallback** — done: `config.env`'s existing `MODEL` knob is that baseline; nothing about it changed.
- **Night shift reads the tag and switches models for that task** — done, pending steps 1–3 above: `night-shift.sh` resolves the model before invoking `claude` for each task, from `check_budget.py`'s per-task selection.
- **Backwards compatible with untagged issues** — done: no tag (or an unrecognized one) falls back to baseline, verified in the `resolve_task_model` unit tests.
- **`update-models` command, if necessary** — built: `nightshift update-models`. Judged necessary since the DoD explicitly asked for a way to keep the tag set current without a person hand-writing new labels every time a model ships.
- **Deprecated model-choosing code updated to use the baseline** — no separate/competing model-selection mechanism was found to deprecate; the existing `CONTROL.md`/`MODEL` precedence chain was extended in place, not replaced.
- **Implemented across the Night Shift repo, the personal claude-tasks repo, and the local claude-tasks folder** — the Night-Shift repo side is this branch (pending the human-only integration steps above); the claude-tasks side is the four labels already live on the hub repo. "My local claude-tasks folder" (the actual clone on the owner's own machine, distinct from either GitHub repo) is outside what this sandbox can ever reach — steps 1–4 above are exactly what happens there once you run them.
- **Questions/concerns, additional permissions needed** — none beyond the standing, structural one every roadmap batch here hits (protected-path writes). No new permission scope is needed: label creation was already inside the existing GitHub-write allowlist.
