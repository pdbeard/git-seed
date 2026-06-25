# git-seed — v2 Design Notes

## Context

The v1 command surface (sync, status, scout, browse, where, recent, dirty, open) is
fully implemented. This document covers planned additions motivated by using git-seed
as the core logic layer behind graphical interfaces — QuickShell widgets, status bars,
or similar.

The single-file bash constraint and the design principles from v1 remain in force.

---

## Planned additions

### 1. `--porcelain` — machine-readable status output

**Motivation.** `--status` output is human-readable (`[OK]`, `[DIRTY]`, `[MISSING]`).
A UI widget polling repo state needs structured data it can parse and bind without
grepping bracket tags.

**Behaviour.** A global `--porcelain` flag switches `--status` to tab-delimited output,
one repo per line:

```
owner/repo<TAB>path<TAB>status[<TAB>change_count]
```

- `status` is one of: `ok`, `dirty`, `missing`
- `change_count` is only present when status is `dirty`

Example:

```
pdbeard/alpha   /Users/.../alpha    ok
testorg/beta    /Users/.../beta     dirty   3
pdbeard/gamma   /Users/.../gamma    missing
```

**Scope.** `--porcelain` only affects `--status` for now. Other commands already emit
path-per-line output suitable for programmatic use.

**Non-goal.** Full JSON output. The tab-delimited format is simpler to produce in bash
and trivially parseable in any language or shell pipeline.

---

### 2. `--repo <name>` — single-repo targeting

**Motivation.** Every command currently operates on the whole manifest. A UI needs to
trigger actions on individual repos — the user clicks "pull" on one row, not all of
them.

**Behaviour.** `--repo <name>` is a filter flag that narrows any command to a single
manifest entry. `<name>` follows the same resolution as `--where`: exact `owner/repo`
match first, basename fallback second.

```bash
git-seed --sync  --repo pdbeard/alpha
git-seed --status --repo pdbeard/alpha
git-seed --dirty  --repo pdbeard/alpha
```

**Implementation note.** `parse_conf` already calls a per-entry callback; adding a
filter at that level touches one place and works for all commands automatically.
`emit_existing` should get the same filter so the frontend commands benefit too.

**Exit behaviour.** Exits non-zero if `<name>` matches no manifest entry, so callers
can detect typos cleanly.

---

### 3. `--add <owner/repo>` — direct manifest entry

**Motivation.** `--scout` discovers repos interactively. A UI already knows which repo
the user wants to add (they typed it or picked it from a search). It needs a
non-interactive path.

**Behaviour.**

```bash
git-seed --add pdbeard/new-repo
git-seed --add pdbeard/new-repo --dir work
```

- `--dir` specifies the subdirectory label (e.g. `personal`, `work`). Defaults to the
  first directory label found in the conf, or `projects` if none exist.
- Inserts under the first `[path]` section in the conf, or appends a new one.
- Reuses the existing `scout_insert_entry` logic — no new insertion code needed.
- Idempotent: silently succeeds if the entry already exists.
- Does not clone. Run `--sync --repo <owner/repo>` after to clone.

---

### 4. `--remove <owner/repo>` — untrack a repo

**Motivation.** The complement of `--add`. A UI should be able to remove a repo from
tracking without the user hand-editing the conf.

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

**Safety.** Before deleting the local clone, check for uncommitted changes (via
`git status --porcelain`). If dirty, abort with `[ERROR]` and require `--force` to
override. Never silently delete a dirty working tree.

---

## UI integration notes

The intended usage pattern for a QuickShell widget or similar:

| Widget action | git-seed call |
|---|---|
| List all repos with state | `--status --porcelain` |
| Pull one repo | `--sync --repo <name>` |
| Open one repo in editor | `--open --repo <name>` |
| Add a repo by name | `--add <owner/repo> --dir <dir>` |
| Remove a repo | `--remove <owner/repo>` |
| Get path for a repo | `--where <name>` |

`--browse`, `--scout`, and `--recent` are terminal-native commands. A UI replaces them
with its own interface and does not need to call them.

---

## Implementation order

1. `--porcelain` — unblocks UI development immediately; self-contained change to
   `do_status`.
2. `--repo` targeting — enables all per-repo UI actions; single change to
   `parse_conf` / `emit_existing`.
3. `--add` — reuses existing `scout_insert_entry`; low effort.
4. `--remove` — new logic, highest risk (manifest mutation + optional file deletion);
   implement last.
