# git-seed

A bash script for managing multiple GitHub repositories across your machine. Clone, update, and discover repos from a simple config file.

## Installation

```bash
git clone https://github.com/pdbeard/git-seed.git ~/dev/git-seed
```

Optionally add to your PATH:

```bash
ln -s ~/dev/git-seed/git-seed ~/.local/bin/git-seed
```

## Config

Copy the example config and edit it:

```bash
mkdir -p ~/.config/git-seed
cp repos.conf.example ~/.config/git-seed/repos.conf
```

Config format:

```
[path ~/projects]
personal      youruser/your-repo
work          yourorg/their-repo

[path ~/src]
libs          someuser/a-library
```

Each `[path]` section sets the base directory for the entries below it. The subdirectory is relative to that path. Entries above any `[path]` section fall back to `~/git-seed-repos`.

Config file is looked up in this order:

1. `--conf FILE`
2. `~/.config/git-seed/repos.conf` (or `$XDG_CONFIG_HOME/git-seed/repos.conf`)
3. `<script dir>/repos.conf`

## Usage

```
git-seed <command> [options]

Manifest commands:
  --sync           Clone missing repos and pull existing ones
  --clone-only     Clone missing repos, skip existing
  --pull-only      Pull existing repos, skip missing
  --scout          Scan paths defined in conf for untracked git repos and
                   interactively offer to add them (multi-select fzf if present)
  --status         Show cloned/missing/dirty state for all repos in conf
  --list           List your GitHub repos via gh CLI (requires gh auth login)
                   Outputs lines ready to paste into repos.conf

Frontend commands:
  --pick           fzf picker over tracked, cloned repos. Prints path on stdout.
  --browse         fzf picker with preview (commits, status, README).
                   Prints selected path on stdout.
  --where <repo>   Look up the local path for owner/repo (or basename).
                   Prints path on stdout.
  --recent [N]     List N most-recently-committed tracked repos (default 20).
  --dirty          List tracked repos with uncommitted changes.
  --open [editor]  Run --browse, then open the selection in editor.
                   Editor defaults: $EDITOR, then code, then vim.

Options:
  --dry-run        Print what would happen without making any changes
                   (works with --sync, --clone-only, --pull-only)
  --conf FILE      Use a specific config file
  --base DIR       Fallback base dir for entries with no [path] section
                   (default: ~/git-seed-repos)
  --help           Show this message
```

### Composition

Frontend commands are designed to compose with other shell tools:

```bash
cd "$(git-seed --pick)"
cd "$(git-seed --browse)"
$EDITOR "$(git-seed --where pdbeard/intermcli)"
git-seed --dirty | xargs -I{} git -C {} status -s
git-seed --recent 5
```

## Authentication

git-seed uses authentication in the following order:

1. `GITHUB_TOKEN` environment variable
2. `gh` CLI (`gh auth login`)
3. No auth (public repos only)

## Requirements

- bash 4.3+
- git
- `fzf` (optional, used by `--pick`, `--browse`, `--open`, and `--scout` for richer interactive UI; everything degrades to numbered prompts without it)
- `gh` CLI (optional, required for `--list` and token auth)
