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
       MODEL_ALLOWLIST SECRETS_DIR GITHUB_REPO

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

# Resolve the model a decision JSON blob implies right now: CONTROL.md's
# model line (riding along as model_override) beats the picked task's
# model:<tag> label (riding along as task_model_id), which beats the local
# MODEL knob, which beats the account default. Shared by the task loop and the
# review loop below so the two can't drift out of sync on precedence. (During
# the review loop the queue is empty, so no task is selected and task_model_id
# is absent -- the helper then collapses to model_override, as before.)
effective_model_for() {
    "$PYTHON3" -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except (ValueError, IndexError):
    d = {}
print(d.get("model_override") or d.get("task_model_id") or "")
' "$1" 2>/dev/null
}

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

# --- Load the token now: both the queue pre-check below and the repo clone
# further down need it. -----------------------------------------------------
if [ ! -f "$SECRETS_DIR/github-token" ]; then
    log "missing $SECRETS_DIR/github-token; aborting"
    exit 0
fi
GH_TOKEN="$(cat "$SECRETS_DIR/github-token")"
export GH_TOKEN GITHUB_REPO

# --- Cheap pre-check: is there provably nothing to do? -----------------------
# check_queue.py makes a few small REST calls (no LLM involved) to ask only
# "does any open issue carry an actionable status label at all?" -- the full
# selection logic (Depends-on chains, 3-hour abandon window, human-reply
# detection) stays exclusively in the agent's judgment on the runs that do
# proceed. On a fully-drained backlog, which is most nights, this replaces an
# entire `claude -p` invocation (that would just conclude NO_ACTIONABLE_TASKS
# anyway) with three small HTTP calls. It fails open: any ambiguity, error, or
# missing env var falls through to invoking claude exactly as before.
if ! "$PYTHON3" "$BASE/check_queue.py" 2>>"$LOG"; then
    log "queue empty (pre-check); skipping claude invocation this run"
    exit 0
fi

# --- Prepare the repo clone ---------------------------------------------------
cd "$REPO_DIR" || { log "REPO_DIR $REPO_DIR missing; aborting"; exit 0; }
git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPO}.git"
if ! git fetch origin 2>>"$LOG"; then
    log "git fetch failed; aborting"
    exit 0
fi
git checkout -q main && git reset -q --hard origin/main && git clean -qfd

# --- Task loop -----------------------------------------------------------------
tasks=0
queue_empty=0
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
    # Model precedence (highest wins):
    #   1. CONTROL.md's model line (fetched by check_budget.py, rides along in
    #      $decision as model_override) -- the "I'm away and need to change
    #      this right now" channel, so it beats everything, including a
    #      specific task's own request.
    #   2. task_model_id -- the model:<tag> label on the specific issue
    #      check_budget.py picked as the next task (resolved through
    #      MODEL_ALLOWLIST; absent whenever the issue has no tag, or an
    #      unrecognized one -- see check_budget.py's resolve_task_model()).
    #   3. MODEL from config.env -- the account-wide baseline.
    #   4. unset -- claude's own account default.
    # Resolution 1+2 happens in effective_model_for; 3+4 here.
    effective_model="$(effective_model_for "$decision")"
    [ -z "$effective_model" ] && effective_model="${MODEL:-}"
    model_args=()
    [ -n "$effective_model" ] && model_args=(--model "$effective_model")
    # ${model_args[@]+"${model_args[@]}"} not "${model_args[@]}": macOS ships
    # bash 3.2, which treats an empty array as unset under `set -u` and
    # aborts the whole run before claude is ever invoked.
    perl -e 'alarm shift; exec @ARGV' "$((TASK_TIMEOUT_MIN * 60))" \
        "$CLAUDE_BIN" -p "$(cat "$REPO_DIR/RUNNER_PROMPT.md")" \
        --settings "$BASE/runner-settings.json" \
        --permission-mode acceptEdits \
        --max-turns "$MAX_TURNS_PER_TASK" \
        --output-format json \
        "${model_args[@]+"${model_args[@]}"}" \
        > "$RUN_LOG" 2>>"$LOG"
    rc=$?
    tasks=$((tasks + 1))

    if grep -q "NO_ACTIONABLE_TASKS" "$RUN_LOG" 2>/dev/null; then
        log "queue empty; done for now"
        queue_empty=1
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
    log "invocation finished: ${result:-no completion marker} (model: ${effective_model:-account default})"

    # Record finished (end-state A) issues for the review pass below -- this
    # is the only source of truth the review loop has for "what got built
    # tonight," so it has to happen right here, not be reconstructed later.
    if [ -n "$result" ]; then
        finished_issue="$(echo "$result" | awk '{print $2}')"
        finished_state="$(echo "$result" | awk '{print $3}')"
        if [ "$finished_state" = "A" ]; then
            completions_csv="$LOG_DIR/completions.csv"
            [ -f "$completions_csv" ] || echo "timestamp,issue" > "$completions_csv"
            echo "$(date '+%Y-%m-%dT%H:%M:%S%z'),$finished_issue" >> "$completions_csv"
        fi
    fi

    # reset to a clean main before the next task selection
    git checkout -q main && git reset -q --hard origin/main && git clean -qfd
