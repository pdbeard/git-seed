# git-seed — v2 Design Notes

## Context

The v1 command surface (sync, status, scout, browse, where, recent, dirty, open) is
fully implemented. This document covers planned additions motivated by using git-seed
as the core logic layer behind graphical interfaces — QuickShell widgets, status bars,
or similar.

The single-file bash constraint and the design principles from v1 remain in force.

---

## Planned additions

### 1. `--tsv` — machine-readable status output

**Motivation.** `--status` output is human-readable (`[OK]`, `[DIRTY]`, `[MISSING]`).
A UI widget polling repo state needs structured data it can parse and bind without
grepping bracket tags.

**Behaviour.** A global `--tsv` flag switches `--status` to tab-delimited output,
one repo per line:

```
owner/repo<TAB>path<TAB>state<TAB>changes<TAB>unpushed
```

- `state` is one of: `ok`, `ahead`, `dirty`, `broken`, `missing`
- `changes` and `unpushed` are always present, `0` where not applicable, so the
  column count is fixed and a parser never has to branch on field length

Example:

```
pdbeard/alpha   /Users/.../alpha    ok      0   0
testorg/beta    /Users/.../beta     dirty   3   1
pdbeard/gamma   /Users/.../gamma    ahead   0   2
pdbeard/delta   /Users/.../delta    broken  0   0
pdbeard/zeta    /Users/.../zeta     missing 0   0
```

The state vocabulary is defined by `--status`; see the Repo states table in the
README. `behind` is deliberately absent — it cannot be known without contacting
the remote, which `--status` never does. `--outdated` answers that question.

**Scope.** `--tsv` only affects `--status` for now. Other commands already emit
path-per-line output suitable for programmatic use.

**Naming.** `--porcelain` was considered first, by analogy with `git status
--porcelain`. Rejected in favour of `--tsv`: git's plumbing/porcelain split describes
a real two-layer architecture that git-seed does not have, so the term would be
borrowed as a bare convention rather than as a description. `--tsv` says what the
output actually is and is legible without git trivia. The stability promise that
`--porcelain` carries by convention is stated explicitly below instead.

**Stability.** Once a UI parses this format, the column order and the `state`
vocabulary are fixed. New columns may only be appended to the right. The five
states were settled before any consumer existed, precisely so that adding one
later is not a breaking change.

**Caveat.** A repo path containing a literal tab or newline would corrupt a row. This
is not escaped; such paths are considered out of scope.

**Deferred: `--json`.** Not rejected outright, but deferred until a consumer actually
needs it. Producing correct JSON in bash means hand-rolling string escaping — `jq`
cannot be assumed present, and paths may contain quotes or backslashes. TSV is
trivially parseable in any language, so JSON earns its escaping bug surface only when
something concrete requires it. If added later, `--json` sits beside `--tsv` as a
sibling flag; no `--format=<x>` machinery until a third format exists.

---

### 2. `--repo <name>` — single-repo targeting

**Motivation.** Every command currently operates on all listed repos. A UI needs to
trigger actions on individual repos — the user clicks "pull" on one row, not all of
them.

**Behaviour.** `--repo <name>` is a filter flag that narrows any command to a single
entry in the config file. `<name>` follows the same resolution as `--where`: exact `owner/repo`
match first, basename fallback second.

```bash
git-seed --sync  --repo pdbeard/alpha
git-seed --status --repo pdbeard/alpha
git-seed --dirty  --repo pdbeard/alpha
```

**Implementation note.** `parse_conf` already calls a per-entry callback; adding a
filter at that level touches one place and works for all commands automatically.
`emit_existing` should get the same filter so the path commands benefit too.

**Exit behaviour.** Exits non-zero if `<name>` matches no entry, so callers
can detect typos cleanly.

---

### 3. `--add <owner/repo>` — add an entry directly

**Motivation.** `--scout` discovers repos interactively. A UI already knows which repo
the user wants to add (they typed it or picked it from a search). It needs a
non-interactive path.

**Behaviour.**

```bash
git-seed --add pdbeard/new-repo
git-seed --add pdbeard/new-repo --dir work
```

