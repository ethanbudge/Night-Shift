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
    ├─► check_queue.py                   ── cheap non-LLM pre-check: any open
    │                                        status:ready/in-progress/needs-human
    │                                        issue at all? Fails open to "proceed"
    │                                        on any doubt; skips the claude
    │                                        invocation entirely only when
    │                                        provably empty. See "Efficiency"
    │                                        in the README.
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

`nightshift begin-run` is a second, manual entry point into the exact same `night-shift.sh`: it runs the identical gates and grabs the same single-instance lock the hourly timer uses, then hands off to the normal run. So an on-demand start and a scheduled start can never overlap, and neither can bypass the budget — `begin-run` is purely a "start now instead of waiting for `:07`" button (typically paired with `nightshift day-off`), never a way around a gate. The `mode.sh` wrapper does a fast pre-flight of the same lock and gate first, purely so it can refuse with a readable reason instead of a silent no-op; `night-shift.sh` re-checks both authoritatively.

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
- **Model choice:** overnight runs use your account's default model (Sonnet) unless `MODEL` is set in `config.env`. Opus 4.8 became available on the Pro plan in May 2026, so setting `MODEL` to an Opus model no longer requires Max — but Opus consumes weekly budget noticeably faster than Sonnet, which matters directly to the budget algorithm above (`PCT_PER_WORK_HOUR` calibration assumes whatever model actually ran). Long tasks may span multiple nights via WIP branches — that's by design.
- **Both you and the agent share one GitHub account** (comments distinguished by the agent's `🤖 Night Shift` header). Besides the cosmetic ambiguity, this is why native GitHub notifications stay silent (own activity) — the ntfy workflow exists to fill that gap. If you'd rather have a hard separation, create a free machine-user account, add it as a collaborator on the repos, and issue the PAT from it.
- **Timeouts leave tasks parked**, not lost: WIP is pushed to the task branch and resumed on a later run with fresh context.

## Why this shape (alternatives considered)

- **Claude scheduled tasks / cloud routines** instead of launchd: no always-on machine needed, but you lose the OS sandbox config, the local network allowlist, and (critically) the pre-flight credit guard. Your always-on desktop makes local strictly better.
- **`gh` CLI** instead of `curl` for GitHub: Go binaries can fail TLS verification under the macOS Seatbelt sandbox, and the documented workaround (excluding them from the sandbox) weakens isolation. Plain `git` + `curl` against the REST API work cleanly through the sandbox proxy, so that's what the agent uses.
- **One long `claude -p` session per night** instead of one-task-per-invocation: fewer cold starts, but you lose the between-task budget checkpoints, crash containment, and per-task context freshness. Checkpointing wins.

## Roadmap: built, staged for integration

Everything below is now fully implemented — not just specified — but it ships under [`repo/proposed/`](proposed/) rather than directly in `ops/`/`.claude/`, because writing there requires editing `ops/`, `.claude/`, `.github/`, `CLAUDE.md`, or `RUNNER_PROMPT.md` under `repo/` — and those exact path components are permanently write-denied to the Night Shift agent, in every repo it ever touches, including this one (see `RUNNER_PROMPT.md`'s hard rules — it's the same self-protection that stops the agent from loosening its own gates in a hub repo, applied literally). That's a real structural collision: this repo's product *is* a set of files that live at those paths. `repo/apply-roadmap.sh` does the one-time copy a maintainer needs to run by hand (see the README's [Applying the staged roadmap items](../README.md#applying-the-staged-roadmap-items)); everything else below was written, and where testable in a macOS sandbox, run and verified, by the agent.

**What's verified vs. code-reviewed only:** `secret_scan.py` and the CLI additions (`mode.sh`'s `model`/`logs` subcommands, `check_budget.py`'s CONTROL.md fetch and override-combining logic) were unit-tested against fixtures in this sandbox. The Linux `systemd --user` unit files and the Windows PowerShell scripts (`night-shift.ps1`, `install.ps1`) could not be executed here (macOS-only sandbox, no Linux/Windows box, no `pwsh` available) — they're careful, doc-reviewed implementations but genuinely untested end-to-end. Treat a first scheduled run on either platform as a dry run to watch.

**Cross-platform install.** Built: `proposed/runner/install.sh` (dispatches by `uname`), `proposed/runner/night-shift.sh` (Linux keep-awake + portable python3 lookup), `proposed/runner/nightshift.service`/`.timer`, `proposed/runner/night-shift.ps1`, and `proposed/runner/install.ps1`. To reach Linux and Windows without forking the guard logic, the design was:
- Keep `check_budget.py` as the single source of truth for the three gates — it's already stdlib-only Python, which runs unmodified on all three OSes. Its `get_token()` already falls back from macOS Keychain to reading `~/.claude/.credentials.json` directly, which is exactly what Linux and Windows need (no Keychain equivalent required); it only needs the `security` subprocess call skipped up front on non-Darwin via `platform.system()` instead of relying on the `OSError` catch.
- **Linux:** replace `launchd` with a `systemd --user` timer + service pair (`OnCalendar=*-*-* *:07:00`, mirroring the `:07` launchd interval) installed via `systemctl --user enable --now`. Swap `caffeinate -i -w $$` for `systemd-inhibit --what=sleep --why="Night Shift run"` (fall back to a no-op with a log line if `systemd-inhibit` isn't present — e.g. WSL without systemd). Hardcoded `/usr/bin/python3` should become a `command -v python3` lookup; it isn't guaranteed at that path on every distro.
- **Windows:** as of the 2026 native installer, Claude Code runs natively on Windows without WSL, so a real Windows path is worth having rather than just recommending WSL. That means porting the *wrapper* (not the gate logic) to PowerShell: a `night-shift.ps1` that sources config, shells out to `python check_budget.py`, and loops `claude.exe` invocations exactly like `night-shift.sh` does. Scheduling via `Register-ScheduledTask` (hourly trigger, "wake the computer to run this task" enabled) replaces `launchd`; keep-awake via `powercfg /requestsoverride PROCESS <host-process> SYSTEM` for the run's duration, cleared in a `finally` block. `install.ps1` would mirror `install.sh`'s idempotent copy-then-schedule shape.
- None of the three platform wrappers should reimplement gate math — they should all shell out to the same `check_budget.py`.

**Remote control without touching the machine.** Built: [`repo/CONTROL.md`](CONTROL.md) itself ships live at the repo root (it isn't a protected path, so a prior run could add it directly); the wiring that makes it take effect — `check_budget.py`'s fetch + override-combining logic, and the `CONTROL.md` deny-list entries — is staged in `proposed/runner/check_budget.py`, `proposed/agent-settings/settings.json`, and `proposed/runner/runner-settings.json`. The one item from the old "not built" list here that had a real objection on the record: *"a GitHub-hosted switch would let \[the agent] loosen its own gates."* The fix is the same mechanism that already protects `CLAUDE.md`/`RUNNER_PROMPT.md`: `CONTROL.md` gets added to the *same* deny lists (`.claude/settings.json` `denyWrite`, `runner-settings.json` `Edit`/`Write` deny) that already protect the other governance files. Once the agent's own tools categorically cannot write it, only the owner (editing on github.com or the GitHub mobile app) can change it, and it's safe for `check_budget.py` to trust. Concretely:
- Format: plain `key: value` lines inside a normal Markdown doc (so it reads fine as a GitHub file), e.g. `mode: normal` / `model: claude-opus-4-8`, parsed with a tolerant regex that ignores surrounding prose.
- `check_budget.py` fetches `GET https://api.github.com/repos/$GITHUB_REPO/contents/CONTROL.md` with `Accept: application/vnd.github.raw` using the same PAT already on disk at `$SECRETS_DIR/github-token` (needs `SECRETS_DIR` and `GITHUB_REPO` exported a few lines earlier in `night-shift.sh`, before the first gate check rather than after it).
- Unlike the Anthropic usage check, this fetch is **not** safety-critical, so it should fail *open* to the existing local `~/claude-night-shift/mode` file on any error (missing file, network hiccup, bad PAT) — the local file stays the reliable fallback, `CONTROL.md` is the convenience layer on top.
- A resolved `model` override should ride along in the guard's JSON decision (`model_override`) so `night-shift.sh` can pick it up for that run without needing its own second API call.

**Secret-leak guard.** Built: `proposed/runner/secret_scan.py`, stdlib-only, unit-tested in this sandbox against fixtures covering every pattern below. DoD asks that if Night Shift finds a credential accidentally committed in a target repo, it stops editing that repo and flags it rather than continuing. Shape: scans a freshly cloned `workspaces/<name>` for common token shapes (`ghp_`/`github_pat_`/`sk-ant-`/AWS access keys/Slack tokens/PEM private-key headers) plus a generic high-entropy-assignment heuristic (keyword-containing variable name + a ≥20-char, ≥3.5-bits/char value), skipping `.git/` and binary files, printing `path:line: <pattern-name>` **without** ever printing the matched value, exit 0 clean / 1 findings. The `RUNNER_PROMPT.md` wiring (run it right after cloning, before any edit, and treat nonzero as a hard stop) is a two-line manual patch described in `proposed/runner-prompt-patch.md` — see that file for why this one edit can't be automated even by `apply-roadmap.sh`.

**CLI polish.** Built: `proposed/runner/mode.sh` adds `nightshift model [<id>|default]` (flips `MODEL` in `config.env` without hand-editing it, mirrors the existing day-off/vacation UX) and `nightshift logs [-f] [N]` (tail `night-shift.log`, default last 50 lines); both verified against a scratch install in this sandbox. `proposed/runner/uninstall.sh` reverses `install.sh` on macOS or Linux (unloads the launchd job / disables the systemd timer, removes the symlink, leaves `secrets/`+`logs/` untouched unless `--purge`).

**Housekeeping identified and fixed in the staged copies:** `night-shift.sh` and `mode.sh` no longer hardcode `/usr/bin/python3` — both now do a `command -v python3` PATH lookup, consistent with `check_budget.py`'s own shebang. `config.env` gained a comment noting `command -v claude` as the general `CLAUDE_BIN` fallback for non-default installs, and documenting `CONTROL.md`'s `model:` precedence over the local `MODEL` knob.

**Queue pre-check (skip the claude invocation on empty nights).** Built: `proposed/check_queue.py` plus the two-line integration in `proposed/night-shift.sh`, applied by `apply-efficiency-patch.sh` (same staged-then-applied shape as the items above, since it edits `ops/night-shift.sh`). Unit-tested against fixtures (all-labels-empty, one-label-nonzero, network error, missing env vars, malformed response) and live-tested against a real hub repo with open issues. See the README's "Efficiency" section for the full writeup, including the deliberate choice to check only the coarsest "is there any candidate at all" question rather than replicate `RUNNER_PROMPT.md`'s full selection logic.

- Auto-calibrate `PCT_PER_WORK_HOUR` from `usage-log.csv` history.
- A nightly digest: the agent opens/updates a single "📋 Night Shift Report" issue summarizing what it did.
- Route the initial "is there work?" pass through a cheaper model than task execution uses (see README's "Efficiency" section — deferred pending issue #12's model-routing design).
