# Claude Night Shift

**Turn your idle Claude credits into a second engineer.** Night Shift is an unattended system that spends your unused Claude Code usage — overnight, on weekends, whenever you're not at the keyboard — working through a backlog of real tasks, without ever touching the credits you need for your actual workday and without ever risking your weekly limit.

You write tasks as GitHub issues. You wake up to pull requests.

---

## Why this exists

Claude Code is fast enough that most people's weekly usage has slack in it — hours where the terminal just isn't open. Night Shift claims that slack safely:

- **It never competes with your workday.** A budget guard checks your *actual* server-side usage before every run and reserves enough of your weekly limit to cover the work hours between now and the weekly reset. Sunday night, with a full workweek ahead, it's conservative. Friday evening, with the reset hours away, it spends what's left.
- **It's sandboxed at the OS level**, not just prompted to behave — filesystem writes are confined to the task's own folder, network access is confined to an explicit domain allowlist, and it can't touch its own operating instructions.
- **It asks instead of guessing.** When a task needs a real decision, it posts one batched, numbered comment with recommended defaults and waits. A push notification lands on your phone either way — when it needs you, and when a PR is ready.
- **You review everything.** Nothing merges without you. The agent's only path to your codebase is a pull request on a branch-protected repo.

## How it works, in one paragraph

An hourly scheduled job on your always-on machine wakes a small guard script. The guard checks three gates — (1) is it outside your working hours, (2) would a new 5-hour usage window still be open when your workday starts, (3) does your real weekly usage, fetched straight from Anthropic, leave enough headroom for the work hours still ahead of the weekly reset. Only if all three pass does it launch Claude Code headlessly, one task at a time, inside an OS-enforced sandbox that can only write to that task's folder and only reach an allowlisted set of domains. Tasks live as GitHub issues in a private hub repo, but each one can target any of your project repos — the agent clones the target, works on a branch, and opens the PR there. If it needs you, the issue gets a `status:needs-human` label, your phone buzzes, and you just reply to the comment.

---

## What's in this repo

| Path | What it is |
|---|---|
| [DESIGN.md](DESIGN.md) | Architecture, the budget algorithm, the full safety model, honest known limitations, and the roadmap for what's designed but not yet built |
| [repo/](repo/) | The complete contents of the GitHub hub repo you'll create — copy this folder in, as-is |
| [repo/CLAUDE.md](repo/CLAUDE.md) | The agent's standing operating manual, loaded automatically every run |
| [repo/RUNNER_PROMPT.md](repo/RUNNER_PROMPT.md) | The exact prompt passed to `claude -p` on every task invocation |
| [repo/REVIEW_PROMPT.md](repo/REVIEW_PROMPT.md) | The prompt passed to `claude -p` for the (optional, staged) end-of-queue review pass — see `nightshift review` below |
| [repo/.claude/settings.json](repo/.claude/settings.json) | The project-scope sandbox rules — filesystem and network lockdown |
| [repo/ops/](repo/ops/) | Guard script, scheduler config, installer — the canonical copies that get installed onto your machine |
| [repo/CONTROL.md](repo/CONTROL.md) | The phone-editable remote control panel — schedule mode and model override, without touching the machine |
| [repo/proposed/](repo/proposed/) | Built-but-not-yet-integrated roadmap items (currently: the Review System) staged for the `apply-roadmap.sh` step — see below |
| [repo/apply-roadmap.sh](repo/apply-roadmap.sh) | Run this to fold `repo/proposed/` into `ops/` and `.claude/`, any time something new lands there |

---

## Quickstart

Five steps: install the CLI, stand up the hub repo, install the runner, do a one-time trust/keychain dance, and keep the machine awake. Ten minutes if you're just following along.

