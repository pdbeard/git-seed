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

Lines beginning with `#` are ignored, as is anything after a `#` on an entry line —
so entries can be annotated:

```
personal      youruser/your-repo   # main project
```

Config file is looked up in this order:

1. `--conf FILE`
2. `$CONF_FILE` environment variable
3. `~/.config/git-seed/repos.conf` (or `$XDG_CONFIG_HOME/git-seed/repos.conf`)
4. `<script dir>/repos.conf`

The fallback base directory for entries above any `[path]` section is `--base DIR`,
then `$BASE_DIR`, then `~/git-seed-repos`.

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
  --browse         fzf picker with preview (commits, status, README).
                   Prints selected path on stdout.
  --where <repo>   Look up the local path for owner/repo (or basename).
                   Prints path on stdout.
  --recent [N]     List N most-recently-committed tracked repos (default 20).
  --dirty          List tracked repos with uncommitted changes.
  --outdated       Check each remote for commits you have not pulled.
                   Requires network access. Prints one path per repo
                   that needs a pull; summary goes to stderr.
  --open [editor]  Run --browse, then open the selection in editor.
                   Editor defaults: $EDITOR, then code, then vim.

Options:
  --dry-run        Print what would happen without making any changes
                   (works with --sync, --clone-only, --pull-only)
  --conf FILE      Use a specific config file
  --base DIR       Fallback base dir for entries with no [path] section
                   (default: ~/git-seed-repos)
  --version        Print the version and exit
  --help           Show this message
```

Options apply only to the commands they belong to. `git-seed --status --dry-run`
is an error, not a silent no-op, and two commands in one invocation
(`--sync --status`) is also an error.

### Composition

Frontend commands are designed to compose with other shell tools:

```bash
cd "$(git-seed --browse)"
$EDITOR "$(git-seed --where pdbeard/intermcli)"
git-seed --dirty | xargs -I{} git -C {} status -s
git-seed --recent 5
```

## Repo states

`--status` reports one of five mutually exclusive states per repo, checked in
this order:

| State | Meaning |
|---|---|
| `MISSING` | No clone. The path is absent, or present but empty. `--sync` will fix it. |
| `BROKEN` | The path is occupied by something that is not a git repo. git-seed will not touch it. |
| `DIRTY` | Uncommitted changes in the working tree. |
| `AHEAD` | Tree is clean, but commits are not yet pushed to the upstream. |
| `OK` | Cloned, clean, nothing unpushed. |

```
[OK]      pdbeard/alpha
[AHEAD]   pdbeard/beta                    2 unpushed
[DIRTY]   pdbeard/gamma                   1 change, 1 unpushed
[OK]      pdbeard/delta                   no upstream
[BROKEN]  pdbeard/epsilon                 not a git repo: /home/p/projects/epsilon
[MISSING] pdbeard/zeta

  cloned: 4  missing: 1  broken: 1  dirty: 1  ahead: 1
```

Unpushed commits are shown for `DIRTY` repos too, in the detail column, so the
count is never hidden behind the more urgent state.

`--status` is entirely local and offline. It never contacts a remote, so it
says nothing about commits other people have pushed. For that, use
`--outdated`.

### `--outdated`

```bash
git-seed --outdated                                # list repos needing a pull
git-seed --outdated | xargs -I{} git -C {} pull    # pull them
```

Asks each remote directly whether the tracked branch has commits you do not
have. It contacts the network but does not modify anything — remote-tracking
refs are left alone, so `--status` output is unaffected. Repos with no
configured upstream are skipped, since there is nothing for them to be behind.

## Authentication

git-seed uses authentication in the following order:

1. `GITHUB_TOKEN` environment variable
2. `gh` CLI (`gh auth login`)
3. No auth (public repos only)

## Requirements

- bash 4.3+ (enforced at startup; macOS ships 3.2 as `/bin/bash` — `brew install bash`)
- git
- `fzf` (optional, used by `--browse`, `--open`, and `--scout` for richer interactive UI; everything degrades to numbered prompts without it)
- `gh` CLI (optional, required for `--list` and token auth)

## Known limitations

- **Token visibility.** Cloning a private repo passes the token through a
  `git -c credential.helper=...` argument, which is briefly visible in the process
  list to other users on the same machine. This is acceptable on a personal machine;
  on a shared host, clone over SSH remotes instead.
- **Serial git calls.** `--status`, `--dirty`, and `--recent` invoke git once per
  repo, sequentially. Fine interactively; noticeable on large manifests.
  `--outdated` additionally makes one network round trip per repo, which is why
  it is a separate command rather than part of `--status`.
- **Tabs and newlines in paths.** Repo paths containing either will corrupt
  tab-delimited output. Not escaped.

## Development

```bash
bats tests/          # run the test suite
shellcheck git-seed  # lint
```

Both run in CI on push and pull request.

## License

MIT — see [LICENSE](LICENSE).
