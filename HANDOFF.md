# Handoff — pending owner steps (Night-Shift template repo)

Several roadmap items have landed staged under `repo/proposed/`. Each needs a
one-time manual step from you, because the agent is permanently write-denied
on `ops/`, `.claude/`, `CLAUDE.md`, `RUNNER_PROMPT.md`, and `CONTROL.md` in
every repo it touches — including this one, whose product *is* the files at
those paths. That's the same self-protection rule that stops the agent from
loosening its own budget gates, so every item below is "built, staged, and
waiting on you to copy into place."

Apply these from your hub repo clone (`~/claude-night-shift/tasks-repo`), not
the template, so the live runner picks them up. Items applied through
`apply-roadmap.sh` (review system, model tags) can be done in one pass; the
efficiency and hand-off items have their own steps below.

---

## Task #7 — More Efficient Night Shift  (apply-efficiency-patch.sh)

Adds `ops/check_queue.py`, a stdlib-only pre-check `night-shift.sh` runs
*before* the `claude -p` invocation. It asks only the coarsest question —
"does any open issue carry `status:ready`, `status:in-progress`, or
`status:needs-human` at all?" — via three GitHub REST calls, no LLM. If all
three are empty, the run logs `queue empty (pre-check); skipping claude
invocation this run` and exits, saving the invocation that would otherwise
just conclude `NO_ACTIONABLE_TASKS`. It fails toward "run claude" on any doubt
(missing token, network error, unexpected response), so normal selection and
execution are unchanged.

```bash
bash apply-efficiency-patch.sh          # backs up ops/night-shift.sh, copies proposed/check_queue.py + night-shift.sh into ops/
git add ops/check_queue.py ops/night-shift.sh
git commit -m "Skip claude invocation when the task queue is provably empty"
git push
bash ops/install.sh                     # re-install the updated script
```

> **Coordination note:** this item and the review/model-tags items below both
> ultimately replace `ops/night-shift.sh`. The combined
> `proposed/runner/night-shift.sh` (review + model tags) does **not** yet
> include this efficiency pre-check, so applying `apply-roadmap.sh` after
> `apply-efficiency-patch.sh` would revert the pre-check. Apply the efficiency
> patch and re-fold the `check_queue.py` gate into the applied
> `ops/night-shift.sh`, or apply the roadmap first and add the pre-check on
> top — see the review below before running either.

---

## Task #10 — Shift Hand-off  (manual copy + prompt patch)

A `README.md` at the hub repo root that always reflects, in one glance, every
task currently waiting on you — a PR to review, questions to answer, or a
`HANDOFF.md` checklist to work through — regardless of which repo the work
landed in. `update_handoff.py` rewrites one marked block from a JSON comment
it keeps as source of truth, so no LLM tokens are spent regenerating prose.

```bash
cp path/to/Night-Shift/repo/proposed/runner/update_handoff.py ops/update_handoff.py
chmod +x ops/update_handoff.py
# then apply the three prose edits in repo/proposed/runner-prompt-patch-handoff.md
# to RUNNER_PROMPT.md and CLAUDE.md by hand, then commit + push. No install.sh re-run needed.
```

Once applied, a future run's next end state starts populating `README.md`
automatically. The companion `claude-tasks` PR seeds a first version of that
README, proving the format end-to-end before the automation is wired up.

---

## Task #4 — Review System  (apply-roadmap.sh)

A toggle (`nightshift review on|off|status`, off by default) that, once the
normal task queue comes back genuinely empty for a run, gives the
highest-priority completed-and-unreviewed issue one more pass from a stronger
model (`sonnet`/default → `opus` → `fable`) before the run ends — turning idle
end-of-queue credits into a second opinion. Built: the review sub-loop in
`proposed/runner/night-shift.sh`, the `REVIEW_MODE` knob in
`proposed/runner/config.env`, the `review` subcommand in
`proposed/runner/mode.sh`, deny-list entries protecting `REVIEW_PROMPT.md` in
`proposed/agent-settings/settings.json` + `proposed/runner/runner-settings.json`,
and `REVIEW_PROMPT.md` itself (already live at the repo root).

```bash
bash apply-roadmap.sh    # backs up ops/ + .claude/, copies proposed/runner/* + proposed/agent-settings/ into place, shows a diff
# review the diff, commit, push, then:
bash ops/install.sh
nightshift review on     # turn it on when you're ready
```

`REVIEW_PROMPT.md` needs no manual patch (it's a new file, not an edit to a
protected one). **Watch the first real review pass closely** — the wrapper
logic is unit-tested, but the actual `claude -p` review invocation against a
live issue/PR has not been run end-to-end; treat the first as a dry run.

> `apply-roadmap.sh` also carries the Model Tags batch (task #12) — the two
> features share the same staged `proposed/runner/*` files, so one
> `apply-roadmap.sh` run applies both. See the Model Tags section for its
> one extra `CLAUDE.md` patch (which includes a real label-preservation bug fix).
