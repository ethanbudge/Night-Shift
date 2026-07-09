#!/usr/bin/env python3
"""Night Shift budget guard. Decides whether the agent may run right now.

Exit codes:
  0  go
  1  stop (a gate said no -- normal, not an error)
  2  stop (error of any kind -- FAIL CLOSED)
  3  stop (OAuth token rejected; caller may refresh via a claude call and retry once)

Prints a single-line JSON decision to stdout and appends a row to usage-log.csv.
Configuration comes from environment variables (sourced from config.env by the
wrapper); every knob has a safe default. Stdlib only; runs on macOS, Linux, and
Windows system python3.
"""

import csv
import datetime as dt
import json
import os
import platform
import re
import subprocess
import sys
import urllib.error
import urllib.request

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
KEYCHAIN_SERVICE = "Claude Code-credentials"
SESSION_HOURS = 5
RESTRICTIVENESS = {"vacation": 0, "day-off": 1, "normal": 2}
NEEDS_HUMAN_STALE_HOURS = 3
AGENT_COMMENT_PREFIXES = ("\U0001f916 **Night Shift**", "\U0001f916 Night Shift")


def fnum(name, default):
    try:
        return float(os.environ.get(name, "") or default)
    except ValueError:
        return float(default)


def parse_model_allowlist(raw):
    """`tag=model-id,tag=model-id` -> {tag: model-id}. Malformed entries are
    dropped rather than raising -- a typo in config.env should degrade to
    'that tag doesn't resolve, fall back to baseline', never crash the guard."""
    out = {}
    for part in (raw or "").split(","):
        part = part.strip()
        if not part or "=" not in part:
            continue
        tag, _, model_id = part.partition("=")
        tag, model_id = tag.strip().lower(), model_id.strip()
        if tag and model_id:
            out[tag] = model_id
    return out


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
    "github_repo": os.environ.get("GITHUB_REPO", ""),
    "secrets_dir": os.path.expanduser(os.environ.get("SECRETS_DIR", "~/claude-night-shift/secrets")),
    # Baseline is whatever config.env's MODEL knob already says (blank = account
    # default). Tags resolve through this allowlist; an issue's model:<tag>
    # label that isn't a key here is treated exactly like a missing tag.
    "model_allowlist": parse_model_allowlist(os.environ.get("MODEL_ALLOWLIST", "")),
}


def read_override(now):
    """Owner-set schedule override from the mode file (see ops/mode.sh).

    File format, single line:  normal | day-off [YYYY-MM-DD] | vacation [YYYY-MM-DD]
    The date is the LAST day the override applies (inclusive). mode.sh always
    writes an explicit date for dateless `day-off` (today's date, at set time) so
    that expiry is fixed to when the mode was set, not re-derived on every read.
    Anything missing, expired, or unparseable collapses to 'normal' -- an override
    can loosen gates only when explicitly and validly set.

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
    if len(parts) > 1:
        try:
            end = dt.date.fromisoformat(parts[1])
        except ValueError:
            return "normal", ""  # a date was given but is garbage -- treat as unset
    else:
        # No date in the file at all: a pre-fix mode file, or hand-written.
        # We don't know when it was set, so we can't tell if it's expired --
        # collapse to unset rather than let it apply forever.
        return "normal", ""
    if now.date() > end:
        return "normal", ""
    note = f"{override} mode" + (f" through {end.isoformat()}" if end else "")
    return override, note


def get_github_token():
    """The PAT from disk -- same file the wrapper already reads. Returns None
    on any failure; callers treat that as 'GitHub features unavailable'."""
    try:
        with open(os.path.join(CFG["secrets_dir"], "github-token")) as f:
            token = f.read().strip()
    except OSError:
        return None
    return token or None


def _api_get(url, token, accept="application/vnd.github+json", timeout=10):
    """GET against the GitHub REST API. Returns parsed JSON, or None on any
    error (network, auth, non-2xx, bad JSON) -- every caller here treats a
    None the same way: 'skip this, don't let it change a safety-relevant
    decision'."""
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": accept,
        "User-Agent": "night-shift-guard",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read().decode("utf-8", errors="ignore")
    except (urllib.error.URLError, TimeoutError, OSError):
        return None
    if accept == "application/vnd.github.raw":
        return body
    try:
        return json.loads(body)
    except ValueError:
        return None