### 1 — Install the Claude Code CLI

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude   # run /login, sign in with the account Night Shift should spend from
```

**Platform support today:** the guard (`check_budget.py`) is stdlib Python with no OS-specific calls beyond an optional macOS Keychain read that already falls back cleanly, so the *decision logic* is portable. macOS (`launchd` + `caffeinate`) works out of the box via `ops/install.sh`. Linux (`systemd --user` timer) and native Windows (PowerShell + Task Scheduler, no WSL needed) are fully built and tested-as-far-as-this-repo's-own-sandbox-allows, but ship staged under [`repo/proposed/`](repo/proposed/) rather than live in `ops/` — see [Applying the staged roadmap items](#applying-the-staged-roadmap-items) for the one-command step to turn them on.

### 2 — Create the GitHub hub repo

1. Create a **private** repo (e.g. `claude-tasks`). This is the hub: every task issue, question, and answer lives here, even for work that lands somewhere else.
2. Copy everything under [`repo/`](repo/) into it and push.
3. **Protect `main`** (Settings → Branches → require pull requests). This is what makes it structurally impossible for the agent to alter its own instructions — every change arrives as a PR you review. Do the same on every project repo it'll touch.
4. Create a **fine-grained personal access token** (Settings → Developer settings → Fine-grained tokens):
   - Repository access: this repo, plus every project repo you want it to work on. This list is the actual security boundary — it's the only thing deciding what the agent can ever touch.
   - Permissions: **Contents** (read/write), **Issues** (read/write), **Pull requests** (read/write), **Metadata** (read). All four — issue comments, label changes, and PRs each need their own scope, and a token missing one will silently 403 on exactly that action.
   - Set an expiry you're comfortable rotating.
5. **Phone notifications** (free, via [ntfy.sh](https://ntfy.sh)): pick a long random topic name — it functions as a password, e.g. `nightshift-x7k2m9qframble` — add it as an Actions secret named `NTFY_TOPIC`, and subscribe to that topic in the ntfy app. The included workflow pings it only when the agent needs your input or finishes a task. (GitHub's own notifications stay silent here — the agent acts as *your* account, and GitHub never notifies you about your own activity.)

### 3 — Install the runner

```bash
mkdir -p ~/claude-night-shift
git clone https://github.com/<you>/claude-tasks.git ~/claude-night-shift/tasks-repo
cd ~/claude-night-shift/tasks-repo/ops
bash install.sh
```

The installer copies the scripts to `~/claude-night-shift/` — deliberately **outside** the repo the agent can write to, so it can never modify the guard that constrains it — creates `logs/` and `secrets/`, and installs the scheduled job.

```bash
# Your fine-grained PAT:
printf '%s' 'github_pat_XXXX' > ~/claude-night-shift/secrets/github-token
chmod 600 ~/claude-night-shift/secrets/github-token

# Review the config: repo slug, working hours, thresholds:
open -e ~/claude-night-shift/config.env

# Create the status/priority labels on the hub repo:
GH_TOKEN=$(cat ~/claude-night-shift/secrets/github-token) bash ~/claude-night-shift/tasks-repo/ops/setup-labels.sh
```

### 4 — One-time trust and credential approval

```bash
# Accept the folder-trust prompt:
cd ~/claude-night-shift/tasks-repo && claude   # then /exit

# Run the guard once by hand. Approve the keychain prompt with "Always Allow"
# so unattended runs can read your token later:
python3 ~/claude-night-shift/check_budget.py --mode start; echo "exit: $?"
```

Exit codes: `0` = would run now, `1` = correctly declining (e.g. it's a workday afternoon — expected), `2` = error (fails closed, nothing runs), `3` = OAuth token needs a refresh (the runner handles this automatically on schedule).

### 5 — Keep the machine awake

System Settings → Energy → never sleep (display sleep is fine — the scheduler can't fire while the machine itself is asleep). The runner also wraps each run in `caffeinate` as a second layer.

### Verify it end-to-end

```bash
bash ~/claude-night-shift/night-shift.sh
tail -50 ~/claude-night-shift/logs/night-shift.log
```

Run this at an off-hours moment (evening or weekend) for a real dry run of the whole pipeline.

---

## Using it day to day

**Add a task:** open a GitHub issue using the "Task" template (the mobile app works fine). Fill in the target repo (`owner/name`, or blank for standalone work in the hub repo itself), a `priority:*` label, and a concrete definition of done — the agent works strictly from the issue text and checks its own work against the DoD before opening a PR. Add `Depends on #N` anywhere in the body to sequence tasks.

