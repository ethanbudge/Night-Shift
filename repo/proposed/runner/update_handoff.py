#!/usr/bin/env python3
"""Keep a hub repo's README.md hand-off section in sync with open Night Shift tasks.

Maintains one table row per issue that currently needs owner attention,
inside a marked block:

    <!-- NIGHT-SHIFT-HANDOFF:START -->
    ## Night Shift Hand-off
    <!-- DATA: {...} -->
    | # | Task | Needs from you |
    ...
    <!-- NIGHT-SHIFT-HANDOFF:END -->

The JSON comment right after the heading is the source of truth; the table
is regenerated from it on every call, so hand edits to the table itself
don't survive the next run (the heading says as much).

Usage:
    update_handoff.py README.md upsert --issue 10 --repo owner/name \
        --title "Shift Hand-off" --kind review --action "Review PR #13"
    update_handoff.py README.md remove --issue 10
    update_handoff.py README.md sync --keep 3,5,10,12
"""
import argparse
import json
import re
import sys

MARK_START = "<!-- NIGHT-SHIFT-HANDOFF:START -->"
MARK_END = "<!-- NIGHT-SHIFT-HANDOFF:END -->"
DATA_RE = re.compile(r"<!-- DATA: (.*?) -->", re.DOTALL)

KIND_ORDER = {"needs-human": 0, "handoff": 1, "infeasible": 2, "review": 3}
KIND_LABELS = {
    "needs-human": "Needs your input",
    "handoff": "Needs setup/credentials",
    "infeasible": "Needs a decision",
    "review": "Ready for review",
}


def load_data(content):
    start = content.find(MARK_START)
    end = content.find(MARK_END)
    if start == -1 or end == -1:
        return {}
    m = DATA_RE.search(content, start, end)
    if not m:
        return {}
    try:
        return json.loads(m.group(1))
    except json.JSONDecodeError:
        return {}


def render_block(data):
    lines = [
        MARK_START,
        "## Night Shift Hand-off",
        "",
        "_Auto-maintained by `ops/update_handoff.py` — do not hand-edit between the"
        " markers; this table is regenerated from the JSON comment below on every"
        " run._",
        "",
        "<!-- DATA: %s -->" % json.dumps(data, sort_keys=True),
        "",
    ]
    if not data:
        lines.append("_Nothing pending — you're caught up._")
    else:
        lines.append("| # | Task | Needs from you |")
        lines.append("|---|------|-----------------|")
        entries = sorted(
            data.items(),
            key=lambda kv: (KIND_ORDER.get(kv[1]["kind"], 99), int(kv[0])),
        )
        for issue, e in entries:
            label = KIND_LABELS.get(e["kind"], e["kind"])
            lines.append(
                "| [#%s](%s) | %s | %s (%s) |"
                % (issue, e["url"], e["title"], e["action"], label)
            )
    lines.append("")
    lines.append(MARK_END)
    return "\n".join(lines)


def write_back(content, data):
    block = render_block(data)
    if MARK_START in content and MARK_END in content:
        pre = content[: content.find(MARK_START)]
        post = content[content.find(MARK_END) + len(MARK_END) :]
        return pre + block + post
    if content and not content.endswith("\n\n"):
        content = content.rstrip("\n") + "\n\n"
    return content + block + "\n"


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("readme")
    sub = p.add_subparsers(dest="cmd", required=True)

    up = sub.add_parser("upsert")
    up.add_argument("--issue", required=True)
    up.add_argument("--repo", required=True)
    up.add_argument("--title", required=True)
    up.add_argument("--kind", required=True, choices=sorted(KIND_ORDER))
    up.add_argument("--action", required=True)
    up.add_argument("--url")

    rm = sub.add_parser("remove")
    rm.add_argument("--issue", required=True)

    sy = sub.add_parser("sync")
    sy.add_argument("--keep", required=True, help="comma-separated issue numbers still open")

    args = p.parse_args()

    try:
        with open(args.readme, "r") as f:
            content = f.read()
    except FileNotFoundError:
        content = ""

    data = load_data(content)

    if args.cmd == "upsert":
        url = args.url or "https://github.com/%s/issues/%s" % (args.repo, args.issue)
        data[args.issue] = {
            "repo": args.repo,
            "title": args.title,
            "kind": args.kind,
            "action": args.action,
            "url": url,
        }
    elif args.cmd == "remove":
        data.pop(args.issue, None)
    elif args.cmd == "sync":
        keep = {n.strip() for n in args.keep.split(",") if n.strip()}
        data = {k: v for k, v in data.items() if k in keep}

    new_content = write_back(content, data)
    with open(args.readme, "w") as f:
        f.write(new_content)

    sys.exit(0)


if __name__ == "__main__":
    main()
