# `proposed/` — staging area for `ops/` and `.claude/` changes

**This folder is empty on purpose right now — nothing is pending.**

Night Shift's own agent is permanently denied write access to `ops/`,
`.claude/`, `.github/`, `CLAUDE.md`, `RUNNER_PROMPT.md`, and `CONTROL.md`, in
every repo it touches — including this one. That's the same self-protection
rule that stops it from loosening its own budget gates. But some tasks *are*
changes to exactly those files (this template's product lives at those paths).

When a task needs to touch one of those paths, the agent can't write it
directly, so it stages the new version here under `proposed/` and leaves a
human to fold it in with [`../apply-roadmap.sh`](../apply-roadmap.sh):

```bash
cd your-hub-repo-clone    # wherever you copied repo/ into
bash apply-roadmap.sh     # backs up ops/ + .claude/, copies proposed/runner/* + proposed/agent-settings/ into place, shows a diff
# review, commit, push, re-run ops/install.sh
```

`apply-roadmap.sh` reads `proposed/runner/*` (→ `ops/`) and
`proposed/agent-settings/settings.json` (→ `.claude/settings.json`); any
`proposed/*-patch.md` files describe hand-edits to protected prose files
(`CLAUDE.md`/`RUNNER_PROMPT.md`) that no script can apply for you. After you
apply something, delete it from here so this folder only ever reflects what's
still pending.

The Review System, per-task Model Tags, hand-off README, and efficiency
pre-check all went through this folder and are now applied directly into
`ops/`/`.claude/`/`CLAUDE.md`/`RUNNER_PROMPT.md` — see DESIGN.md's roadmap
section for their write-ups. This folder starts empty again, ready for the
next one.
