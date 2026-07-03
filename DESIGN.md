# Design: Claude Night Shift

## Architecture

```
 launchd (hourly, :07)
    │
    ▼
 night-shift.sh ──────────────── single-instance lock, caffeinate, logging
    │
    ├─► check_budget.py --mode start     ── the three gates (below). Fail closed.
    │        │
    │        ├─ reads ~/claude-night-shift/mode  (day-off / vacation override)
    │        └─ reads OAuth token (Keychain) ─► GET api.anthropic.com/api/oauth/usage
    │
    ├─► git reset repo clone to origin/main   (clean slate each run)
    │
    └─► LOOP (up to MAX_TASKS_PER_RUN):
          ├─► check_budget.py --mode continue   ── re-gate before EVERY task
          ├─► claude -p "$(cat RUNNER_PROMPT.md)"
          │       --settings runner-settings.json   (sandbox + permissions)
          │       --max-turns N, wrapped in a hard wall-clock timeout
          │       → works exactly ONE task, then exits
          └─► stop on: budget says no / queue empty / usage-limit error / timeout
```

Task state lives entirely in GitHub Issues:

```
status:ready ──► status:in-progress ──► status:in-review (PR opened) ──► you merge & close
                      │                        ▲
                      ▼                        │
               status:needs-human ── you reply to the comment ──┘ (agent resumes)
```

## The three gates

1. **Working hours gate.** If local time is inside 8AM–6PM Mon–Fri, exit immediately. (Configurable: `WORK_START_HOUR`, `WORK_END_HOUR`, `WORKDAYS`.)

2. **Session-collision gate.** A 5-hour usage window opens at your first message and everything sent within it counts against one session cap. If `now + 5h` reaches past the next workday's 8AM start, a run now would leave you with a partially-consumed window at the start of your day — so the guard blocks new work from 3AM onward on weekday mornings. Corollary: a window opened *at* ~3AM resets at exactly 8AM, which is the "credits refresh right before my day starts" behavior you wanted. Weekends are unrestricted until 3AM Monday.

3. **Weekly budget gate (dynamic).** See below.

**Schedule overrides.** The owner can waive the schedule protection via a mode file at `~/claude-night-shift/mode` (managed by the `nightshift` helper, `ops/mode.sh`). `day-off` skips gates 1–2 (dateless = today only, auto-expiring at midnight so a forgotten toggle can't eat a workday's credits); `vacation` skips gates 1–2 **and** zeroes the workday reserve in gate 3. The weekly hard cap and 5-hour caps always apply, so even open-ended vacation mode can't burn the account to 100%. The file lives outside the sandbox, so the agent cannot loosen its own gates; anything unparseable or expired collapses to `normal`.

## The budget algorithm

The guard queries `https://api.anthropic.com/api/oauth/usage` with your Claude Code OAuth token. This returns your **actual server-side** utilization — the same numbers the `/usage` screen shows:

```json
{
  "five_hour": { "utilization": 8.0,  "resets_at": "..." },
  "seven_day": { "utilization": 42.0, "resets_at": "..." }
}
```

The dynamic reservation you asked for:

```
work_hours_remaining = count of hours between now and seven_day.resets_at
                       that fall inside your working hours
reserve  = work_hours_remaining × PCT_PER_WORK_HOUR × SAFETY_FACTOR
surplus  = (100 − seven_day.utilization) − reserve

GO if surplus ≥ MIN_SURPLUS_START   (8 points to start a run)
     and surplus ≥ MIN_SURPLUS_CONTINUE (3 points to start each next task)
     and seven_day.utilization < WEEKLY_HARD_CAP (85)
     and five_hour.utilization < FIVE_HOUR_MAX (90 start / 95 continue)
```

This gives exactly the behavior you described: on Sunday night with the whole workweek ahead, the reserve is large and the agent is cautious; in the hours before the weekly reset, `work_hours_remaining → 0`, the reserve evaporates, and the agent burns whatever is left. If the reset lands mid-week, the math follows `resets_at` — it never assumes a calendar week.

