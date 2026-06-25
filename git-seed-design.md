# git-seed — Design Document

## Overview

git-seed is a single bash script that manages a developer's repos across one
or more machines. It pairs two halves that other tools tend to separate:

- A **declarative manifest** (`repos.conf`) describing which repos should
  exist locally and where.
- An **interactive workflow surface** for discovering new repos, syncing
  state, and starting work — built on `fzf` and shell composition.

The current script already covers the manifest half well. This document
describes the deliberate expansion into the workflow surface — keeping the
script's single-file, bash-only character intact while making it the
day-to-day entry point to a developer's repo collection, not just a
provisioning tool.

## Positioning

git-seed sits in a gap between existing tools:

| Tool | What it does | What it misses |
|---|---|---|
| `ghq` | Clones by URL into a structured tree | No manifest, no concept of drift |
| `mr` (myrepos) | Declarative VCS multiplexer | No browser, unmaintained, perl |
| `zoxide` / `autojump` | Jumps to known directories | Doesn't know what *should* exist |
| `chezmoi` / dotbot | Manages dotfiles | Wrong scope for project repos |
| IDE project managers | Browse and open | GUI-only, no sync, no drift detection |

The unique seat: **"the declarative manifest of my repos, plus the
interactive surface to work with them."** The manifest answers "what should
be on this machine?" The frontend answers "what is here, let me start
working." No existing tool covers both as one thing.

## Design Principles

1. **One bash script.** No Python rewrite. No package manager. `curl |
   bash`-installable. The single-file constraint caps complexity at
   something a person can read end-to-end.

2. **Manifest is the source of truth.** The conf file describes intent.
   Every command either reads from it, converges reality toward it, or
   updates it interactively. There is no hidden state.

3. **Compose, don't subsume.** Lean on `fzf` for fuzzy selection, `gh` for
   GitHub auth, `git` for everything git. Don't reimplement any of them.
   Where a tool isn't present, degrade to something simple (numbered
   prompts) rather than hand-rolling a replacement.

4. **stdout is an API.** Path-emitting commands (`--pick`, `--where`) write
   one path per line to stdout so they compose with `cd`, `$EDITOR`,
   `xargs`, etc. Non-path commands use a stable line format prefixed with
   `[STATUS]`-style tags for grep-ability.

5. **Idempotence.** Every mutating command is safe to run twice. `--sync`
   converges. `--scout` only adds. Manifest edits are append-or-insert,
   never destructive.

6. **The `--scout` pattern is the spine.** The interaction where the tool
   *discovers* untracked state and *interactively offers* to bring it into
   the manifest is the central design pattern. It's what makes a
   declarative tool tolerable to maintain by hand.

7. **No coupling.** git-seed depends on `bash`, `git`, and optionally `fzf`
   and `gh`. It does not depend on, integrate with, or know about any
   sibling tooling. If other tools want to consume its output they can —
   that's what stdout is for.

## Architecture

### Single-file script

`git-seed` is one bash file. Sections are delineated by `# ── Heading ──`
comment banners. Functions follow a convention:

- `parse_conf <callback>` — iterates conf entries, calls `callback
  base_dir dir owner/repo` per entry. The callback pattern keeps
  per-command logic separated from parsing.
- `do_<command>` — callback for `parse_conf`-driven commands (`do_sync`,
  `do_status`).
- `<command>_repos` — self-contained commands that need their own loop
  (`scout_repos`, `list_repos`, `browse_repos`).

### Config lookup order

Unchanged from current behavior:

1. `--conf FILE`
2. `$XDG_CONFIG_HOME/git-seed/repos.conf` (default
   `~/.config/git-seed/repos.conf`)
3. `<script dir>/repos.conf`

### Manifest format

Current format is preserved. INI-flavored with `[path ...]` section
headers:

```
[path ~/development]
personal    pdbeard/intermcli
work        someorg/their-repo

[path ~/src]
libs        someuser/a-library
```