def read_remote_control():
    """Owner-set override from CONTROL.md in the hub repo (see CONTROL.md).

    This is a convenience layer on top of the local mode file, fetched over
    the network with the same PAT the wrapper already has on disk -- and
    unlike the Anthropic usage check below, it is NOT safety-critical: any
    error (missing config, network hiccup, bad token, unparseable content)
    returns (None, None) so the caller falls back to the local mode file
    alone. It never fails open to "run anyway" -- only to "ignore me."

    Returns (remote_mode_or_None, remote_model_or_None).
    """
    repo = CFG["github_repo"]
    if not repo:
        return None, None
    token = get_github_token()
    if not token:
        return None, None

    url = f"https://api.github.com/repos/{repo}/contents/CONTROL.md"
    text = _api_get(url, token, accept="application/vnd.github.raw")
    if text is None:
        return None, None

    # [ \t] rather than \s so the match can't cross a newline (\s includes
    # \n, which let a blank `model:` value greedily swallow the next line --
    # e.g. a following markdown code-fence line -- as its "value").
    mode_m = re.search(r"(?im)^[ \t]*mode[ \t]*:[ \t]*(\S+)", text)
    model_m = re.search(r"(?im)^[ \t]*model[ \t]*:[ \t]*(\S*)[ \t]*$", text)
    remote_mode = mode_m.group(1).strip().lower() if mode_m else None
    if remote_mode not in RESTRICTIVENESS:
        remote_mode = None
    remote_model = model_m.group(1).strip() if model_m and model_m.group(1).strip() else None
    return remote_mode, remote_model


def combine_overrides(local, remote):
    """The more restrictive (safer) of the local and remote override wins."""
    if remote is None:
        return local, False
    if RESTRICTIVENESS[remote] > RESTRICTIVENESS[local]:
        return remote, True
    return local, False


# --- Per-task model selection ------------------------------------------------
#
# Mirrors RUNNER_PROMPT.md's "Select one task" algorithm exactly, so that the
# model resolved here matches the issue the agent itself will pick a few
# seconds later. If RUNNER_PROMPT.md's selection rules ever change, this
# function must change with it -- see proposed/runner-prompt-patch.md.
#
# This is best-effort, not authoritative: the agent always re-derives its own
# selection from live state when it actually runs, and that's what governs
# which issue gets worked. A rare race (state changing in the few seconds
# between this call and the agent's own selection) could pick a different
# issue than the one whose model tag was resolved -- in that case the task
# just runs under the baseline-precedence model instead of its own tag, which
# is a safe, harmless fallback, not a wrong-answer failure.

def label_names(issue):
    return [l["name"] for l in issue.get("labels", [])]


def priority_rank(labels):
    """high=2, medium=1, low=0, none=-1 -- higher sorts first."""
    order = {"priority:high": 2, "priority:medium": 1, "priority:low": 0}
    for name in labels:
        if name in order:
            return order[name]
    return -1


def model_tag(labels):
    for name in labels:
        if name.startswith("model:"):
            tag = name.split(":", 1)[1].strip().lower()
            if tag:
                return tag
    return None


def is_agent_comment(body):
    return (body or "").startswith(AGENT_COMMENT_PREFIXES)


def list_issues(token, repo, label, state="open"):
    url = (f"https://api.github.com/repos/{repo}/issues"
           f"?state={state}&labels={label}&sort=created&direction=asc&per_page=50")
    data = _api_get(url, token)
    if not isinstance(data, list):
        return []
    return [i for i in data if "pull_request" not in i]


def list_comments(token, repo, number):
    url = f"https://api.github.com/repos/{repo}/issues/{number}/comments?per_page=100"
    data = _api_get(url, token)
    return data if isinstance(data, list) else []


DEPENDS_RE = re.compile(r"(?i)depends on #(\d+)")