**Answer a question:** a `status:needs-human` label plus a phone ping means the agent is stuck on a real decision. It leaves one comment with every question numbered and a recommended default for each — reply "defaults" if you don't want to think about it, or answer inline. No label changes needed on your end.

**Pause it — a day, a vacation, or for good:**

```bash
nightshift status                  # current mode, and what the guard would decide right now
nightshift begin-run               # start one run now, as if the hourly timer just fired (see below)
nightshift day-off                 # run anytime today; reverts automatically at midnight
nightshift day-off 2026-07-04      # ...or through a specific date, inclusive
nightshift vacation 2026-07-20     # also stop reserving weekly budget, through a date
nightshift vacation                # open-ended, until you run `nightshift normal`
nightshift normal                  # back to the default protected schedule
```

`day-off` skips the working-hours gate for the day. `vacation` additionally stops reserving weekly budget for workdays that aren't coming. Both still respect the hard weekly cap and 5-hour session limits, so nothing you do here can lock you out of your own account. The mode file lives outside the sandbox — the agent has no path to flip its own switch.

**Start a run right now:** `nightshift begin-run` fires a single run immediately, exactly as the hourly timer would — handy right after `nightshift day-off`, when you want the agent to start *now* instead of waiting for the top of the hour.

```bash
nightshift day-off      # lift the working-hours gate for today
nightshift begin-run    # ...and kick off the first run immediately
```

It runs through the very same gates (working hours, budget, the hard caps) and refuses — with the reason printed — if they say no, or if a run is already in progress. It never loosens a limit; it only changes *when* a run may start, never *whether* one is allowed. The scheduled hourly timer is left untouched, so normal runs continue after this one, and it reuses the runner's single-instance lock so an on-demand run and a timer run can never overlap. The run is detached — follow it with `nightshift logs -f`.