Entries before any `[path]` section fall back to `$BASE_DIR` (default
`~/git-seed-repos`). Lines starting with `#` are comments.

The format is not TOML on purpose: it stays human-editable, it doesn't
require a TOML parser in pure bash, and it preserves the existing user's
files. If a structured format becomes necessary later, accept both and
deprecate gradually.

### Dependencies

| Dependency | Status | Used for |
|---|---|---|
| `bash` 4+, `git` | Required | Core operation |
| `fzf` | Optional | `--browse`, `--pick`, `--open` interactive flows |
| `gh` | Optional | `--list`, token resolution for private repos |
| `GITHUB_TOKEN` env | Optional | Token resolution if `gh` absent |

Missing optional dependencies degrade gracefully:

- No `fzf`: `--browse` / `--pick` fall back to a numbered prompt.
- No `gh` and no token: clones use anonymous HTTPS; private repos fail
  with a clear error.

## Command Surface

### Existing commands (preserved)

| Command | Purpose |
|---|---|
| `--sync` | Clone missing, pull existing |
| `--clone-only` | Clone missing only |
| `--pull-only` | Pull existing only |
| `--scout` | Discover untracked repos, interactively add to manifest |
| `--status` | Show cloned / missing / dirty for every manifest entry |
| `--list` | Dump GitHub repos via `gh` in conf-ready format |

### New commands (the frontend)

| Command | Purpose | Output |
|---|---|---|
| `--pick` | fzf picker over tracked repos | Selected path on stdout |
| `--browse` | fzf picker with preview pane (recent commits, README) | TTY only |
| `--where <repo>` | Look up the local path for a single repo | Path on stdout |
| `--recent [N]` | List tracked repos by mtime, newest first | One path per line |
| `--dirty` | List tracked repos with uncommitted changes | One path per line |
| `--open [editor]` | `--browse` then exec `$editor` on the selection | n/a |

### Composition examples

```bash
cd "$(git-seed --pick)"
code "$(git-seed --where pdbeard/intermcli)"
git-seed --dirty | xargs -I{} git -C {} status -s
git-seed --recent 5
```

### The browse experience

`--browse` is the headline new capability. Implementation uses fzf's
preview pane:

```
┌── pdbeard/intermcli ────────────────────────┐
│ pdbeard/intermcli                            │
│ pdbeard/git-seed                             │
│ someuser/libfoo                              │
│                                              │
├── preview ──────────────────────────────────┤
│ Path: ~/development/personal/intermcli       │
│ Remote: github.com/pdbeard/intermcli         │
│ Status: dirty (3 modified)                   │
│                                              │
│ Recent commits:                              │
│ 7befc72 Update shared dep reporting          │
│ 5f30b9c update pip_audit flag                │
│ 6fd13fd Add specific audit for 25.2 pip      │
│                                              │
│ README:                                      │
│ # IntermCLI                                  │
│ Suite of interactive CLI tools...            │
└──────────────────────────────────────────────┘
```

The preview command is roughly:

```bash
fzf --preview '
  path={path}
  echo "Path:   $path"
  echo "Remote: $(git -C "$path" remote get-url origin 2>/dev/null)"
  echo
  git -C "$path" log --oneline -10 2>/dev/null
  echo
  head -20 "$path/README.md" 2>/dev/null
'
```

This is the differentiator. It's better than what most "interactive project
picker" tools provide today, and it costs ~30 lines of bash.

### The --scout pattern, elevated

`--scout` already implements the central interaction model: discover
drift, prompt to resolve. The frontend commands should preserve this where
useful:

- `--scout` learns to use fzf as the prompt UI when available (preview
  shows the remote, recent commits, and README before the user decides to
  add).
- After a successful `--sync` or `--scout`, hint the user about
  `--browse`.

## Roadmap

Implementation order is chosen to ship value early without blocking on
later choices.

### Phase 1 — `--pick` and `--where`

Smallest surface. No interactive output to design. Immediately useful in
shell aliases.

- `--pick` reads the manifest, pipes through `fzf` (or numbered prompt),
  emits the selected absolute path.
