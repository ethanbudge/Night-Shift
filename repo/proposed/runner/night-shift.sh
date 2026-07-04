#!/bin/bash
# Night Shift runner: invoked hourly by launchd (macOS) or a systemd --user
# timer (Linux). Checks the budget gates, then works tasks one claude
# invocation at a time, re-checking the budget between each. Every failure
# path exits WITHOUT running claude (fail closed).
#
# Windows has its own wrapper (night-shift.ps1) rather than trying to run this
# script under WSL -- see DESIGN.md's cross-platform section for why.
set -u

BASE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.env
source "$BASE/config.env"
export WORK_START_HOUR WORK_END_HOUR WORKDAYS PCT_PER_WORK_HOUR SAFETY_FACTOR \
       MIN_SURPLUS_START MIN_SURPLUS_CONTINUE WEEKLY_HARD_CAP \
       FIVE_HOUR_MAX_START FIVE_HOUR_MAX_CONTINUE LOG_DIR MODE_FILE MODEL \
       SECRETS_DIR GITHUB_REPO

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/night-shift.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# PATH lookup rather than a hardcoded /usr/bin/python3: that path isn't
# guaranteed on every Linux distro, and isn't guaranteed on macOS forever
# either. check_budget.py itself is stdlib-only and runs on any python3.
PYTHON3="$(command -v python3 || true)"
if [ -z "$PYTHON3" ]; then
    log "no python3 on PATH; aborting"
    exit 0
fi

# --- single-instance lock (mkdir is atomic; recover if the holder is dead) ---
LOCKDIR="$BASE/.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    oldpid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        exit 0   # a previous run is still working; that's fine
    fi
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT

# Keep the machine awake for the duration of this process only. macOS has
# caffeinate; Linux's equivalent is systemd-inhibit (a no-op with a log line
# if it isn't present, e.g. a systemd-less container or WSL1).
case "$(uname -s)" in
    Darwin)
        caffeinate -i -w $$ &
        ;;
    Linux)
        if command -v systemd-inhibit >/dev/null 2>&1; then
            systemd-inhibit --what=sleep --why="Night Shift run" --mode=block \
                tail -f /dev/null --pid=$$ >/dev/null 2>&1 &
        else
            log "systemd-inhibit not found; proceeding without a sleep inhibitor"
        fi
        ;;
esac

budget() { "$PYTHON3" "$BASE/check_budget.py" --mode "$1" 2>>"$LOG"; }

# --- Gate check (with one token-refresh retry on exit code 3) ---------------
decision="$(budget start)"; rc=$?
if [ "$rc" -eq 3 ]; then
    log "OAuth token stale; refreshing with a minimal claude call"
    "$CLAUDE_BIN" -p "Reply with exactly: ok" --model claude-haiku-4-5-20251001 \
        >/dev/null 2>>"$LOG"
    decision="$(budget start)"; rc=$?
fi
if [ "$rc" -ne 0 ]; then
    log "no-go (rc=$rc): $decision"
    exit 0
fi
log "GO: $decision"

# --- Prepare the repo clone ---------------------------------------------------
if [ ! -f "$SECRETS_DIR/github-token" ]; then
    log "missing $SECRETS_DIR/github-token; aborting"
    exit 0
fi
GH_TOKEN="$(cat "$SECRETS_DIR/github-token")"
export GH_TOKEN GITHUB_REPO

cd "$REPO_DIR" || { log "REPO_DIR $REPO_DIR missing; aborting"; exit 0; }
git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPO}.git"
if ! git fetch origin 2>>"$LOG"; then
    log "git fetch failed; aborting"
    exit 0
fi
git checkout -q main && git reset -q --hard origin/main && git clean -qfd

# --- Task loop -----------------------------------------------------------------
tasks=0
while [ "$tasks" -lt "$MAX_TASKS_PER_RUN" ]; do
    decision="$(budget continue)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        log "stopping loop (rc=$rc): $decision"
        break
    fi

    RUN_LOG="$LOG_DIR/task-$(date '+%Y%m%d-%H%M%S').json"
    log "task invocation $((tasks + 1)) -> $RUN_LOG"

    # macOS/older Linux distros may lack timeout(1); perl's alarm gives a
    # hard wall-clock cap everywhere perl is present (macOS and virtually
    # every Linux base image ship it).
    #
    # Model precedence: CONTROL.md's model line (fetched by check_budget.py
    # and riding along in $decision as model_override) beats the local MODEL
    # knob in config.env, which beats the account default -- CONTROL.md is
    # the "I'm away and need to change this right now" channel, so it should
    # win over a setting that requires being at the machine to change.
    effective_model="$("$PYTHON3" -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except (ValueError, IndexError):
    d = {}
print(d.get("model_override") or "")
' "$decision" 2>/dev/null)"
    [ -z "$effective_model" ] && effective_model="${MODEL:-}"
    model_args=()
    [ -n "$effective_model" ] && model_args=(--model "$effective_model")
    perl -e 'alarm shift; exec @ARGV' "$((TASK_TIMEOUT_MIN * 60))" \
        "$CLAUDE_BIN" -p "$(cat "$REPO_DIR/RUNNER_PROMPT.md")" \
        --settings "$BASE/runner-settings.json" \
        --permission-mode acceptEdits \
        --max-turns "$MAX_TURNS_PER_TASK" \
        --output-format json \
        "${model_args[@]}" \
        > "$RUN_LOG" 2>>"$LOG"
    rc=$?
    tasks=$((tasks + 1))

    if grep -q "NO_ACTIONABLE_TASKS" "$RUN_LOG" 2>/dev/null; then
        log "queue empty; done for now"
        break
    fi
    if [ "$rc" -eq 142 ]; then
        log "task invocation hit the ${TASK_TIMEOUT_MIN}m wall clock; WIP is on its branch, will resume next run"
        continue
    fi
    if [ "$rc" -ne 0 ]; then
        log "claude exited rc=$rc (usage limit or error); stopping loop"
        break
    fi
    result="$(grep -o 'TASK_COMPLETE [0-9]* [A-D]' "$RUN_LOG" 2>/dev/null | head -1 || true)"
    log "invocation finished: ${result:-no completion marker}"

    # reset to a clean main before the next task selection
    git checkout -q main && git reset -q --hard origin/main && git clean -qfd
done

log "run complete; task invocations: $tasks"
