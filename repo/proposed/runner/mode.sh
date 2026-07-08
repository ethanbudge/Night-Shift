#!/bin/bash
# Night Shift schedule/model override toggle. Writes the mode file that
# check_budget.py reads on every gate check, and can flip the MODEL knob in
# config.env without hand-editing it. Installed to ~/claude-night-shift/ (and
# symlinked as `nightshift` if ~/.local/bin exists).
#
#   nightshift status                  show the current mode + live gate decision
#   nightshift begin-run               start one run now, as if the hourly timer just fired
#   nightshift normal                  default: full workday protection
#   nightshift day-off [YYYY-MM-DD]    skip workday gates; no date = today only
#   nightshift vacation [YYYY-MM-DD]   also drop the weekly reserve; no date = until changed
#   nightshift model [<id>|default]    show/set/clear the MODEL override in config.env
#   nightshift review [on|off|status]  toggle the end-of-queue review pass (see DESIGN.md)
#   nightshift logs [-f] [N]           show the last N lines of night-shift.log (default 50)
#
# Hard caps (weekly 85%, 5-hour window) always stay on -- vacation mode can never
# burn the account to 100%.
set -euo pipefail

BASE="$(cd "$(dirname "$(readlink "$0" 2>/dev/null || echo "$0")")" && pwd)"
[ -f "$BASE/config.env" ] && source "$BASE/config.env"
MODE_FILE="${MODE_FILE:-$HOME/claude-night-shift/mode}"
LOG_DIR="${LOG_DIR:-$HOME/claude-night-shift/logs}"

# Export the runtime config the same way night-shift.sh does before any gate
# check, so the decision we show (status) or pre-flight (begin-run) matches what
# a real run would actually decide. GITHUB_REPO is the one that bites: without
# it check_budget can't fetch CONTROL.md, so status/pre-check silently ignore a
# remote override and disagree with the run (e.g. report a local day-off as
# "go" when CONTROL.md's more-restrictive normal would veto it).
export WORK_START_HOUR WORK_END_HOUR WORKDAYS PCT_PER_WORK_HOUR SAFETY_FACTOR \
       MIN_SURPLUS_START MIN_SURPLUS_CONTINUE WEEKLY_HARD_CAP \
       FIVE_HOUR_MAX_START FIVE_HOUR_MAX_CONTINUE LOG_DIR MODE_FILE MODEL \
       SECRETS_DIR GITHUB_REPO

# PATH lookup rather than a hardcoded /usr/bin/python3: that path doesn't
# exist on every Linux distro (and isn't guaranteed on macOS either once
# Command Line Tools moves), whereas `python3` on PATH is the one thing every
# supported platform actually guarantees.
PYTHON3="$(command -v python3 || true)"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

valid_date() {
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    # Round-trip through date(1): BSD date silently rolls 2026-02-31 over to
    # March 3, so parse-then-reformat and require an exact match.
    local rt
    rt="$(date -j -f "%Y-%m-%d" "$1" "+%Y-%m-%d" 2>/dev/null)" \
        || rt="$(date -d "$1" "+%Y-%m-%d" 2>/dev/null)" || return 1
    [ "$rt" = "$1" ]
}

