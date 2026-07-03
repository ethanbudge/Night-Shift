#!/bin/bash
# Night Shift schedule override toggle. Writes the mode file that check_budget.py
# reads on every gate check. Installed to ~/claude-night-shift/ (and symlinked as
# `nightshift` if ~/.local/bin exists).
#
#   nightshift status                  show the current mode + live gate decision
#   nightshift normal                  default: full workday protection
#   nightshift day-off [YYYY-MM-DD]    skip workday gates; no date = today only
#   nightshift vacation [YYYY-MM-DD]   also drop the weekly reserve; no date = until changed
#
# Hard caps (weekly 85%, 5-hour window) always stay on -- vacation mode can never
# burn the account to 100%.
set -euo pipefail

BASE="$(cd "$(dirname "$(readlink "$0" 2>/dev/null || echo "$0")")" && pwd)"
[ -f "$BASE/config.env" ] && source "$BASE/config.env"
MODE_FILE="${MODE_FILE:-$HOME/claude-night-shift/mode}"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

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
        echo "guard decision right now:"
        MODE_FILE="$MODE_FILE" /usr/bin/python3 "$BASE/check_budget.py" --mode start || true
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
    *)
        usage
        ;;
esac