**Change the model:** set `MODEL` in `~/claude-night-shift/config.env` (e.g. `claude-opus-4-8` for harder tasks, blank for your account's default), or run `nightshift model claude-opus-4-8` (or `nightshift model default` to clear it). Opus finishes tougher tasks in fewer turns but draws down your weekly budget faster — if you switch, keep an eye on `PCT_PER_WORK_HOUR` (below).

**Change it from your phone, no laptop required:** edit [`CONTROL.md`](repo/CONTROL.md) at your hub repo's root, from the GitHub web UI or mobile app. It's a plain two-line `mode:` / `model:` panel — same effect as `nightshift vacation` or `nightshift model`, but reachable from anywhere. It's protected the same way `CLAUDE.md` and `RUNNER_PROMPT.md` are: the agent's own tools categorically cannot edit it, so it's safe to treat as a trusted remote switch.

**Get a second opinion on finished work, for free (idle credits):** `nightshift review on` — once the normal task queue comes back genuinely empty for a run, a stronger model (`sonnet`/default `-> opus -> fable`) takes one more pass at the highest-priority completed-but-unreviewed issue, reads the PR it produced, and fixes anything it finds before the run ends. Off by default; `nightshift review off` reverts, `nightshift review status` shows the current setting. Staged — see below. Full design in [DESIGN.md](DESIGN.md#roadmap-built-staged-for-integration).

**Review finished work:** PRs land on the target repo, titled `Task #N: ...` and linked back to the hub issue, which flips to `status:in-review` with a phone ping. Merge, request changes, or close.

**Add a new project:** create its repo, protect its default branch, add it to the PAT's repository list. That's the whole enrollment step — the agent clones it into a `workspaces/` folder the first time a task names it.

**Missing a credential or connector?** The agent doesn't stall silently — it scaffolds everything it can, pushes it, and leaves a `HANDOFF.md` plus a checklist comment stating exactly what to enable and what it'll do once you have.

**Tune the burn rate:** after a normal week, check `~/claude-night-shift/logs/usage-log.csv` for how many weekly-usage points your actual workdays cost per hour, and set `PCT_PER_WORK_HOUR` in `config.env` to that. Full math in [DESIGN.md](DESIGN.md#the-budget-algorithm).

**Update the runner itself:** edit files under `ops/`, push, then re-run `bash ~/claude-night-shift/tasks-repo/ops/install.sh`. This step is deliberately manual — the agent cannot update the code that governs it.

**Uninstall it:** once you've applied the staged roadmap items, `bash ~/claude-night-shift/uninstall.sh` unloads the scheduled job and removes the installed scripts, leaving `logs/`, `secrets/`, and your config alone (`--purge` removes those too).

---

## Applying the staged roadmap items

Cross-platform install (Linux/Windows), the secret-leak scanner, the original CLI polish (`nightshift model`/`nightshift logs`/`uninstall.sh`), and the wiring that makes `CONTROL.md` actually take effect have already been applied — they live directly in `repo/ops/`/`repo/.claude/` now, not staged.

**Currently staged: the Review System** (`nightshift review`, see above) — fully built, but it lives under `repo/proposed/` instead of directly in `repo/ops/`/`repo/.claude/`. That's not an oversight: Night Shift's own agent is permanently denied write access to `ops/`, `.claude/`, `.github/`, `CLAUDE.md`, and `RUNNER_PROMPT.md`, in every repo it ever touches — including this one, which is the reason it can never rewrite the instructions that govern it. The catch is that *this* repo's actual product is a set of files that happen to live at exactly those paths (they're the template you copy into your own hub repo), so that same protection blocks the agent from finishing its own product development. A human has to make this one copy — and will again, any time a future task needs to touch `ops/`/`.claude/` the same way.

It's a single command:

```bash
cd claude-tasks-hub-repo-clone   # wherever you copied repo/ into
bash apply-roadmap.sh            # backs up ops/ + .claude/, copies proposed/* into place, shows a diff
```

`REVIEW_PROMPT.md` itself needs no manual patch — it's a brand-new file, not an edit to an existing protected one, so it already shipped live at the repo root (the same way `CONTROL.md` did). Review the diff `apply-roadmap.sh` shows you, commit, push, and re-run `ops/install.sh` (or `install.ps1` on Windows) to pick up the new scripts.

**Honesty about testing:** the Review System's pure logic (model-escalation ladder, pending-candidate selection) was unit-tested in isolation, `apply-roadmap.sh` was dry-run against a scratch copy of `repo/`, and `nightshift review on/off/status` was run against a scratch install — see [DESIGN.md](DESIGN.md#roadmap-built-staged-for-integration) for specifics. The actual end-to-end review invocation (a real `claude -p` call reviewing a real PR) hasn't been exercised — that needs a live run. The earlier batch (secret scanner, CLI additions) was run and verified in this sandbox at the time; the Linux `systemd --user` unit files and Windows PowerShell scripts were written carefully against their platform docs but, this sandbox being macOS-only, were never executed on real Linux/Windows hardware — treat them as code-reviewed, not field-tested, and sanity-check the first scheduled run on either platform.

---

## Safety, in short

Every layer is designed to fail closed: filesystem writes are OS-sandboxed to the task folder, network access is allowlisted at the socket level, the agent's own tools refuse to edit `CLAUDE.md`, `RUNNER_PROMPT.md`, `REVIEW_PROMPT.md` (once the staged Review System wiring is applied), `CONTROL.md`, `.claude/`, `ops/`, or `.github/` in any repo it ever touches, the fine-grained PAT is the only thing that decides which repos exist for it at all, and any error anywhere in the budget check means *don't run* rather than *run anyway*. Before editing a freshly cloned project repo, `ops/secret_scan.py` scans it for accidentally-committed credentials (GitHub/Anthropic/AWS/Slack token shapes, PEM headers, and a generic high-entropy heuristic); a hit stops the agent from touching that repo further and flags you instead, printing only the file and pattern that matched, never the value. The full layer-by-layer breakdown, plus the things that are genuinely still caveats (an undocumented usage endpoint, hostname-level network allowlisting, a shared GitHub identity), is in [DESIGN.md](DESIGN.md#safety-model-layered) — worth reading before you point this at anything you care about.

## License

MIT — see [LICENSE](LICENSE).
