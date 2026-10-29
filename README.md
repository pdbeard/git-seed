# git-seed

git-seed is a bash script that keeps a set of GitHub repositories on your computer
up to date. You list the repositories in a config file. git-seed clones the missing
repositories and pulls the cloned repositories. It also finds repositories that are
not in the list.

## Terms

This document uses these terms:

| Term | Meaning |
|---|---|
| repo | A GitHub repository. |
| config file | The file `repos.conf`. It lists your repos. |
| entry | A line in the config file that names a repo. |
| listed repo | A repo that has an entry in the config file. |
| unlisted repo | A git repo in a base directory that has no entry in the config file. `--scout` finds these repos. |
| base directory | The directory that a `[path]` section sets. |
| label | The first field of an entry. It is a subdirectory of the base directory. |
| clone | The local copy of a repo. |

## Install git-seed

1. Clone git-seed:

   ```bash
   git clone https://github.com/pdbeard/git-seed.git ~/dev/git-seed
   ```

2. Optional: put git-seed on your PATH:

   ```bash
   ln -s ~/dev/git-seed/git-seed ~/.local/bin/git-seed
   ```

## Make the config file

1. Make the config directory, and copy the example config file into it:

   ```bash
   mkdir -p ~/.config/git-seed
   cp repos.conf.example ~/.config/git-seed/repos.conf
   ```

2. Edit `~/.config/git-seed/repos.conf`. Add one entry for each repo.

### Config file format

```
[path ~/projects]
personal      youruser/your-repo
work          yourorg/their-repo

[path ~/src]
libs          someuser/a-library
```

A `[path DIR]` section sets the base directory for the entries below it. Each entry
has two fields: a label and `owner/repo`. git-seed clones the repo to
`<base directory>/<label>/<repo name>`. For example, the first entry above clones to
`~/projects/personal/your-repo`.

Entries above all `[path]` sections use the fallback base directory. git-seed uses
`--base DIR`, then `$BASE_DIR`, then `~/git-seed-repos`.

Rules:

- A base directory must be an absolute path, or start with `~/`.
- A line that starts with `[` must be a `[path DIR]` section. For other lines that
  start with `[`, git-seed stops with an error. A typo in a section header then
  cannot put entries in the wrong base directory.
- git-seed ignores lines that start with `#`. It also ignores the text after a `#`
  on an entry line. You can use this to add notes:

  ```
  personal      youruser/your-repo   # main project
  ```

### Config file location

git-seed uses the first config file that it finds, in this order:

1. `--conf FILE`
2. The `$CONF_FILE` environment variable
3. `~/.config/git-seed/repos.conf` (or `$XDG_CONFIG_HOME/git-seed/repos.conf`)
4. `<script directory>/repos.conf`

## Usage

```
git-seed <command> [options]

Config commands:
  --sync           Clone missing repos and pull cloned repos (fast-forward
                   only). Exit with status 1 if a repo does not sync.
  --clone-only     Clone missing repos. Do not pull cloned repos.
  --pull-only      Pull cloned repos. Do not clone missing repos.
  --scout          Find repos in the base directories that are not in the
                   config file, and ask which to add. Use fzf if installed.
  --status         Show the state of each repo in the config file.
  --list           List your GitHub repos with the gh CLI. Each output line
                   is ready to paste into the config file.

Path commands:
  --browse         Select a repo in fzf, with a preview. Print its path.
  --where <repo>   Print the path of a repo. Give owner/repo, or only the
                   repo name if no other listed repo has that name.
  --recent [N]     Print the paths of the N repos with the newest commits
                   (default 20).
  --mine           Use with --recent: count only commits by your git
                   user.email.
  --dirty          Print the paths of repos with uncommitted changes.
  --outdated       Print the paths of repos whose remote has commits that you
                   did not pull. Connect to each remote. Print a summary
                   on stderr.
  --open [editor]  Select a repo as --browse does, then open it in the
                   editor. Default: $EDITOR, then code, then vim.

Options:
  --dry-run        Show the changes, but do not make them. Use with --sync,
                   --clone-only or --pull-only.
  --dir <label>    Label for the --list output (default: projects).
  --conf FILE      Use this config file.
  --base DIR       Base directory for entries above all [path] sections
                   (default: ~/git-seed-repos).
  --version        Print the version.
  --help           Show this help.
```