- `--dir` specifies the label (for example `personal` or `work`). Defaults to the
  first label in the config file, or `projects` if none exist.
- Inserts under the first `[path]` section in the config file, or appends a new one.
- Reuses the existing `scout_insert_entry` logic — no new insertion code needed.
- Idempotent: silently succeeds if the entry already exists.
- Does not clone. Run `--sync --repo <owner/repo>` after to clone.

---

### 4. `--remove <owner/repo>` — remove an entry

**Motivation.** The complement of `--add`. A UI should be able to remove an entry
without the user editing the config file by hand.

**Behaviour.**

```bash
git-seed --remove pdbeard/old-repo
git-seed --remove pdbeard/old-repo --delete-local
```

- Default: removes the entry from `repos.conf` only. Local clone is untouched.
- `--delete-local`: also deletes the local clone directory. Requires explicit flag —
  destructive operations should never be the default.
- Exits non-zero if the entry is not found.
- Prints `[REMOVED] owner/repo` on success, `[WARN] local clone kept at <path>` unless
  `--delete-local` was passed.

**Safety.** Before deleting the local clone, check for uncommitted changes (with
`git status --porcelain`). If dirty, abort with `[ERROR]` and require `--force` to
override. Never silently delete a dirty working tree.

---

## UI integration notes

The intended usage pattern for a QuickShell widget or similar:

| Widget action | git-seed call |
|---|---|
| List all repos with state | `--status --tsv` |
| Pull one repo | `--sync --repo <name>` |
| Open one repo in editor | `--open --repo <name>` |
| Add a repo by name | `--add <owner/repo> --dir <dir>` |
| Remove a repo | `--remove <owner/repo>` |
| Get path for a repo | `--where <name>` |

`--browse`, `--scout`, and `--recent` are terminal-native commands. A UI replaces them
with its own interface and does not need to call them.

---

## Performance consideration: serial git calls

**The problem.** `--status`, `--dirty`, and `--recent` shell out to git once per repo,
sequentially. `--status` runs `git status --porcelain` for every cloned entry; on a
cold cache with many listed repos this takes seconds.

This is fine for a command a person runs occasionally. It is not obviously fine for a
widget polling `--status --tsv` on a timer, which is the motivation for the whole v2
surface. A poll that takes three seconds cannot run every second, and a poll that
spawns two git processes per repo per tick is a meaningful background load.

**Measure before designing around it.** The cost is unknown at present — it has not
been measured with a realistic config file. Time `--status` with the number of repos
you actually expect before choosing any of the following:

- **Do nothing.** If a full poll is comfortably under the intended refresh interval,
  there is no problem to solve. This is the most likely result for a few dozen repos.
- **Parallelise.** `xargs -P` over the per-repo check. Cheap in effort, but reorders
  output, so `do_status` would need to collect and sort rather than print as it goes.
- **Let the caller poll less.** Push the problem to the UI: poll on a long interval,
  refresh a single repo with `--sync --repo <name>` on demand. Costs nothing here.
- **Cache.** A state file with mtime-based invalidation. Most effective, and by far the
  most complexity and the most ways to be subtly wrong. Avoid unless measurement
  proves it necessary.

**Update.** `--status` now gets dirty state and the unpushed count from a single
`git status --porcelain=v2 --branch` per repo, so adding upstream awareness cost
no additional invocations. The per-repo count is one git process, unchanged.
Network checks live in `--outdated`, which is deliberately a separate,
explicitly triggered command — the fast path stays offline.

**Bearing on `--tsv`.** None directly — the flag changes formatting, not the number of
git invocations. But it is the feature that turns this from a non-issue into a
question, because it is the feature that invites polling. Worth answering before the
widget is built, since the answer could change what the widget asks for.

---

## Implementation order

1. `--tsv` — unblocks UI development immediately; self-contained change to
   `do_status`.
2. `--repo` targeting — enables all per-repo UI actions; single change to
   `parse_conf` / `emit_existing`.
3. `--add` — reuses existing `scout_insert_entry`; low effort.
4. `--remove` — new logic, highest risk (config file changes and optional file deletion);
   implement last.
