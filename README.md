# Claude Night Shift

An unattended system that spends your idle Claude credits on a backlog of tasks — overnight and on weekends — without ever touching the credits you need during your workday, and without ever bypassing your weekly limit.

**How it works in one paragraph:** a macOS `launchd` job on your always-on desktop wakes a guard script every hour. The guard checks three gates — (1) is it outside working hours, (2) would a 5-hour usage window opened now still be open when your workday starts, (3) does your *real* server-side usage (fetched from Anthropic's usage endpoint) leave enough weekly headroom for your remaining work hours before the weekly reset. (A `day-off`/`vacation` toggle can waive the schedule gates — see [Daily usage](#daily-usage).) Only if all gates pass does it launch Claude Code headlessly, one task at a time, inside an OS-enforced sandbox that can only write to the task repo folder and only reach an explicit allowlist of domains. Tasks live as GitHub Issues in a single private hub repo, but each task can target any of your project repos — the agent clones the target into a `workspaces/` folder inside its sandbox, works on a branch there, and opens the PR on that project. Questions for you land as issue comments under a `status:needs-human` label (with a push notification to your phone), and you answer by simply replying to the comment.

---

## Repository layout (what's in this folder)

| Path | What it is |
|---|---|
| [DESIGN.md](DESIGN.md) | Architecture, the budget algorithm, safety model, known risks |
| [repo/](repo/) | The complete contents of the GitHub tasks repo you'll create |
| [repo/CLAUDE.md](repo/CLAUDE.md) | The agent's standing operating manual (loaded automatically every run) |
| [repo/RUNNER_PROMPT.md](repo/RUNNER_PROMPT.md) | **The prompt** — passed to `claude -p` on every task invocation |
| [repo/.claude/settings.json](repo/.claude/settings.json) | Project-scope sandbox rules (filesystem + network lockdown) |
| [repo/ops/](repo/ops/) | Guard scripts, config, launchd plist, installer — canonical copies |

---

## Setup guide (run on the always-on desktop)

### Step 1 — Install the Claude Code CLI and log in

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude   # then run /login and sign in with your Pro account
```

The login stores an OAuth token in the macOS Keychain (item `Claude Code-credentials`). The guard script reads this token to query your real usage.

### Step 2 — Create the GitHub tasks repo

1. Create a **private** repo on GitHub (e.g. `claude-tasks`). This is the **hub**: all task issues, questions, and answers live here, even for work that lands in other repos.
2. Copy everything under `repo/` into it and push.
3. **Protect `main`**: Settings → Branches → add a ruleset/branch protection on `main` requiring pull requests. This is a safety layer — it makes it impossible for the agent to alter its own instructions or config on `main`; all its work arrives as PRs you review. Do the same on each project repo's default branch.
4. Create a **fine-grained personal access token** (Settings → Developer settings → Fine-grained tokens):
   - Repository access: **this repo plus each project repo** you want the agent to work on. This list is the chokepoint that decides what the agent can ever touch — when you start a new project, add its repo here.
   - Permissions: Contents **Read & write**, Issues **Read & write**, Pull requests **Read & write**, Metadata **Read**
   - Set an expiry you're comfortable rotating.
5. **Set up phone notifications** (ntfy.sh): pick a long random topic name (it acts as a password, e.g. `nightshift-x7k2m9qframble`), add it as an Actions secret named `NTFY_TOPIC` (repo Settings → Secrets and variables → Actions), then install the free [ntfy app](https://ntfy.sh) on your phone and subscribe to that topic. The included workflow pushes a notification **only** when the agent needs your input or finishes a task. (Note: GitHub's own notifications won't fire for agent activity, because the agent acts as *your* account and GitHub never notifies you about yourself.)

### Step 3 — Install the night-shift runner

```bash
mkdir -p ~/claude-night-shift
git clone https://github.com/<you>/claude-tasks.git ~/claude-night-shift/tasks-repo
cd ~/claude-night-shift/tasks-repo/ops
bash install.sh
```

The installer copies the scripts to `~/claude-night-shift/` (deliberately **outside** the repo, so the sandboxed agent can never modify the code that governs it), creates `logs/` and `secrets/`, and installs the launchd job.

Then:

```bash
# Put your fine-grained PAT in the secrets file:
printf '%s' 'github_pat_XXXX' > ~/claude-night-shift/secrets/github-token
chmod 600 ~/claude-night-shift/secrets/github-token

# Review/edit the config (repo slug, thresholds, hours):
open -e ~/claude-night-shift/config.env

# Create the status/priority labels on the repo:
GH_TOKEN=$(cat ~/claude-night-shift/secrets/github-token) bash ~/claude-night-shift/tasks-repo/ops/setup-labels.sh
```

### Step 4 — One-time trust and keychain approval

```bash
# Trust the repo folder in Claude Code (accept the trust prompt):
cd ~/claude-night-shift/tasks-repo && claude
# type /exit once it's open

# Run the guard once manually. If macOS shows a keychain prompt for
# "security", click "Always Allow" so unattended runs can read the token:
python3 ~/claude-night-shift/check_budget.py --mode start; echo "exit: $?"
```

Exit code meanings: `0` = would run, `1` = correctly refusing (e.g. it's work hours right now — expected during the day), `2` = error, `3` = OAuth token expired (the runner refreshes this automatically).

### Step 5 — Keep the desktop awake

System Settings → Energy: set the machine to never sleep (display sleep is fine). `launchd` cannot fire while the machine is asleep. The runner also wraps itself in `caffeinate` during runs as a belt-and-suspenders measure.

### Step 6 — Verify

```bash
# Dry-run the whole pipeline at an off-hours moment (evening/weekend):
bash ~/claude-night-shift/night-shift.sh
tail -50 ~/claude-night-shift/logs/night-shift.log
```

---

## Daily usage

**Adding a task:** open a GitHub Issue in the hub repo using the "Task" template (the GitHub mobile app works great for this). Fill in the **Target repository** (`owner/name` of the project repo the work should land in, or blank for standalone work inside the hub repo), give it a `priority:high|medium|low` label and `status:ready`, and write a clear *definition of done* — the agent works strictly from the issue text and verifies against the DoD before opening a PR. To sequence tasks, put `Depends on #N` in the issue body; it won't be picked up until issue N closes.

**Answering questions:** when the agent needs you, the issue gets `status:needs-human` and one consolidated comment listing numbered questions (with the agent's proposed defaults) — and your phone gets an ntfy push. **Just reply to the comment** (replying "defaults" is always valid) — you don't need to touch labels. The agent marks its own comments with a `🤖 Night Shift` header; any comment without that header is treated as your answer, and the task is picked up again on the next run.

**Days off and vacations:** the guard normally protects your workday hours and reserves weekly budget for them. Two overrides, managed with the `nightshift` command on the desktop (or by editing `~/claude-night-shift/mode`):

```bash
nightshift status                  # current mode + what the guard would decide right now
nightshift day-off                 # run anytime TODAY; auto-reverts at midnight
nightshift day-off 2026-07-04      # ...or through a given date (inclusive)
nightshift vacation 2026-07-20     # also stop reserving weekly budget, through the date
nightshift vacation                # open-ended vacation (until `nightshift normal`)
nightshift normal                  # back to default
```

`day-off` skips the working-hours and session-overlap gates. `vacation` additionally drops the weekly reserve. Both keep the hard caps (weekly 85%, 5-hour window limits) so the agent can never lock you out of Claude on your phone. The mode file lives outside the sandbox, so the agent can't flip its own switches.

**Reviewing work:** finished tasks arrive as pull requests **on the target repo**, linked to their hub issue (`Closes owner/claude-tasks#N` auto-closes it on merge), with the issue labeled `status:in-review` and a push notification sent. Merge, request changes (a PR review comment also counts as human input), or close.

**Adding a new project:** create its GitHub repo, protect its default branch, and add it to the fine-grained PAT's repository list. That's it — the agent clones it into `workspaces/` on demand the first time a task targets it.

**Missing connectors/credentials:** the agent won't give up — it builds the scaffold, pushes it, and leaves a `HANDOFF.md` + checklist comment telling you exactly what to enable and what it will do once you have.

**Tuning the burn rate:** after the first normal week, open `~/claude-night-shift/logs/usage-log.csv`, see how many percentage points of weekly usage your actual workdays consume per hour, and set `PCT_PER_WORK_HOUR` in `config.env` accordingly. Full explanation in [DESIGN.md](DESIGN.md#the-budget-algorithm).

**Updating the runner scripts:** edit them in the repo, push, then re-run `bash ~/claude-night-shift/tasks-repo/ops/install.sh`. Installation is deliberately manual — the agent cannot update its own runner.
