# Night Shift remote control

Edit this file from anywhere -- the GitHub web UI or the GitHub mobile app --
to change what tonight's run does, without touching the machine it runs on.
No SSH, no terminal, no laptop required: this is the "I'm on vacation and my
phone is all I have" control panel.

**Why this is safe to trust:** this file lives at the hub repo root, which
puts it in the same protected-path family as `CLAUDE.md` and
`RUNNER_PROMPT.md` -- Night Shift's own `Edit`/`Write` tools categorically
refuse to touch it (see `.claude/settings.json` and `ops/runner-settings.json`
deny lists), and the OS sandbox denies it a second time at the filesystem
layer. The agent can read this file's *effect* (via `check_budget.py`, which
runs before the agent is ever invoked) but can never edit its *content*. Only
someone with write access on github.com or the mobile app can change what's
below.

Two plain `key: value` lines. Everything else on the page is prose for
humans and is ignored by the parser (it looks for these two keys anywhere in
the file with a tolerant regex, so feel free to annotate above/below).

```
mode: normal
model:
```

## `mode`

- `normal` -- full workday protection, default.
- `day-off` -- skip today's schedule gates (auto-reverts at midnight, same as
  `nightshift day-off` run locally).
- `vacation` -- skip schedule gates **and** the weekly budget reserve, until
  changed back. Hard caps (weekly 85%, 5-hour window) still always apply, so
  even open-ended vacation mode can't run the account to empty.

This is a convenience layer on top of the local mode file
(`~/claude-night-shift/mode`, managed by `nightshift day-off` / `nightshift
vacation` / `nightshift normal`). If both are set, whichever is more
restrictive wins for gates 1-2 (see `check_budget.py`); this file is fetched
over the network and is **not** safety-critical, so any error reading it
(network hiccup, bad token, file missing) fails open to the local mode file
-- it never fails open to "run anyway."

## `model`

Leave blank to use whatever `config.env`'s `MODEL` knob says (account default
if that's also blank). Set to a model ID, e.g. `claude-opus-4-8` or
`claude-sonnet-4-6`, to override it for every run until you change this back
to blank. Handy for "there's an emergency and I want the strongest model
available on my plan for the next task, right now" without reaching for a
laptop.

Opus burns weekly budget noticeably faster than Sonnet -- see DESIGN.md's
`PCT_PER_WORK_HOUR` note before leaving an Opus override on indefinitely.
