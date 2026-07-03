# Handoff: Task #1 — Make Night Shift Public

This branch has real, useful work on it, but it does not fully satisfy the issue's definition of done. Two independent blockers stopped normal completion — one on the GitHub side, one structural — both explained below, along with exactly what to do about each.

## What's actually done here

- **README.md** — full rewrite: professional, welcoming, "why this exists" framing up front, accurate quickstart, a day-to-day usage section (pause/resume, model switching, reviewing work), and an honest platform-support note instead of silently assuming macOS.
- **DESIGN.md** — added a `## Roadmap: designed, not yet built` section with implementation-ready specs for: Linux (`systemd --user` timer) and native Windows (PowerShell + Task Scheduler) support; a `CONTROL.md`-based remote mode/model switch the owner can flip from GitHub's mobile app, including the exact fix for the security objection recorded against the old "not built" version of this idea; a secret-leak scanner design (what it scans, what it prints, where it plugs into the runner prompt); and a couple of concrete CLI/housekeeping fixes (hardcoded `/usr/bin/python3`, an `uninstall.sh`, `nightshift model`/`nightshift logs` subcommands).
- **LICENSE** — added MIT. No license existed; picked MIT as a sensible default for a tool meant to be broadly reusable. Easy to swap if you want something else.

## Blocker 1: the GitHub token can't post comments, set labels, or open PRs

Every write I tried against `$GITHUB_REPO` (the hub repo, `ethanbudge/claude-tasks`) that touches issues or pull requests came back `403 Resource not accessible by personal access token`. The response headers are explicit about why:

```
x-accepted-github-permissions: issues=write; pull_requests=write
```

...meaning the token currently has `issues=read` and `pull_requests=read` (both confirmed via a GET, which succeeded), but not the write side of either. `git push` itself should still work (the token's `Contents` scope looks intact based on collaborator permissions), but I could not:
- label this issue `status:in-progress` / `status:in-review` / `status:needs-human`
- post the claiming comment, a questions comment, or a summary comment
- open the PR this task is supposed to end with

**Fix:** GitHub Settings → Developer settings → Fine-grained tokens → the token Night Shift uses → Repository permissions → set **Issues** and **Pull requests** to **Read and write** (Contents and Metadata already look fine). This is exactly what `README.md`'s own setup instructions say to configure — the currently-installed token doesn't match them. This isn't specific to this task; *no* task can reach any of its four end states without this, since all of them require an issue comment and most require a label change or a PR.

## Blocker 2: the agent can't edit the files this task asks it to change

The bulk of the definition of done — cross-platform scripts, the model-switch mechanism, the remote control file, the secret scanner, CLI polish — all requires editing files under `repo/ops/`, `repo/.claude/`, `repo/.github/`, `repo/CLAUDE.md`, or `repo/RUNNER_PROMPT.md`. Night Shift's own hard rules (in `RUNNER_PROMPT.md`) permanently deny the agent write access to any path containing `ops/`, `.claude/`, `.github/`, `CLAUDE.md`, or `RUNNER_PROMPT.md`, in *every* repo it touches, including this one — by design, so it can never rewrite the instructions that govern it. My own tools refused these edits outright; this isn't a judgment call I made, it's enforced.

The collision: this repo's actual product is a set of files that live at exactly those paths (they're the templates end users copy into their own hub repo). The safety rule that protects a *hub* repo from self-tampering also, as a side effect, blocks legitimate product development on the repo that generates that hub repo's template.

**Two ways to resolve it**, pick one:

1. **Apply the roadmap by hand.** `DESIGN.md`'s new roadmap section is written to be directly implementable — copy the specs into `ops/check_budget.py`, `ops/night-shift.sh`, `ops/mode.sh`, a new `ops/secret_scan.py`, a new `repo/CONTROL.md`, updated `.claude/settings.json` / `runner-settings.json` deny lists, and the `RUNNER_PROMPT.md` secret-scan step. Probably a few hours of focused work, not a redesign.
2. **Restructure this repo's paths** so the pattern-based protection stops false-positiving on legitimate content — e.g. rename `repo/ops` → `repo/runner`, `repo/.claude` → `repo/agent-config` in this project (with corresponding updates to the setup instructions telling end users what to copy where). Then a future Night Shift run *could* do this work itself. This changes the hub-repo layout convention, so it's a bigger call — only do it if you expect to hand Night Shift more tasks like this one.

I'd default to (1) for this specific batch of changes, since it's a bounded amount of work and doesn't touch the hub-repo convention that every other task in this system already depends on.

## Once both are fixed

A future run can pick up `task/1-make-night-shift-public`, apply the roadmap items from `DESIGN.md`, verify them (the secret scanner and the CLI additions are the easy ones to actually test; the systemd/PowerShell paths will need a real Linux/Windows box or careful manual review, since this sandbox is macOS-only), and then post the claiming comment / open the PR that this run couldn't.