done

# --- Review pass -----------------------------------------------------------
# Only when the normal queue came back genuinely empty (not merely out of
# budget, time, or MAX_TASKS_PER_RUN) and REVIEW_MODE is on. This is what
# turns idle end-of-queue credits into a second look at tonight's work by a
# stronger model, per the "Review System" roadmap item in DESIGN.md.
if [ "$queue_empty" -eq 1 ] && [ "${REVIEW_MODE:-off}" = "on" ]; then
    completions_csv="$LOG_DIR/completions.csv"
    reviewed_csv="$LOG_DIR/reviewed.csv"
    touch "$reviewed_csv"

    pending() {
        "$PYTHON3" -c '
import csv, os, sys
comp, revd = sys.argv[1], sys.argv[2]
reviewed = set()
if os.path.exists(revd):
    with open(revd) as f:
        reviewed = {l.strip() for l in f if l.strip()}
seen = []
if os.path.exists(comp):
    with open(comp) as f:
        r = csv.reader(f)
        next(r, None)
        for row in r:
            if len(row) >= 2 and row[1] not in reviewed and row[1] not in seen:
                seen.append(row[1])
print(" ".join(seen))
' "$completions_csv" "$reviewed_csv"
    }

    candidates="$(pending)"
    if [ -n "$candidates" ]; then
        log "review mode on; candidates awaiting review: $candidates"
    fi

    while [ -n "$candidates" ] && [ "$tasks" -lt "$MAX_TASKS_PER_RUN" ]; do
        decision="$(budget continue)"; rc=$?
        if [ "$rc" -ne 0 ]; then
            log "stopping review loop (rc=$rc): $decision"
            break
        fi

        effective_model="$(effective_model_for "$decision")"
        [ -z "$effective_model" ] && effective_model="${MODEL:-}"
        # Escalation ladder the issue asked for: sonnet (or unset -> account
        # default, which is sonnet) -> opus -> fable. Fable has nothing above
        # it, so a review pass with fable already as the base model is skipped
        # rather than reviewing itself.
        review_model="$("$PYTHON3" -c '
import sys
m = (sys.argv[1] if len(sys.argv) > 1 else "").lower()
if "fable" in m:
    print("")
elif "opus" in m:
    print("claude-fable-5")
else:
    print("claude-opus-4-8")
' "$effective_model")"

        if [ -z "$review_model" ]; then
            log "review model already at the top tier (fable); skipping review pass"
            break
        fi

        RUN_LOG="$LOG_DIR/review-$(date '+%Y%m%d-%H%M%S').json"
        base_label="${effective_model:-account default}"
        log "review invocation -> $RUN_LOG (escalating $base_label -> $review_model)"

        review_prompt="$(cat "$REPO_DIR/REVIEW_PROMPT.md")

## This run's candidates
Completed-and-unreviewed issue numbers (this hub repo), oldest completion first: $candidates
Pick the single highest-priority one (check each candidate's priority label; oldest issue number first within a tier) to review this invocation.

## Model escalation for this pass
Escalating from ${base_label} to ${review_model}. Use these exact two values in the announcement comment described above."

        perl -e 'alarm shift; exec @ARGV' "$((TASK_TIMEOUT_MIN * 60))" \
            "$CLAUDE_BIN" -p "$review_prompt" \
            --settings "$BASE/runner-settings.json" \
            --permission-mode acceptEdits \
            --max-turns "$MAX_TURNS_PER_TASK" \
            --output-format json \
            --model "$review_model" \
            > "$RUN_LOG" 2>>"$LOG"
        rc=$?
        tasks=$((tasks + 1))

        if [ "$rc" -eq 142 ]; then
            log "review invocation hit the ${TASK_TIMEOUT_MIN}m wall clock; will retry next run"
            break
        fi
        if [ "$rc" -ne 0 ]; then
            log "review invocation exited rc=$rc (usage limit or error); stopping review loop"
            break
        fi

        reviewed_issue="$(grep -o 'REVIEW_COMPLETE [0-9]*' "$RUN_LOG" 2>/dev/null | head -1 | awk '{print $2}' || true)"
        if [ -n "$reviewed_issue" ]; then
            echo "$reviewed_issue" >> "$reviewed_csv"
            log "review finished for issue #$reviewed_issue"
        elif grep -q "NO_REVIEW_CANDIDATES" "$RUN_LOG" 2>/dev/null; then
            log "review agent found no reviewable candidate; stopping review loop"
            break
        else
            log "review invocation finished without a REVIEW_COMPLETE marker; stopping review loop to avoid spinning"
            break
        fi

        git checkout -q main && git reset -q --hard origin/main && git clean -qfd
        candidates="$(pending)"
    done
fi

log "run complete; task invocations: $tasks"
