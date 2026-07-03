# Claude Night Shift

An unattended system that spends your idle Claude credits on a backlog of tasks — overnight and on weekends — without ever touching the credits you need during your workday, and without ever bypassing your weekly limit.

**How it works in one paragraph:** a macOS `launchd` job on your always-on desktop wakes a guard script every hour. The guard checks three gates — (1) is it outside working hours, (2) would a 5-hour usage window opened now still be open when your workday starts, (3) does your *real* server-side usage (fetched from Anthropic's usage endpoint) leave enough weekly headroom for your remaining work hours before the weekly reset. Only if all three pass does it launch Claude Code headlessly, one task at a time, inside an OS-enforced sandbox that can only write to the task repo folder and only reach an explicit allowlist of domains. Tasks live as GitHub Issues in a single private repo; questions for you land as issue comments under a `status:needs-human` label, and you answer by simply replying to the comment.

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

1. Create a **private** repo on GitHub (e.g. `claude-tasks`).
2. Copy everything under `repo/` into it and push.
3. **Protect `main`**: Settings → Branches → add a ruleset/branch protection on `main` requiring pull requests. This is a safety layer — it makes it impossible for the agent to alter its own instructions or config on `main`; all its work arrives as PRs you review.
4. Create a **fine-grained personal access token** (Settings → Developer settings → Fine-grained tokens):
   - Repository access: **only this repo**
   - Permissions: Contents **Read & write**, Issues **Read & write**, Pull requests **Read & write**, Metadata **Read**
   - Set an expiry you're comfortable rotating.

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

**Adding a task:** open a GitHub Issue using the "Task" template. Give it a `priority:high|medium|low` label and `status:ready`. Write a clear *definition of done* — the agent works strictly from the issue text.

**Answering questions:** when the agent needs you, the issue gets `status:needs-human` and one consolidated comment listing numbered questions (with the agent's proposed defaults). **Just reply to the comment** — you don't need to touch labels. The agent marks its own comments with a `🤖 Night Shift` header; any comment without that header is treated as your answer, and the task is picked up again on the next run. GitHub notifications (email/app) are your inbox for all of this, in one place.

**Reviewing work:** finished tasks arrive as pull requests linked to their issue, labeled `status:in-review`. Merge, request changes (a PR review comment also counts as human input), or close.

**Missing connectors/credentials:** the agent won't give up — it builds the scaffold, pushes it, and leaves a `HANDOFF.md` + checklist comment telling you exactly what to enable and what it will do once you have.

**Tuning the burn rate:** after the first normal week, open `~/claude-night-shift/logs/usage-log.csv`, see how many percentage points of weekly usage your actual workdays consume per hour, and set `PCT_PER_WORK_HOUR` in `config.env` accordingly. Full explanation in [DESIGN.md](DESIGN.md#the-budget-algorithm).

**Updating the runner scripts:** edit them in the repo, push, then re-run `bash ~/claude-night-shift/tasks-repo/ops/install.sh`. Installation is deliberately manual — the agent cannot update its own runner.