- `--where owner/repo` resolves a manifest entry to a path.
- Both exit non-zero with no stdout if nothing selected / not found.

### Phase 2 — `--browse` with preview

The headline interactive command. Builds on the Phase 1 infrastructure.

- Same picker as `--pick` but with `--preview` configured.
- No path emitted; intended for interactive terminal use.
- Hotkey hints visible in fzf's footer.

### Phase 3 — `--recent`, `--dirty`, `--open`

Query and convenience commands.

- `--recent [N]` sorts by `git log -1 --format=%ct` across all manifest
  entries. Default N=20.
- `--dirty` reuses `do_status`'s dirty detection, prints paths only.
- `--open [editor]` runs `--browse` then `exec $editor "$path"`. Editor
  defaults to `$EDITOR`, falls back to `code`, `vim`, in that order.

### Phase 4 — fzf-driven `--scout`

Upgrade the existing `--scout` to use fzf when available, with preview pane
showing the remote and a few commits before the y/n prompt.

### Phase 5 (maybe) — `--archive` and `--remove`

If real use surfaces the need: a way to mark a manifest entry as no longer
wanted, and to remove the local clone safely. Out of scope for v1.

## Non-Goals

Explicitly out of scope. Listed to prevent scope creep:

- **A TUI without fzf.** If fzf isn't available, degrade to numbered
  prompts. Do not build a from-scratch arrow-key navigator in bash.
- **Project-type detection.** Not git-seed's job. If a user wants
  language-aware browsing, they can pipe through another tool.
- **Anything in Python.** No port. No Python helper modules. If a feature
  can only reasonably be done in Python, it's a sign that feature belongs
  in a different tool entirely.
- **Integration with intermCLI, find-projects, or any sibling.** git-seed
  is standalone. Other tools may consume its output. git-seed does not
  consume theirs.
- **Manifest format breaking changes.** The current INI-ish format stays.
  Additions are backward-compatible.
- **Multi-VCS support (svn, hg, fossil).** GitHub + git only. The "git" in
  the name is load-bearing.
- **Sync conflict resolution beyond `git pull`.** If pull fails because
  the working tree is dirty, report it and move on. The user resolves.

## Open Questions

Honest list of things not yet decided.

1. **Selection key for `--browse` actions.** Should `enter` open in editor,
   or print path? Currently leaning toward `enter` = print path (composable
   with `cd $(...)` if user has a shell function), `ctrl-o` = open in
   editor. Needs trial.

2. **Manifest mutation safety.** `--scout` currently uses `awk` to insert
   under the right `[path]` section. This is fragile if users have
   non-standard formatting (e.g. tabs, comments mid-section). Worth a
   round of property-based testing.

3. **Token in command line for clone.** Current `git -c credential.helper`
   trick puts the token briefly in `argv`, visible to other users on a
   multi-user host. Acceptable for personal machines, less so for shared
   ones. Document or use `GIT_ASKPASS` alternative.

4. **Tests.** There are none today. Bash is famously hard to test, but
   `bats` is mature and covers what's needed. Worth adding before the
   refactor so regressions get caught.

5. **Distribution.** Currently install is `git clone && symlink`. Worth
   considering: a Homebrew formula, an AUR package, a one-line installer
   (`curl ... | bash` is contentious but common). Defer until there are
   external users requesting it.

## Success Criteria

git-seed v1 is done when:

- A new machine setup is `git clone git-seed; ./git-seed --sync`, period.
- Daily use is `cd "$(git-seed --pick)"` or `git-seed --browse`, and
  feels lighter than `cd ~/dev` + `ls`.
- `git-seed --scout` after a manual clone correctly offers to track it.
- `git-seed --status` reliably surfaces drift across all tracked repos.
- The script is under 600 lines of bash. (Currently ~330.)

The implicit success criterion: git-seed becomes the tool a user reaches
for first when they start a work session, displacing `zoxide`/`fzf
+ ghq`/manual `cd` for the common case.