def depends_on_open(token, repo, issue):
    """True if any `Depends on #N` in the body or thread names a still-open
    issue N. On any fetch error, treat as unblocked -- a guard fetch failure
    here must never make an otherwise-ready task look permanently stuck."""
    text_blobs = [issue.get("body") or ""]
    for c in list_comments(token, repo, issue["number"]):
        text_blobs.append(c.get("body") or "")
    dep_numbers = set()
    for blob in text_blobs:
        dep_numbers.update(int(n) for n in DEPENDS_RE.findall(blob))
    for n in dep_numbers:
        dep = _api_get(f"https://api.github.com/repos/{repo}/issues/{n}", token)
        if isinstance(dep, dict) and dep.get("state") == "open":
            return True
    return False


def parse_iso(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def select_next_task(token, repo):
    """Returns {"number": N, "labels": [...]} for the issue the agent would
    pick next, or None if nothing is actionable. Never raises -- any fetch
    error along the way just makes that tier come up empty."""
    if not token or not repo:
        return None

    # Tier 1: needs-human issues the owner has replied to, highest priority first.
    candidates = list_issues(token, repo, "status:needs-human")
    candidates.sort(key=lambda i: (-priority_rank(label_names(i)), i.get("created_at", "")))
    for issue in candidates:
        comments = list_comments(token, repo, issue["number"])
        if not comments:
            continue
        if is_agent_comment(comments[-1].get("body")):
            continue
        if depends_on_open(token, repo, issue):
            continue
        return {"number": issue["number"], "labels": label_names(issue)}

    # Tier 2: in-progress issues abandoned for 3+ hours.
    now = dt.datetime.now(dt.timezone.utc)
    candidates = list_issues(token, repo, "status:in-progress")
    candidates.sort(key=lambda i: i.get("updated_at", ""))
    for issue in candidates:
        try:
            updated = parse_iso(issue["updated_at"])
        except (KeyError, ValueError):
            continue
        if (now - updated) < dt.timedelta(hours=NEEDS_HUMAN_STALE_HOURS):
            continue
        if depends_on_open(token, repo, issue):
            continue
        return {"number": issue["number"], "labels": label_names(issue)}

    # Tier 3: ready issues, highest priority first, oldest within a tier.
    candidates = list_issues(token, repo, "status:ready")
    candidates.sort(key=lambda i: (-priority_rank(label_names(i)), i.get("created_at", "")))
    for issue in candidates:
        if depends_on_open(token, repo, issue):
            continue
        return {"number": issue["number"], "labels": label_names(issue)}

    return None


def resolve_task_model(token, repo):
    """Returns (issue_number_or_None, model_tag_or_None, model_id_or_None).
    model_id is None whenever there's no tag, or the tag isn't a recognized
    key in MODEL_ALLOWLIST -- both cases mean 'the caller should fall back to
    baseline', per the task's definition of done ("revert to the baseline
    model rather than failing if a model is incompatible")."""
    task = select_next_task(token, repo)
    if task is None:
        return None, None, None
    tag = model_tag(task["labels"])
    model_id = CFG["model_allowlist"].get(tag) if tag else None
    return task["number"], tag, model_id


# --- End per-task model selection --------------------------------------------


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
    """OAuth access token: macOS Keychain first (Darwin only), credentials
    file as fallback everywhere (this is also the only path on Linux/Windows,
    which have no Keychain equivalent)."""
    if platform.system() == "Darwin":
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
    local_override, local_note = read_override(now)
    remote_mode, remote_model = read_remote_control()
    override, remote_won = combine_overrides(local_override, remote_mode)
    if remote_won:
        override_note = f"{override} mode (from CONTROL.md, overriding local '{local_override}')"
    else:
        override_note = local_note

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
    if remote_model:
        metrics["model_override"] = remote_model

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

    # Model resolution only matters for the invocation about to happen, i.e.
    # only in `continue` mode (the loop iteration that's actually about to
    # invoke claude for one task). `start`'s decision is just the initial
    # whole-run gate and its model fields would be discarded anyway.
    if mode == "continue":
        github_token = get_github_token()
        issue_number, tag, model_id = resolve_task_model(github_token, CFG["github_repo"])
        if issue_number is not None:
            metrics["task_issue"] = issue_number
        if tag is not None:
            metrics["task_model_tag"] = tag
        if model_id is not None:
            metrics["task_model_id"] = model_id

    return decide(mode, True, "all gates passed", **metrics)


if __name__ == "__main__":
    sys.exit(main())
