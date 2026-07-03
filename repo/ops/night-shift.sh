#!/bin/bash
# Night Shift runner: invoked hourly by launchd. Checks the budget gates, then
# works tasks one claude invocation at a time, re-checking the budget between
# each. Every failure path exits WITHOUT running claude (fail closed).
set -u

BASE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.env
source "$BASE/config.env"
export WORK_START_HOUR WORK_END_HOUR WORKDAYS PCT_PER_WORK_HOUR SAFETY_FACTOR \
       MIN_SURPLUS_START MIN_SURPLUS_CONTINUE WEEKLY_HARD_CAP \
       FIVE_HOUR_MAX_START FIVE_HOUR_MAX_CONTINUE LOG_DIR MODE_FILE MODEL

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/night-shift.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

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

# Keep the machine awake for the duration of this process only.
caffeinate -i -w $$ &

budget() { /usr/bin/python3 "$BASE/check_budget.py" --mode "$1" 2>>"$LOG"; }

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

    # macOS has no timeout(1); perl's alarm gives us a hard wall-clock cap.
    model_args=()
    [ -n "${MODEL:-}" ] && model_args=(--model "$MODEL")
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