**Calibrating `PCT_PER_WORK_HOUR`:** this is the one number the API can't tell us — how much weekly budget *you* personally consume per working hour. Default is `1.0` (i.e., a 50-hour workweek reserves 50 points × 1.25 safety). Every guard invocation appends a row to `usage-log.csv`; after a normal week, compute `(utilization Friday 6PM − utilization Monday 8AM) ÷ your work hours` and set that (the log makes this a 2-minute job). Since you're "usually well under" your weekly limit, the real number is probably well below 1.0, which will free up more overnight budget.

**Mid-run enforcement:** the budget is re-checked between every task, and each `claude -p` invocation is additionally capped by `--max-turns` and a hard wall-clock timeout. If Claude hits the actual 5-hour session cap mid-task, the CLI exits with an error, the wrapper detects it and stops the loop; the task stays `status:in-progress` and is resumed (from its pushed WIP branch) on a later run.

**Fail closed:** any error — token missing, endpoint changed, network down, unparseable response — results in *not running*. The only credits this system can ever burn are ones the guard affirmatively verified as surplus.

## Safety model (layered)

| Layer | Mechanism | What it guarantees |
|---|---|---|
| OS sandbox (filesystem) | Seatbelt via Claude Code sandbox; writes allowed **only** in the repo clone + session tmp | Even a malicious/buggy shell command can't touch the rest of the disk |
| OS sandbox (reads) | `denyRead: ~/` with `allowRead: .` (project scope) + credential file denies | Bash subprocesses can't read your home dir, SSH keys, AWS creds, Claude credentials |
| OS sandbox (network) | Proxy allowlist: `github.com`, `api.github.com`, `*.githubusercontent.com`, package registries. Everything else blocked at the socket layer, prompts impossible headlessly | "Read the internet" is via WebFetch/WebSearch (GET-only tools); arbitrary outbound traffic from shell commands is blocked |
| Strict mode | `allowUnsandboxedCommands: false`, `failIfUnavailable: true` | No escape hatch: a command either runs sandboxed or not at all |
| Permission rules | Deny `Edit`/`Write` on `.claude/`, `ops/`, `CLAUDE.md`, `RUNNER_PROMPT.md`; deny `Read` on key credential paths (defense-in-depth for Claude's own file tools, which sit outside the Bash sandbox) | The agent cannot rewrite its own rules or read secrets via the Read tool |
| Sandbox denyWrite | Same governance paths denied at the OS layer too | Shell commands can't do what the file tools were denied |
| GitHub | Fine-grained PAT scoped to the hub repo + explicitly named project repos; default branches protected (PRs required) | Worst-case blast radius on GitHub is branches/issues of repos you deliberately enrolled; instructions on `main` are immutable to the agent |
| Runner isolation | Guard scripts + settings live in `~/claude-night-shift/`, **outside** the sandbox's writable area; updates require you to re-run `install.sh` | The agent can never modify the guard that constrains it |
| Headless permission behavior | In `-p` mode there is no human to prompt, so anything not pre-allowed is **auto-denied** and the agent must adapt | No "prompt fatigue" holes; denials are logged in the transcript |
| Budget caps | The three gates + per-task `--max-turns` + wall-clock timeout + `MAX_TASKS_PER_RUN` | Bounded worst-case burn even if everything else misbehaves |

## Multi-repo: hub and spokes

Task issues live in one hub repo (`claude-tasks`); each issue may name a **target repository** where the work lands. The agent clones targets *inside* its existing sandbox, under a gitignored `workspaces/` folder in the hub clone:

```
tasks-repo/            ← agent working dir; sandbox unchanged (writes only inside ".")
├── governance files   ← still write-denied (.claude/, ops/, .github/, *.md)
└── workspaces/        ← gitignored; one persistent clone per project repo
```

Why inside rather than sibling folders: the OS sandbox's write boundary, the settings files, and the installer all stay exactly as they were — no new writable areas, no per-project configuration. `git clean -fd` in the runner's reset step skips both ignored paths and nested git repos, so workspace clones persist across runs without being re-downloaded. Issue numbers are hub-global, so `task/<n>-slug` branch names can't collide across projects, and a PR body of `Closes owner/claude-tasks#n` auto-closes the hub issue when the project PR merges. Enrollment of a new project is deliberate and singular: add the repo to the fine-grained PAT (and protect its default branch). A repo the PAT doesn't cover fails at clone time and becomes a handoff comment.

## Notifications

GitHub's native notifications do **not** work here: the agent authenticates with the owner's PAT, its comments are the owner's own activity, and GitHub never notifies you about yourself. Instead, a GitHub Action (`.github/workflows/notify.yml`) fires on exactly two label events — `status:needs-human` (questions) and `status:in-review` (PR ready) — and curls a push to a private [ntfy.sh](https://ntfy.sh) topic (stored as an Actions secret; the topic name is effectively the password, so make it long and random). The phone app subscribes to the topic; tapping the notification opens the issue. Everything else (creating tasks, replying, merging) happens in the GitHub mobile app or web. If you ever want hard separation of identities (and native GitHub notifications), a free machine-user account holding the PAT is the upgrade path.

## Known risks and honest limitations

- **The usage endpoint is undocumented.** It's what community status-line tools use, it's stable in practice, and it requires your own OAuth token — but Anthropic could change it. If that happens the guard fails closed (night shift silently stops running, your credits are untouched) and you'd see it in the log. Anthropic has open feature requests for an official equivalent ([#32796](https://github.com/anthropics/claude-code/issues/32796), [#44328](https://github.com/anthropics/claude-code/issues/44328)); swap it in when it ships.
- **OAuth token expiry.** The access token expires periodically; the CLI refreshes it whenever it runs. The wrapper handles a 401 by making one minimal Haiku call (`claude -p "ok"`) to trigger a refresh, then retries the check once. Cost: negligible.
- **Network allowlisting is by hostname, not content.** The sandbox proxy doesn't inspect TLS, so a hostile payload could in principle abuse an allowed domain (the docs themselves flag `github.com` + domain-fronting). Mitigations: the agent only handles content from your own private repo, its readable surface is essentially just that repo, and the PAT limits GitHub writes to it. Residual risk is low but not zero — this is the main caveat to "foolproof."
- **WebFetch can GET arbitrary URLs** (that's the "read-only internet" you wanted), and a GET's query string is technically an outbound channel. Same mitigation as above: there's nothing sensitive in the agent's readable world to leak. If you want maximum lockdown, add `WebFetch` deny rules or an allowlist of research domains in `runner-settings.json`.
- **Pro plan realities:** overnight runs use your default model (Sonnet); Opus isn't part of Pro. Long tasks may span multiple nights via WIP branches — that's by design.
- **Both you and the agent share one GitHub account** (comments distinguished by the agent's `🤖 Night Shift` header). Besides the cosmetic ambiguity, this is why native GitHub notifications stay silent (own activity) — the ntfy workflow exists to fill that gap. If you'd rather have a hard separation, create a free machine-user account, add it as a collaborator on the repos, and issue the PAT from it.
- **Timeouts leave tasks parked**, not lost: WIP is pushed to the task branch and resumed on a later run with fresh context.

## Why this shape (alternatives considered)

- **Claude scheduled tasks / cloud routines** instead of launchd: no always-on machine needed, but you lose the OS sandbox config, the local network allowlist, and (critically) the pre-flight credit guard. Your always-on desktop makes local strictly better.
- **`gh` CLI** instead of `curl` for GitHub: Go binaries can fail TLS verification under the macOS Seatbelt sandbox, and the documented workaround (excluding them from the sandbox) weakens isolation. Plain `git` + `curl` against the REST API work cleanly through the sandbox proxy, so that's what the agent uses.
- **One long `claude -p` session per night** instead of one-task-per-invocation: fewer cold starts, but you lose the between-task budget checkpoints, crash containment, and per-task context freshness. Checkpointing wins.

## Future ideas (not built)

- Auto-calibrate `PCT_PER_WORK_HOUR` from `usage-log.csv` history.
- A nightly digest: the agent opens/updates a single "📋 Night Shift Report" issue summarizing what it did.
- A phone-flippable day-off/vacation toggle (e.g. a control issue on GitHub). Deliberately not built yet: the agent can write to the hub repo, so a GitHub-hosted switch would let it loosen its own gates unless the machine-account split happens first.