cmd="${1:-status}"
case "$cmd" in
    status)
        if [ -f "$MODE_FILE" ]; then
            echo "mode file: $(cat "$MODE_FILE")   ($MODE_FILE)"
        else
            echo "mode file: (none) -> normal   ($MODE_FILE)"
        fi
        echo "model override: ${MODEL:-(none -- account default)}"
        echo "review mode: ${REVIEW_MODE:-off}"
        echo "guard decision right now:"
        if [ -n "$PYTHON3" ]; then
            # rc=$? on a separate line would abort under `set -e` before it runs;
            # `|| rc=$?` handles the non-zero exit so the script survives it.
            rc=0
            decision="$(MODE_FILE="$MODE_FILE" "$PYTHON3" "$BASE/check_budget.py" --mode start)" || rc=$?
            # Mirror night-shift.sh's one-shot refresh: the CLI's OAuth token
            # expires every few hours, so a status check between runs otherwise
            # reports a scary "token rejected" error for what the real run would
            # transparently refresh and retry. Only bother if we have the CLI.
            if [ "$rc" -eq 3 ] && [ -n "${CLAUDE_BIN:-}" ] && [ -x "$CLAUDE_BIN" ]; then
                echo "  (OAuth token stale; refreshing with a minimal claude call...)"
                "$CLAUDE_BIN" -p "Reply with exactly: ok" \
                    --model claude-haiku-4-5-20251001 >/dev/null 2>&1 || true
                decision="$(MODE_FILE="$MODE_FILE" "$PYTHON3" "$BASE/check_budget.py" --mode start)" || true
            fi
            echo "$decision"
        else
            echo "  (skipped: python3 not found on PATH)"
        fi
        ;;
    begin-run)
        # Fire one run right now, exactly as the hourly launchd/systemd timer
        # would -- without waiting for the top of the hour. Every gate still
        # applies (working hours, day-off/vacation, budget, the hard caps): this
        # changes only WHEN a run may start, never WHETHER one is allowed. The
        # scheduled timer is left alone, so normal hourly runs resume after this.
        RUNNER="$BASE/night-shift.sh"
        [ -x "$RUNNER" ] || { echo "ERROR: $RUNNER not found or not executable (run ops/install.sh)"; exit 1; }
        [ -n "$PYTHON3" ] || { echo "ERROR: python3 not found on PATH"; exit 1; }

        # 1) Refuse if a run is already in flight. night-shift.sh holds this same
        #    lock the whole time it works, so reusing it means begin-run and the
        #    hourly timer can never overlap into a double run.
        LOCKDIR="$BASE/.lock"
        if [ -d "$LOCKDIR" ]; then
            running_pid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
            if [ -n "$running_pid" ] && kill -0 "$running_pid" 2>/dev/null; then
                echo "nightshift is already running (pid $running_pid) -- begin-run refused."
                echo "watch it with: nightshift logs -f"
                exit 1
            fi
        fi

        # 2) Refuse if the gates say no this instant -- the same decision the run
        #    itself makes a beat later, surfaced now as a clear message instead
        #    of a silent no-op. Retry once through a token refresh, like the
        #    runner does, so an expired CLI token can't masquerade as a no-go.
        rc=0
        decision="$(MODE_FILE="$MODE_FILE" "$PYTHON3" "$BASE/check_budget.py" --mode start)" || rc=$?
        if [ "$rc" -eq 3 ] && [ -n "${CLAUDE_BIN:-}" ] && [ -x "$CLAUDE_BIN" ]; then
            echo "(OAuth token stale; refreshing with a minimal claude call...)"
            "$CLAUDE_BIN" -p "Reply with exactly: ok" \
                --model claude-haiku-4-5-20251001 >/dev/null 2>&1 || true
            rc=0
            decision="$(MODE_FILE="$MODE_FILE" "$PYTHON3" "$BASE/check_budget.py" --mode start)" || rc=$?
        fi
        if [ "$rc" -ne 0 ]; then
            echo "begin-run refused -- the gates say no right now:"
            echo "  ${decision:-(no output; check_budget.py exited $rc)}"
            echo "tip: 'nightshift day-off' lifts the working-hours gate for today -- but a"
            echo "     more-restrictive mode in CONTROL.md (e.g. normal) overrides it, so set it there too."
            exit 1
        fi

        # 3) Clear to go: launch the runner detached, the same way the timer
        #    invokes it, so it keeps working even if this shell closes. It
        #    re-checks the gate and takes the lock itself -- the checks above are
        #    just fast, friendly pre-flight.
        mkdir -p "$LOG_DIR"
        nohup "$RUNNER" >>"$LOG_DIR/launchd.log" 2>&1 &
        echo "nightshift begin-run: started an immediate run (pid $!)."
        echo "the hourly schedule is unchanged; normal runs continue after this one."
        echo "watch it with: nightshift logs -f"
        ;;
    normal)
        rm -f "$MODE_FILE"
        echo "mode: normal (workday gates + weekly reserve active)"
        ;;
    day-off|vacation)
        if [ -n "${2:-}" ]; then
            valid_date "$2" || { echo "ERROR: '$2' is not a valid YYYY-MM-DD date"; exit 1; }
            end="$2"
        elif [ "$cmd" = "day-off" ]; then
            # No date given: expire at the end of today. Write today's actual
            # date into the file now -- check_budget.py just compares against
            # it, so the override correctly stops matching after midnight
            # instead of silently re-deriving "today" on every future read.
            end="$(date "+%Y-%m-%d")"
        else
            end=""
        fi
        line="$cmd${end:+ $end}"
        mkdir -p "$(dirname "$MODE_FILE")"
        printf '%s\n' "$line" > "$MODE_FILE"
        if [ "$cmd" = "day-off" ] && [ -z "${2:-}" ]; then
            echo "mode: day-off (today only -- auto-reverts at midnight)"
        elif [ -n "${2:-}" ]; then
            echo "mode: $cmd through $2 (inclusive; auto-reverts after)"
        else
            echo "mode: vacation (until you run 'nightshift normal')"
        fi
        ;;
    model)
        [ -f "$BASE/config.env" ] || { echo "ERROR: $BASE/config.env not found"; exit 1; }
        case "${2:-}" in
            "")
                echo "current MODEL: ${MODEL:-(none -- account default)}"
                echo "usage: nightshift model <model-id>   or   nightshift model default"
                ;;
            default)
                sed -i.bak 's/^MODEL=.*/MODEL=""/' "$BASE/config.env" && rm -f "$BASE/config.env.bak"
                echo "MODEL cleared -- runs will use your account's default model"
                ;;
            *)
                sed -i.bak "s/^MODEL=.*/MODEL=\"$2\"/" "$BASE/config.env" && rm -f "$BASE/config.env.bak"
                echo "MODEL set to '$2' -- takes effect on the next run"
                echo "note: this is a machine-local override; CONTROL.md's 'model:' line (if your"
                echo "hub repo has one) takes priority for that run when it's set to a non-empty value."
                ;;
        esac
        ;;
    review)
        [ -f "$BASE/config.env" ] || { echo "ERROR: $BASE/config.env not found"; exit 1; }
        case "${2:-status}" in
            status)
                echo "review mode: ${REVIEW_MODE:-off}"
                ;;
            on)
                sed -i.bak 's/^REVIEW_MODE=.*/REVIEW_MODE="on"/' "$BASE/config.env" && rm -f "$BASE/config.env.bak"
                echo "review mode: on"
                echo "once the normal task queue is empty for the run, a completed-and-unreviewed"
                echo "issue (oldest first, highest priority) gets one pass from a stronger model"
                echo "(sonnet -> opus -> fable) before the run ends -- see DESIGN.md's Review System"
                echo "section for the escalation ladder and what 'reviewed' means."
                ;;
            off)
                sed -i.bak 's/^REVIEW_MODE=.*/REVIEW_MODE="off"/' "$BASE/config.env" && rm -f "$BASE/config.env.bak"
                echo "review mode: off"
                ;;
            *)
                echo "usage: nightshift review [on|off|status]"
                exit 1
                ;;
        esac
        ;;
    logs)
        LOGFILE="$LOG_DIR/night-shift.log"
        [ -f "$LOGFILE" ] || { echo "no log yet at $LOGFILE"; exit 0; }
        follow=""
        n=50
        for arg in "${@:2}"; do
            case "$arg" in
                -f) follow="-f" ;;
                *[!0-9]*) ;;  # ignore anything else non-numeric
                *) n="$arg" ;;
            esac
        done
        if [ -n "$follow" ]; then
            tail -n "$n" -f "$LOGFILE"
        else
            tail -n "$n" "$LOGFILE"
        fi
        ;;
    *)
        usage
        ;;
esac
