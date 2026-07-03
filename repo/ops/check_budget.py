#!/usr/bin/env python3
"""Night Shift budget guard. Decides whether the agent may run right now.

Exit codes:
  0  go
  1  stop (a gate said no -- normal, not an error)
  2  stop (error of any kind -- FAIL CLOSED)
  3  stop (OAuth token rejected; caller may refresh via a claude call and retry once)

Prints a single-line JSON decision to stdout and appends a row to usage-log.csv.
Configuration comes from environment variables (sourced from config.env by the
wrapper); every knob has a safe default. Stdlib only; runs on macOS system python3.
"""

import csv
import datetime as dt
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
KEYCHAIN_SERVICE = "Claude Code-credentials"
SESSION_HOURS = 5


def fnum(name, default):
    try:
        return float(os.environ.get(name, "") or default)
    except ValueError:
        return float(default)


CFG = {
    "work_start": int(fnum("WORK_START_HOUR", 8)),
    "work_end": int(fnum("WORK_END_HOUR", 18)),
    "workdays": {int(d) for d in os.environ.get("WORKDAYS", "0,1,2,3,4").split(",") if d.strip() != ""},
    "pct_per_work_hour": fnum("PCT_PER_WORK_HOUR", 1.0),
    "safety_factor": fnum("SAFETY_FACTOR", 1.25),
    "min_surplus_start": fnum("MIN_SURPLUS_START", 8),
    "min_surplus_continue": fnum("MIN_SURPLUS_CONTINUE", 3),
    "weekly_hard_cap": fnum("WEEKLY_HARD_CAP", 85),
    "five_hour_max_start": fnum("FIVE_HOUR_MAX_START", 90),
    "five_hour_max_continue": fnum("FIVE_HOUR_MAX_CONTINUE", 95),
    "log_dir": os.environ.get("LOG_DIR", os.path.expanduser("~/claude-night-shift/logs")),
    "mode_file": os.path.expanduser(os.environ.get("MODE_FILE", "~/claude-night-shift/mode")),
}


def read_override(now):
    """Owner-set schedule override from the mode file (see ops/mode.sh).

    File format, single line:  normal | day-off [YYYY-MM-DD] | vacation [YYYY-MM-DD]
    The date is the LAST day the override applies (inclusive). day-off without a
    date means today only. Anything missing, expired, or unparseable collapses to
    'normal' -- an override can loosen gates only when explicitly and validly set.

    Effects: day-off and vacation skip the working-hours and session-collision
    gates; vacation additionally zeroes the workday reserve. The weekly hard cap
    and 5-hour caps always apply.

    Returns (override, human_note).
    """
    try:
        with open(CFG["mode_file"]) as f:
            parts = f.readline().strip().lower().split()
    except OSError:
        return "normal", ""
    if not parts or parts[0] not in ("day-off", "vacation"):
        return "normal", ""
    override = parts[0]
    end = None
    if len(parts) > 1:
        try:
            end = dt.date.fromisoformat(parts[1])
        except ValueError:
            return "normal", ""  # a date was given but is garbage -- treat as unset
    elif override == "day-off":
        end = now.date()  # dateless day-off auto-expires at midnight
    if end is not None and now.date() > end:
        return "normal", ""
    note = f"{override} mode" + (f" through {end.isoformat()}" if end else "")
    return override, note


def decide(mode, go, reason, **extra):
    payload = {"go": go, "mode": mode, "reason": reason, **extra}
    print(json.dumps(payload))
    log_row(mode, go, reason, extra)
    return 0 if go else 1


def fail(mode, code, reason):
    print(json.dumps({"go": False, "mode": mode, "reason": reason, "error": True}))
    log_row(mode, False, reason, {})
    return code


def log_row(mode, go, reason, extra):
    try:
        os.makedirs(CFG["log_dir"], exist_ok=True)
        path = os.path.join(CFG["log_dir"], "usage-log.csv")
        new = not os.path.exists(path)
        with open(path, "a", newline="") as f:
            w = csv.writer(f)
            if new:
                w.writerow(["timestamp", "mode", "go", "reason", "five_hour_pct",
                            "weekly_pct", "work_hours_remaining", "reserve", "surplus"])
            w.writerow([
                dt.datetime.now().astimezone().isoformat(timespec="seconds"),
                mode, go, reason,
                extra.get("five_hour_pct", ""), extra.get("weekly_pct", ""),
                extra.get("work_hours_remaining", ""), extra.get("reserve", ""),
                extra.get("surplus", ""),
            ])
    except OSError:
        pass  # logging must never change the decision


def get_token():
    """OAuth access token: macOS Keychain first, credentials file as fallback."""
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=15,
        )
        if out.returncode == 0:
            tok = json.loads(out.stdout).get("claudeAiOauth", {}).get("accessToken")
            if tok:
                return tok
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        pass
    try:
        with open(os.path.expanduser("~/.claude/.credentials.json")) as f:
            return json.load(f).get("claudeAiOauth", {}).get("accessToken")
    except (OSError, json.JSONDecodeError):
        return None


