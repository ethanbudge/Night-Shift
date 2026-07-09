# Tasks repo — agent reference

This repo is the task queue for the Night Shift agent. Tasks are GitHub Issues **in this repo**; work products are `task/*` branches and PRs — in this repo for standalone tasks, or in a separate project repo when the issue names one. The per-run instructions are in RUNNER_PROMPT.md; this file is the reference for conventions and API calls.

## Target repositories and workspaces

Each task issue may have a `## Target repository` section naming an `owner/repo` slug. That is where the work lands. If the section is blank, missing, or says `claude-tasks`, the task is standalone and lands in this repo (under `projects/<issue#>-<slug>/`).

Project repos are cloned inside this clone, under the gitignored `workspaces/` folder — one subfolder per repo name. The clone persists between runs. At the start of a task targeting `owner/name`:

```bash
mkdir -p workspaces
if [ ! -d "workspaces/name/.git" ]; then
  git clone "https://x-access-token:${GH_TOKEN}@github.com/owner/name.git" "workspaces/name"
fi
cd workspaces/name
git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/owner/name.git"
git fetch origin
# fresh task: branch from the remote default branch (check it -- not always main)
git checkout -B "task/<issue#>-<slug>" "origin/$(git remote show origin | sed -n 's/.*HEAD branch: //p')"
# resuming: git checkout "task/<issue#>-<slug>" && git merge --ff-only "origin/task/<issue#>-<slug>"
```

Rules that follow from this layout:

- **Issues, labels, and comments always live in this repo** (`$GITHUB_REPO`), no matter where the code goes. The curl commands below always target `$GITHUB_REPO` for issue operations.
- **Branches and PRs go to the target repo.** When opening a PR on a project repo, substitute its slug in the pulls URL and use `"body":"Closes $GITHUB_REPO#<issue#>\n\n..."` — the cross-repo `Closes` reference auto-closes the task issue here when the PR merges.
- The same branch/commit rules apply in project repos: never commit to the default branch, never force-push, never rewrite pushed history, never touch `.git/hooks` or `.git/config`.
- If a clone fails with 403/404, the PAT doesn't cover that repo — that is end state C (handoff): tell the owner exactly which repo to add to the token.

## Dependencies between tasks

If an issue body or comment thread contains `Depends on #N` (case-insensitive) and issue N is still open, the task is not actionable — skip it during selection. Multiple `Depends on` lines all must be satisfied.

## Labels

| Label | Meaning | Set by |
|---|---|---|
| `status:ready` | Task is defined and available to pick up | Owner |
| `status:in-progress` | Agent is working (or a run died mid-work) | Agent |
| `status:needs-human` | Waiting on the owner: questions, handoff, or review of a blocker | Agent |
| `status:in-review` | PR open, awaiting owner review | Agent |
| `priority:high` / `priority:medium` / `priority:low` | Selection order | Owner |
| `model:<name>` | Requests a specific model for this task (`model:opus`, `model:sonnet`, `model:haiku`, `model:fable`). Falls back to the baseline model if absent or unrecognized. | Owner |

An issue always carries exactly one `status:*` label. Closing the issue = done (owner does this, usually by merging the PR).

## Hand-off README

`README.md` at this repo's root always reflects every task currently waiting on the owner — a PR to review, questions to answer, or a HANDOFF.md checklist to work through — regardless of which repo the work actually landed in. It's maintained by `ops/update_handoff.py`; see `## End states` in RUNNER_PROMPT.md for when it's called. Don't hand-edit between the `<!-- NIGHT-SHIFT-HANDOFF:START/END -->` markers — it's regenerated from a JSON comment on every run.

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

# Replace labels (send the complete new set, e.g. keep the priority and any model:* label):
# This PUT replaces ALL labels, so every label you want to survive must be in the
# array -- always re-send the issue's existing priority:* AND model:* labels, or you
# will silently delete them (which breaks per-task model routing on the next resume).
curl -sS -X PUT -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GITHUB_REPO/issues/$N/labels" \
  -d '{"labels":["status:in-progress","priority:high","model:opus"]}'

# Open a PR (standalone task -- PR lives here alongside the issue):
curl -sS -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GITHUB_REPO/pulls" \
  -d '{"title":"Task #N: <title>","head":"task/N-slug","base":"main","body":"Closes #N\n\n<summary + verification steps>"}'

# Open a PR on a project repo (replace owner/name and base with its default branch;
# note the full-slug Closes reference back to the task issue in this repo):
curl -sS -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/owner/name/pulls" \
  -d '{"title":"Task #N: <title>","head":"task/N-slug","base":"main","body":"Closes OWNER/claude-tasks#N\n\n<summary + verification steps>"}'
```

## Branches and commits

- One branch per task: `task/<issue-number>-<short-slug>` (e.g. `task/12-csv-importer`), created in the target repo. Issue numbers are unique across all your projects because they all come from this repo, so branch names can't collide.
- Push early and often; pushed WIP is the crash-recovery mechanism.
- Never commit to `main` (or the target repo's default branch), never force-push, never rewrite pushed history.
- Standalone task deliverables live in a folder named after the task (e.g. `projects/12-csv-importer/`) in this repo; work targeting a project repo follows that repo's existing layout.

## Question etiquette (end state B)

One consolidated comment. Numbered questions. Each question: (a) the decision needed, (b) options if enumerable, (c) your recommended default. The goal is that the owner can answer the whole batch with one short reply, including just: "defaults."

## Handoff etiquette (end state C)

`HANDOFF.md` at the branch root, written for a reader with zero context: what's blocked, exact enable/setup steps for the owner (numbered, copy-pasteable), where placeholders live, and what the agent will do after unblock. The issue comment is a checklist version of the same.
