#!/bin/bash
# Night Shift schedule/model override toggle. Writes the mode file that
# check_budget.py reads on every gate check, and can flip the MODEL knob in
# config.env without hand-editing it. Installed to ~/claude-night-shift/ (and
# symlinked as `nightshift` if ~/.local/bin exists).
#
#   nightshift status                  show the current mode + live gate decision
#   nightshift normal                  default: full workday protection
#   nightshift day-off [YYYY-MM-DD]    skip workday gates; no date = today only
#   nightshift vacation [YYYY-MM-DD]   also drop the weekly reserve; no date = until changed
#   nightshift model [<id>|default]    show/set/clear the MODEL override in config.env
#   nightshift logs [-f] [N]           show the last N lines of night-shift.log (default 50)
#
# Hard caps (weekly 85%, 5-hour window) always stay on -- vacation mode can never
# burn the account to 100%.
set -euo pipefail

BASE="$(cd "$(dirname "$(readlink "$0" 2>/dev/null || echo "$0")")" && pwd)"
[ -f "$BASE/config.env" ] && source "$BASE/config.env"
MODE_FILE="${MODE_FILE:-$HOME/claude-night-shift/mode}"
LOG_DIR="${LOG_DIR:-$HOME/claude-night-shift/logs}"

# PATH lookup rather than a hardcoded /usr/bin/python3: that path doesn't
# exist on every Linux distro (and isn't guaranteed on macOS either once
# Command Line Tools moves), whereas `python3` on PATH is the one thing every
# supported platform actually guarantees.
PYTHON3="$(command -v python3 || true)"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

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
        echo "guard decision right now:"
        if [ -n "$PYTHON3" ]; then
            MODE_FILE="$MODE_FILE" "$PYTHON3" "$BASE/check_budget.py" --mode start || true
        else
            echo "  (skipped: python3 not found on PATH)"
        fi
        ;;
    normal)
        rm -f "$MODE_FILE"
        echo "mode: normal (workday gates + weekly reserve active)"
        ;;
    day-off|vacation)
        line="$cmd"
        if [ -n "${2:-}" ]; then
            valid_date "$2" || { echo "ERROR: '$2' is not a valid YYYY-MM-DD date"; exit 1; }
            line="$cmd $2"
        fi
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