def fetch_usage(token):
    """Returns (usage_dict, None) or (None, 'auth'|'error')."""
    req = urllib.request.Request(USAGE_URL, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-code/2.1.0",
    })
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read().decode()), None
    except urllib.error.HTTPError as e:
        return None, "auth" if e.code in (401, 403) else "error"
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None, "error"


def parse_reset(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone()


def in_work_hours(t):
    return t.weekday() in CFG["workdays"] and CFG["work_start"] <= t.hour < CFG["work_end"]


def next_work_start(now):
    for d in range(8):
        day = now + dt.timedelta(days=d)
        if day.weekday() in CFG["workdays"]:
            ws = day.replace(hour=CFG["work_start"], minute=0, second=0, microsecond=0)
            if ws > now:
                return ws
    return None


def work_hours_until(now, until):
    n, t = 0, now
    while t < until:
        if in_work_hours(t):
            n += 1
        t += dt.timedelta(hours=1)
    return n


def main():
    mode = "start"
    if "--mode" in sys.argv:
        mode = sys.argv[sys.argv.index("--mode") + 1]
    if mode not in ("start", "continue"):
        return fail(mode, 2, f"unknown mode {mode!r}")

    now = dt.datetime.now().astimezone()
    override, override_note = read_override(now)

    # Gates 1 & 2 protect the workday; a day-off/vacation override waives them.
    if override == "normal":
        # Gate 1: never run during working hours.
        if in_work_hours(now):
            return decide(mode, False, "inside working hours")

        # Gate 2: a 5-hour window opened now must not still be open at workday start.
        nws = next_work_start(now)
        if nws is not None and now + dt.timedelta(hours=SESSION_HOURS) > nws:
            return decide(mode, False,
                          f"a session window opened now would overlap the workday starting {nws.isoformat(timespec='minutes')}")

    # Gate 3: dynamic weekly budget, from real server-side usage. Fail closed.
    token = get_token()
    if not token:
        return fail(mode, 2, "no OAuth token found (is the Claude Code CLI logged in?)")
    usage, err = fetch_usage(token)
    if err == "auth":
        return fail(mode, 3, "usage endpoint rejected token (expired?)")
    if err or not isinstance(usage, dict):
        return fail(mode, 2, "usage endpoint unreachable or unparseable")

    five = usage.get("five_hour") or {}
    five_pct = float(five.get("utilization", 0))

    # Weekly: take the most-constrained of whatever weekly buckets the API reports.
    weekly_pct, weekly_reset = -1.0, None
    for key in ("seven_day", "seven_day_sonnet", "seven_day_opus", "seven_day_oauth_apps"):
        b = usage.get(key)
        if isinstance(b, dict) and b.get("utilization") is not None:
            u = float(b["utilization"])
            if u > weekly_pct:
                weekly_pct = u
                weekly_reset = b.get("resets_at")
    if weekly_pct < 0 or not weekly_reset:
        return fail(mode, 2, "usage response missing weekly utilization/resets_at")
    try:
        reset_at = parse_reset(weekly_reset)
    except ValueError:
        return fail(mode, 2, f"unparseable resets_at {weekly_reset!r}")

    whr = work_hours_until(now, reset_at)
    reserve = whr * CFG["pct_per_work_hour"] * CFG["safety_factor"]
    if override == "vacation":
        reserve = 0.0  # no workdays coming: nothing to reserve for
    surplus = (100.0 - weekly_pct) - reserve
    metrics = {"five_hour_pct": five_pct, "weekly_pct": weekly_pct,
               "weekly_resets_at": reset_at.isoformat(timespec="minutes"),
               "work_hours_remaining": whr,
               "reserve": round(reserve, 1), "surplus": round(surplus, 1)}
    if override != "normal":
        metrics["override"] = override_note

    if weekly_pct >= CFG["weekly_hard_cap"]:
        return decide(mode, False, f"weekly utilization {weekly_pct}% >= hard cap", **metrics)

    five_max = CFG["five_hour_max_start"] if mode == "start" else CFG["five_hour_max_continue"]
    if five_pct >= five_max:
        return decide(mode, False, f"5-hour window at {five_pct}% >= {five_max}%", **metrics)

    need = CFG["min_surplus_start"] if mode == "start" else CFG["min_surplus_continue"]
    if surplus < need:
        return decide(mode, False,
                      f"surplus {surplus:.1f} < {need} (reserving {reserve:.1f} for {whr} work hours before weekly reset)",
                      **metrics)

    return decide(mode, True, "all gates passed", **metrics)


if __name__ == "__main__":
    sys.exit(main())
