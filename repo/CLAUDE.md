# Tasks repo — agent reference

This repo is the task queue for the Night Shift agent. Tasks are GitHub Issues; work products are `task/*` branches and PRs. The per-run instructions are in RUNNER_PROMPT.md; this file is the reference for conventions and API calls.

## Labels

| Label | Meaning | Set by |
|---|---|---|
| `status:ready` | Task is defined and available to pick up | Owner |
| `status:in-progress` | Agent is working (or a run died mid-work) | Agent |
| `status:needs-human` | Waiting on the owner: questions, handoff, or review of a blocker | Agent |
| `status:in-review` | PR open, awaiting owner review | Agent |
| `priority:high` / `priority:medium` / `priority:low` | Selection order | Owner |

An issue always carries exactly one `status:*` label. Closing the issue = done (owner does this, usually by merging the PR).

## Telling agent comments from owner comments

Both may come from the same GitHub account. Every agent comment begins with:

```
🤖 **Night Shift** — 2026-07-02T03:15:00Z
```

A comment **without** that header is from the owner. "Owner has replied" = the newest comment on the issue lacks the header.

## GitHub REST via curl (the `gh` CLI is not used — see ops docs)

All calls: `-H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json"` against `https://api.github.com`. `$GITHUB_REPO` is `owner/repo`.

```bash
# List open issues with a label (sorted oldest first):
curl -sS -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GITHUB_REPO/issues?state=open&labels=status:ready&sort=created&direction=asc&per_page=50"
# NOTE: this endpoint also returns PRs; skip entries that have a "pull_request" key.

# Read an issue's comments (newest last):
curl -sS -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GITHUB_REPO/issues/$N/comments?per_page=100"

# Post a comment:
curl -sS -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GITHUB_REPO/issues/$N/comments" \
  -d '{"body":"🤖 **Night Shift** — <timestamp>\n\n<text>"}'

# Replace labels (send the complete new set, e.g. keep the priority label):
curl -sS -X PUT -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GITHUB_REPO/issues/$N/labels" \
  -d '{"labels":["status:in-progress","priority:high"]}'

# Open a PR:
curl -sS -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GITHUB_REPO/pulls" \
  -d '{"title":"Task #N: <title>","head":"task/N-slug","base":"main","body":"Closes #N\n\n<summary + verification steps>"}'
```

## Branches and commits

- One branch per task: `task/<issue-number>-<short-slug>` (e.g. `task/12-csv-importer`).
- Push early and often; pushed WIP is the crash-recovery mechanism.
- Never commit to `main`, never force-push, never rewrite pushed history.
- Task deliverables live in a folder named after the task when they're standalone (e.g. `projects/12-csv-importer/`), or follow the issue's stated layout.

## Question etiquette (end state B)

One consolidated comment. Numbered questions. Each question: (a) the decision needed, (b) options if enumerable, (c) your recommended default. The goal is that the owner can answer the whole batch with one short reply, including just: "defaults."

## Handoff etiquette (end state C)

`HANDOFF.md` at the branch root, written for a reader with zero context: what's blocked, exact enable/setup steps for the owner (numbered, copy-pasteable), where placeholders live, and what the agent will do after unblock. The issue comment is a checklist version of the same.
