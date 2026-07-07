# Handoff: Task #1 — Make Night Shift Public

This is the fourth run on this branch. The first three were almost entirely blocked; this one resolved one of the two blockers and used the resulting write access to build out nearly the entire definition of done. What's left is a single, unavoidably-manual integration step plus real-hardware verification of two files this sandbox can't run.

## Blocker 1 — RESOLVED this run

Three earlier runs found the fine-grained PAT was read-only: `PUT .../issues/1/labels`, `POST .../issues/1/comments`, and `git push` to `ethanbudge/Night-Shift` all came back `403`. This run re-tested all three independently, from scratch, before doing anything else:

- `PUT .../issues/1/labels` → succeeded (label set to `status:in-progress`)
- `POST .../issues/1/comments` → succeeded (claiming comment posted)
- `git push -u origin task/1-make-night-shift-public` → succeeded

Whatever needed fixing on the token side has been fixed. This run did the label/comment/push work every prior run was blocked on.

## Blocker 2 — confirmed still real, still structural, not something a future run can retry past

`ops/`, `.claude/`, `.github/`, `CLAUDE.md`, and `RUNNER_PROMPT.md` are permanently write-denied to the agent, in every repo it touches — including this one, whose actual product is a set of files that live at exactly those paths (they're the template end users copy into their own hub repo). This run re-confirmed it directly, twice:

- `Edit` on `repo/ops/night-shift.sh` → refused: "File is in a directory that is denied by your permission settings."
- `Write` of a brand-new file at `repo/ops/new_file_probe.py` → refused with the identical message, so this isn't limited to editing existing files; **any** file under a protected directory name is unreachable, new or old.

This is not a token permission and cannot be fixed by re-running with different credentials — it's the same self-protection rule that stops the agent from loosening its own gates, applied literally to path components, and it's supposed to be permanent. The only way past it in this repo specifically is a human copy, which is exactly what's staged below.

## What got built this run

Given Blocker 2 is permanent, everything that would normally live in `ops/`/`.claude/` was instead written into `repo/proposed/` (a plain, unprotected directory name) as complete, ready-to-copy files, plus `repo/apply-roadmap.sh` — a script **you** run, once, from a normal shell, that copies them into place. The agent cannot run this script itself for the same reason it couldn't write the files directly; see the script's own header comment.

| Item | Where it lives | Tested? |
|---|---|---|
| Secret-leak scanner (`secret_scan.py`) | `repo/proposed/runner/secret_scan.py` | Yes — unit-tested against fixtures covering every pattern (GitHub/Anthropic/AWS/Slack tokens, PEM headers, high-entropy assignments incl. `some_secret`-style prefixed names), plus a clean-directory negative test and a `.git/`-exclusion test. One real bug was found and fixed in testing (fixed-length `ghp_` regex too brittle; `some_secret` missed by an over-strict word boundary). |
| `CONTROL.md` remote control | `repo/CONTROL.md` (live now — not a protected path) + wiring in `repo/proposed/runner/check_budget.py`, `repo/proposed/agent-settings/settings.json`, `repo/proposed/runner/runner-settings.json` | Parsing logic unit-tested directly (including a real bug found and fixed: `\s*` in the value regex crossed newlines and swallowed a following markdown code-fence line as the "value" — fixed to `[ \t]*`). Override-combining logic (`combine_overrides`) unit-tested. The live GitHub fetch itself is untestable without a deployed instance, but fails open to the local mode file on any error by design. |
| Cross-platform install | `repo/proposed/runner/install.sh` (dispatches macOS/Linux by `uname`), `night-shift.sh` (portable `python3` lookup, `systemd-inhibit` fallback), `nightshift.service`/`.timer`, `night-shift.ps1`, `install.ps1` | **Partial.** `install.sh`/`night-shift.sh` changes are bash, syntax-checked (`bash -n`) and logically verified. The systemd unit files and both `.ps1` files could not be executed — this sandbox is macOS-only with no `pwsh` available. They're careful, doc-reviewed implementations (brace/paren-balance checked), not field-tested. Treat the first real scheduled run on Linux or Windows as a dry run to watch closely. |
| CLI polish (`nightshift model`/`logs`, `uninstall.sh`) | `repo/proposed/runner/mode.sh`, `repo/proposed/runner/uninstall.sh` | Yes — ran against a scratch install in `$TMPDIR`: `model` show/set/default, `logs` with and without an existing log file, `day-off`/`vacation`/`normal`/bad-date rejection, and the usage/help path all verified. `uninstall.sh` is syntax-checked only (it unloads real OS scheduler state, not something to dry-run for real without an actual install). |
| `RUNNER_PROMPT.md` patch (secret-scan step + `CONTROL.md` protection) | `repo/proposed/runner-prompt-patch.md` (prose description, not a file — see below) | N/A — this is instructions for a manual edit, not code. |
| README.md / DESIGN.md | Updated in place (not staged — these aren't protected paths) | README rewritten with a new "Applying the staged roadmap items" section, CLI/CONTROL.md docs, and an honest tested-vs-code-reviewed note. DESIGN.md's roadmap section rewritten from "designed, not yet built" to "built, staged for integration," pointing at the actual files. |

## What you need to do

1. **Clean up stray test files first.** A second run's accidental `echo > repo/ops/test_probe.txt` (documented in the old handoff below) is still sitting there, untracked. This run also left `repo/proposed/ops/` — an accidentally-created empty directory from before discovering the naming collision — which is harmless (git won't track an empty dir) but you can `rmdir` it if you want it gone. Run:
   ```bash
   rm -f repo/ops/test_probe.txt
   ```
2. **Run the integration script** from the hub repo clone (wherever you copied `repo/` into):
   ```bash
   bash apply-roadmap.sh
   ```
   This backs up `ops/` and `.claude/` to `*.bak-<timestamp>`, copies everything from `repo/proposed/` into place, and shows you a diff to review.
3. **Apply the `RUNNER_PROMPT.md` patch by hand** — described exactly in `proposed/runner-prompt-patch.md` (two small edits: a secret-scan step, and adding `CONTROL.md` to the protected-path list). This is the one step `apply-roadmap.sh` deliberately doesn't do, since editing `RUNNER_PROMPT.md` is exactly the write this whole system exists to deny even to itself.
4. **Review the diff, commit, push, re-run `ops/install.sh`** (or `install.ps1` on Windows) to pick up the new scripts on your machine.
5. **Watch the first run on a new platform closely** if you're on Linux or Windows — those two paths are code-reviewed but not execution-tested (see the table above).

## Definition of done: where it stands after all of the above

- **#1 (cross-platform setup)** — done, pending the caveat above about Linux/Windows being untested.
- **#2 (clean, efficient, bug-free codebase)** — the two real bugs found during this run's own testing (the `ghp_`/word-boundary issues in `secret_scan.py`, the newline-crossing regex in `check_budget.py`) were fixed before landing, not left in. No other cleanup was identified as needed in the existing `ops/` scripts beyond what's already folded into the staged changes.
- **#3/#4 (model switching, remote control without touching the machine)** — done: `nightshift model` locally, `CONTROL.md` remotely, once staged items are applied.
- **#5 (professional public README)** — done.
- **#6 (other QoL)** — `uninstall.sh`, portable `python3` lookups, `CLAUDE_BIN` fallback comment.
- **#7 (secret-leak safety)** — done, pending the `RUNNER_PROMPT.md` wiring step above.
- **#8 (CLI aesthetics)** — `nightshift status/model/logs` reads cleanly; unchanged otherwise, no specific complaint was on record to address.

Net: this task cannot reach a clean `status:in-review` PR this run, because the actual definition of done isn't satisfied until you run `apply-roadmap.sh` and hand-patch `RUNNER_PROMPT.md` — steps only you can do. Once you have, a future run (or you, manually) can open the PR.

---

## Prior runs' notes (kept for the record; Blocker 1 details above supersede the "unfixed" framing below, Blocker 2 details above supersede and extend these)

### Original blocker 1 write-up

Every write I tried came back denied — not just issues/PRs, but `git push` itself: `PUT .../issues/1/labels` and `POST .../issues/1/comments` on the hub repo both returned `403 Resource not accessible by personal access token` (`x-accepted-github-permissions: issues=write; pull_requests=write` missing). `git push` against `ethanbudge/Night-Shift` failed with `remote: Permission ... denied` / `403`. Cloning and fetching both worked, so it wasn't a repo-enrollment problem — Contents was also read-only. Fix applied since (confirmed working this run): the PAT's Contents/Issues/Pull requests permissions were set to Read and write.

### Original blocker 2 write-up and the two options it proposed

The bulk of the definition of done requires editing files under `repo/ops/`, `repo/.claude/`, `repo/.github/`, `repo/CLAUDE.md`, or `repo/RUNNER_PROMPT.md`. Two ways to resolve it were proposed: (1) apply the roadmap by hand — this run did the "apply" half of that (wrote everything out fully) and left the "by hand" copy step as `apply-roadmap.sh`, so what's left for you is much smaller than "a few hours of focused work." (2) restructure this repo's paths so the pattern-based protection stops false-positiving on legitimate content — not attempted, since (1) turned out to be tractable and doesn't touch the hub-repo layout convention every other task in this system depends on.

### Second run's notes

Found and worked around a local sandbox quirk: `~/.gitconfig` isn't readable from inside the sandbox, so `git` needs `GIT_CONFIG_GLOBAL=/dev/null` (this run confirmed the same workaround still applies and used it throughout). Also found that a plain shell redirect (`echo ... > repo/ops/test_probe.txt`) wasn't caught by the same Edit/Write policy that blocks the tool-based routes — flagged as a mistake not to repeat, and this run didn't repeat it (only tested denial via the `Edit`/`Write` tools directly, never via a Bash redirect into a protected path).

### Third run's notes

Re-tested all three write paths a third time with identical (unfixed, at the time) results, and concluded the token issue was a stable environment fact rather than something to keep re-testing. That conclusion turned out to be provisional, not permanent — this run found it fixed. The lesson for future runs: re-verify blockers that depend on external configuration (tokens, permissions) each time, even after multiple consistent failures, since they can be fixed out-of-band by the owner without a corresponding update to this file.