Some options work only with the commands that they name: `--dry-run`, `--dir` and
`--mine`. With a different command, git-seed stops with an error. For example,
`git-seed --status --dry-run` causes an error. Two commands together, for example
`--sync --status`, also cause an error.

### Use git-seed with other shell tools

The path commands print paths, one path on each line. You can give these paths to
other shell tools:

```bash
cd "$(git-seed --browse)"
$EDITOR "$(git-seed --where pdbeard/intermcli)"
git-seed --dirty | xargs -I{} git -C {} status -s
git-seed --recent 5
```

## Repo states

`--status` shows one of five states for each repo. git-seed examines the states in
this order, and it shows the first state that applies:

| State | Meaning |
|---|---|
| `MISSING` | The repo has no clone. The path does not exist, or it is an empty directory. `--sync` clones the repo. |
| `BROKEN` | The path contains something that is not a git repo. git-seed does not change it. |
| `DIRTY` | The working tree has uncommitted changes. |
| `AHEAD` | The working tree is clean, but some commits are not on the upstream branch. |
| `OK` | The repo is cloned and clean, and all commits are on the upstream branch. |

```
[OK]      pdbeard/alpha
[AHEAD]   pdbeard/beta                    2 unpushed
[DIRTY]   pdbeard/gamma                   1 change, 1 unpushed
[OK]      pdbeard/delta                   no upstream
[BROKEN]  pdbeard/epsilon                 not a git repo: /home/p/projects/epsilon
[MISSING] pdbeard/zeta

  cloned: 4  missing: 1  broken: 1  dirty: 1  ahead: 1
```

For a `DIRTY` repo, the detail column also shows the number of unpushed commits.
The more urgent state does not hide this number.

`--status` does not connect to a remote. It does not show the commits that other
people pushed. To find these commits, use `--outdated`.

### `--outdated`

```bash
git-seed --outdated                                          # list the repos to pull
git-seed --outdated | xargs -I{} git -C {} pull --ff-only    # pull them
```

`--outdated` asks the remote of each repo if the upstream branch has commits that
you do not have. It connects to the network, but it does not change your clones. It
does not update the remote-tracking refs, so the `--status` output stays the same.
`--outdated` skips repos that have no upstream branch.

## Authentication

git-seed uses the first of these that is available:

1. The `GITHUB_TOKEN` environment variable
2. The token of the `gh` CLI (from `gh auth login`)
3. No authentication. git-seed can then clone only public repos.

git-seed gives the token only to `https://github.com`. It never gives the token to a
remote on a different host. On github.com, the token has priority over other
credential helpers, for example a keychain.

## Requirements

- bash 4.3 or later. On an earlier version, git-seed stops with an error. macOS has
  bash 3.2 as `/bin/bash`. To install a newer bash, run `brew install bash`.
- git.
- `fzf` (optional). `--browse`, `--open` and `--scout` use fzf if it is installed.
  If fzf is not installed, these commands show numbered prompts.
- `gh` CLI (optional). `--list` needs it. git-seed can also get a token from it.

## Known limitations

- **Token visibility.** git-seed gives the token to git in a
  `git -c credential...helper=...` argument. For a short time, other users on the
  same computer can see this argument in the process list. On a personal computer,
  this is acceptable. On a shared computer, do not give git-seed a token: unset
  `GITHUB_TOKEN`, and do not log in to `gh`. Without a token, git-seed cannot clone
  private repos. Clone them yourself with SSH. git-seed then pulls them.
- **One git process at a time.** `--status`, `--dirty` and `--recent` run git one
  time for each repo, one repo after the other. This is fast enough for interactive
  use, but it is slower with many repos. `--outdated` also connects to the network
  one time for each repo. For this reason, it is a separate command and not a part
  of `--status`.
- **Tabs and newlines in paths.** A repo path that contains a tab or a newline makes
  the tab-separated output incorrect. git-seed does not escape these characters.
- **Spaces in labels.** Whitespace separates the fields of an entry, so a label
  cannot contain a space, for example `my stuff`. `--scout` does not add such
  directories. It shows a warning.

## Development

```bash
bats tests/          # run the tests
shellcheck git-seed  # examine the script for problems
```

CI runs both on each push and each pull request.

## License

MIT. See [LICENSE](LICENSE).
