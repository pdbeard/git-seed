#!/usr/bin/env bats

SEED="$BATS_TEST_DIRNAME/../git-seed"

# ── Helpers ───────────────────────────────────────────────────────────

_make_repo() {
    local path="$1" remote="$2" msg="${3:-init}"
    mkdir -p "$path"
    git -C "$path" init -q
    git -C "$path" remote add origin "$remote"
    echo "# $(basename "$path")" > "$path/README.md"
    git -C "$path" add .
    git -C "$path" commit -qm "$msg"
}

# Gives a repo a local bare origin and makes its branch track it, so it has
# an upstream to pull from. Prints the bare repo's path.
_track_upstream() {
    local path="$1" bare="$SANDBOX/$(basename "$1").git"
    git clone -q --bare "$path" "$bare"
    git -C "$path" remote set-url origin "file://$bare"
    git -C "$path" fetch -q origin
    git -C "$path" branch -q -u "origin/$(git -C "$path" branch --show-current)"
    printf "%s\n" "$bare"
}

setup() {
    SANDBOX=$(mktemp -d)
    REPO_BASE="$SANDBOX/repos"
    CONF="$SANDBOX/repos.conf"

    # Tests must not depend on the developer's git config (identity, commit
    # signing, default branch), so every git call gets a known one.
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
    git config --global user.email test@test.com
    git config --global user.name Test
    git config --global commit.gpgsign false
    git config --global init.defaultBranch main

    # Repos in manifest
    _make_repo "$REPO_BASE/personal/alpha" "https://github.com/pdbeard/alpha.git"
    _make_repo "$REPO_BASE/work/beta"      "https://github.com/testorg/beta.git"

    # beta is dirty
    echo "dirty" >> "$REPO_BASE/work/beta/README.md"

    # Untracked repo (not in conf, for --scout)
    _make_repo "$REPO_BASE/personal/untracked" "https://github.com/pdbeard/untracked.git"

    cat > "$CONF" <<EOF
[path $REPO_BASE]
personal  pdbeard/alpha
work      testorg/beta
EOF

    # Mock fzf: reads stdin, behaviour controlled by FZF_MOCK env var.
    #   select-first (default) — returns first line, exits 0
    #   select-all             — returns all lines, exits 0
    #   cancel                 — exits 1 (simulates Esc)
    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/fzf" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
case "${FZF_MOCK:-select-first}" in
    cancel)     exit 1 ;;
    select-all) printf "%s\n" "$input" ;;
    *)          printf "%s\n" "$input" | head -1 ;;
esac
EOF
    chmod +x "$SANDBOX/bin/fzf"

    # Tests that pin PATH to system dirs would otherwise resolve
    # /usr/bin/env bash to macOS's bash 3.2, which git-seed refuses to run
    # under. Keep a 4.3+ bash reachable from the sandbox.
    ln -sf "$(command -v bash)" "$SANDBOX/bin/bash"
    # /bin has no dirname, which git-seed needs before it does anything else.
    ln -sf "$(command -v dirname)" "$SANDBOX/bin/dirname"

    export PATH="$SANDBOX/bin:$PATH"
    export CONF SANDBOX REPO_BASE
}

teardown() {
    rm -rf "$SANDBOX"
}

# ── --help / no args ──────────────────────────────────────────────────

@test "no args prints usage, exits 0" {
    run "$SEED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "--help prints usage, exits 0" {
    run "$SEED" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"--browse"* ]]
    [[ "$output" == *"--scout"* ]]
}

@test "unknown option exits 1 with error" {
    run "$SEED" --conf "$CONF" --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option"* ]]
}

# ── --conf / --base ───────────────────────────────────────────────────

@test "--conf with missing file exits 1" {
    run "$SEED" --conf /no/such/file --status
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}

@test "--conf requires an argument" {
    run "$SEED" --conf --status
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires a file argument"* ]]
}

# ── conf entry sanitisation ───────────────────────────────────────────

@test "trailing slash on repo entry is stripped and resolves correctly" {
    # Write a conf entry with a trailing slash on the repo name
    printf "[path %s]\npersonal  pdbeard/alpha/\n" "$REPO_BASE" > "$SANDBOX/slash.conf"
    run "$SEED" --conf "$SANDBOX/slash.conf" --where pdbeard/alpha
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_BASE/personal/alpha" ]
}

@test "trailing whitespace on repo entry is stripped and resolves correctly" {
    printf "[path %s]\npersonal  pdbeard/alpha   \n" "$REPO_BASE" > "$SANDBOX/ws.conf"
    run "$SEED" --conf "$SANDBOX/ws.conf" --where pdbeard/alpha
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_BASE/personal/alpha" ]
}

# ── --status ──────────────────────────────────────────────────────────

@test "--status shows OK for clean repo" {
    run "$SEED" --conf "$CONF" --status
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK]"*"alpha"* ]]
}

@test "--status shows DIRTY for modified repo" {
    run "$SEED" --conf "$CONF" --status
    [[ "$output" == *"[DIRTY]"*"beta"* ]]
}

@test "--status shows DIRTY for repo with untracked files only" {
    echo "untracked" > "$REPO_BASE/personal/alpha/newfile.txt"
    run "$SEED" --conf "$CONF" --status
    [[ "$output" == *"[DIRTY]"*"alpha"* ]]
}

@test "--status shows MISSING for absent repo" {
    rm -rf "$REPO_BASE/personal/alpha"
    run "$SEED" --conf "$CONF" --status
    [[ "$output" == *"[MISSING]"*"alpha"* ]]
}

@test "--status prints summary line with counts" {
    run "$SEED" --conf "$CONF" --status
    [[ "$output" == *"cloned:"*"missing:"*"dirty:"* ]]
}

# ── --where ───────────────────────────────────────────────────────────

@test "--where resolves exact owner/repo" {
    run "$SEED" --conf "$CONF" --where pdbeard/alpha
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_BASE/personal/alpha" ]
}

@test "--where resolves by basename" {
    run "$SEED" --conf "$CONF" --where alpha
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_BASE/personal/alpha" ]
}

@test "--where refuses an ambiguous repo name and lists the matches" {
    _make_repo "$REPO_BASE/work/alpha" "https://github.com/testorg/alpha.git"
    echo "work  testorg/alpha" >> "$CONF"
    run "$SEED" --conf "$CONF" --where alpha
    [ "$status" -eq 1 ]
    [[ "$output" == *"several repos"*"personal/alpha"*"work/alpha"* ]]
}

@test "--where exits 1 for unknown repo" {
    run "$SEED" --conf "$CONF" --where nobody/nosuchrepo
    [ "$status" -eq 1 ]
    [[ "$output" == *"No manifest entry"* ]]
}

@test "--where requires an argument" {
    run "$SEED" --conf "$CONF" --where
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires a repo argument"* ]]
}

# ── --dirty ───────────────────────────────────────────────────────────

@test "--dirty lists dirty repo paths" {
    run "$SEED" --conf "$CONF" --dirty
    [ "$status" -eq 0 ]
    [[ "$output" == *"$REPO_BASE/work/beta"* ]]
}

@test "--dirty does not list clean repos" {
    run "$SEED" --conf "$CONF" --dirty
    [[ "$output" != *"alpha"* ]]
}

@test "--dirty is empty when all repos are clean" {
    git -C "$REPO_BASE/work/beta" checkout -- .
    run "$SEED" --conf "$CONF" --dirty
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── --recent ──────────────────────────────────────────────────────────

@test "--recent lists cloned repo paths" {
    run "$SEED" --conf "$CONF" --recent
    [ "$status" -eq 0 ]
    [[ "$output" == *"$REPO_BASE"* ]]
}

@test "--recent respects N limit" {
    run "$SEED" --conf "$CONF" --recent 1
    [ "$status" -eq 0 ]
    [ "$(printf "%s\n" "$output" | grep -c .)" -eq 1 ]
}

@test "--recent exits 1 for non-integer N" {
    run "$SEED" --conf "$CONF" --recent abc
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive integer"* ]]
}

@test "--recent rejects 0" {
    run "$SEED" --conf "$CONF" --recent 0
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive integer"* ]]
}

@test "--recent --mine filters to repos with commits by git user.email" {
    # alpha's newest commit is someone else's; beta's newest is ours.
    GIT_COMMITTER_DATE="@4000000000 +0000" git -C "$REPO_BASE/personal/alpha" \
        -c user.email=other@test.com commit -q --allow-empty -m theirs
    GIT_COMMITTER_DATE="@3900000000 +0000" git -C "$REPO_BASE/work/beta" \
        commit -q --allow-empty -m mine

    run "$SEED" --conf "$CONF" --recent 1
    [[ "$output" == *"/alpha" ]]
    run "$SEED" --conf "$CONF" --recent 1 --mine
    [ "$status" -eq 0 ]
    [[ "$output" == *"/beta" ]]
}

@test "--recent --mine exits 1 when git user.email is not configured" {
    run env GIT_CONFIG_GLOBAL=/dev/null \
        "$SEED" --conf "$CONF" --recent --mine
    [ "$status" -eq 1 ]
    [[ "$output" == *"user.email"* ]]
}

# ── --browse ──────────────────────────────────────────────────────────

@test "--browse returns a valid path" {
    run "$SEED" --conf "$CONF" --browse
    [ "$status" -eq 0 ]
    [[ "$output" == "$REPO_BASE"* ]]
    [ -d "$output" ]
}

@test "--browse exits 1 when selection is cancelled" {
    FZF_MOCK=cancel run "$SEED" --conf "$CONF" --browse
    [ "$status" -eq 1 ]
}

# ── --open ────────────────────────────────────────────────────────────

@test "--open execs the given editor with the selected path" {
    # Create a mock editor that echoes its argument to stdout.
    # exec in git-seed replaces the git-seed process, so the mock's
    # stdout is captured by bats' run.
    cat > "$SANDBOX/bin/mock-editor" <<'EOF'
#!/usr/bin/env bash
echo "opened:$1"
EOF
    chmod +x "$SANDBOX/bin/mock-editor"

    run "$SEED" --conf "$CONF" --open "$SANDBOX/bin/mock-editor"
    [ "$status" -eq 0 ]
    [[ "$output" == "opened:"* ]]
    local opened="${output#opened:}"
    [ -d "$opened" ]
}

@test "--open accepts an EDITOR that carries flags" {
    cat > "$SANDBOX/bin/mock-editor" <<'EOF'
#!/usr/bin/env bash
echo "args:$*"
EOF
    chmod +x "$SANDBOX/bin/mock-editor"
    EDITOR="mock-editor --wait" run "$SEED" --conf "$CONF" --open
    [ "$status" -eq 0 ]
    [[ "$output" == "args:--wait $REPO_BASE/"* ]]
}

@test "--open exits 1 when no editor found and EDITOR unset" {
    # /bin contains bash but not vim or code; /usr/bin/env can find bash via /bin.
    # Stripping homebrew and /usr/bin ensures no vim or code fallback is found.
    run env PATH="$SANDBOX/bin:/bin" HOME="$HOME" CONF="$CONF" \
        "$SEED" --conf "$CONF" --open
    [ "$status" -eq 1 ]
    [[ "$output" == *"No editor found"* ]]
}

# ── --sync / --clone-only / --pull-only ───────────────────────────────

@test "--sync --dry-run prints DRY lines without modifying files" {
    echo "personal  pdbeard/ghost" >> "$CONF"
    run "$SEED" --conf "$CONF" --sync --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY]"*"would clone pdbeard/ghost"* ]]
    [ ! -e "$REPO_BASE/personal/ghost" ]
}

@test "--sync --dry-run suppresses browse hint" {
    run "$SEED" --conf "$CONF" --sync --dry-run
    [[ "$output" != *"--browse"* ]]
}

@test "--clone-only hints about --browse on completion" {
    run "$SEED" --conf "$CONF" --clone-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"--browse"* ]]
}

@test "--pull-only hints about --browse on completion" {
    run "$SEED" --conf "$CONF" --pull-only
    [[ "$output" == *"--browse"* ]]
}

@test "--clone-only skips repos that already exist" {
    run "$SEED" --conf "$CONF" --clone-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SKIP]"* ]]
}

@test "--pull-only skips repos that are not cloned" {
    rm -rf "$REPO_BASE/personal/alpha"
    run "$SEED" --conf "$CONF" --pull-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SKIP]"*"alpha"* ]]
}

@test "--sync pulls an existing repo" {
    # Create a bare remote from alpha, add a commit via a temp clone, then
    # point alpha's origin at the bare so --pull-only can fetch it.
    local bare upstream="$SANDBOX/upstream-alpha"
    bare="$(_track_upstream "$REPO_BASE/personal/alpha")"
    git clone -q "file://$bare" "$upstream"
    git -C "$upstream" commit -qm "upstream change" --allow-empty
    git -C "$upstream" push -q origin HEAD

    run "$SEED" --conf "$CONF" --pull-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"[PULL]"*"alpha"* ]]
    [ "$(git -C "$REPO_BASE/personal/alpha" log -1 --format=%s)" = "upstream change" ]
}

@test "--sync skips a repo with no upstream instead of failing" {
    run "$SEED" --conf "$CONF" --pull-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SKIP]"*"testorg/beta"*"no upstream"* ]]
}

@test "--sync skips repo on detached HEAD instead of erroring" {
    git -C "$REPO_BASE/personal/alpha" checkout -q \
        "$(git -C "$REPO_BASE/personal/alpha" rev-parse HEAD)"
    run "$SEED" --conf "$CONF" --pull-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SKIP]"*"alpha"* ]]
    [[ "$output" == *"detached HEAD"* ]]
}

@test "--sync --dry-run also skips a detached HEAD instead of promising a pull" {
    git -C "$REPO_BASE/personal/alpha" checkout -q \
        "$(git -C "$REPO_BASE/personal/alpha" rev-parse HEAD)"
    run "$SEED" --conf "$CONF" --pull-only --dry-run
    [[ "$output" == *"[SKIP]"*"alpha"*"detached HEAD"* ]]
    [[ "$output" != *"would pull pdbeard/alpha"* ]]
}

@test "--sync refuses a non-fast-forward pull and exits 1" {
    local upstream
    upstream="$(_track_upstream "$REPO_BASE/personal/alpha")"
    git clone -q "$upstream" "$SANDBOX/other"
    git -C "$SANDBOX/other" commit -q --allow-empty -m theirs
    git -C "$SANDBOX/other" push -q
    git -C "$REPO_BASE/personal/alpha" commit -q --allow-empty -m mine
    # pull.rebase=false would merge here; --ff-only must still refuse.
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=pull.rebase GIT_CONFIG_VALUE_0=false \
        run "$SEED" --conf "$CONF" --pull-only
    [ "$status" -eq 1 ]
    [ ! -f "$REPO_BASE/personal/alpha/.git/MERGE_HEAD" ]
}

@test "--sync tracks error count and warns when a pull fails" {
    # Point alpha's origin at a non-existent path so pull fails
    _track_upstream "$REPO_BASE/personal/alpha" >/dev/null
    git -C "$REPO_BASE/personal/alpha" remote set-url origin "file:///nonexistent"
    run "$SEED" --conf "$CONF" --pull-only
    [ "$status" -eq 1 ]
    [[ "$output" == *"[WARN]"*"failed to sync"* ]]
}

# ── --scout ───────────────────────────────────────────────────────────

@test "--scout finds untracked repos" {
    run "$SEED" --conf "$CONF" --scout
    [ "$status" -eq 0 ]
    [[ "$output" == *"untracked"* ]]
}

@test "--scout adds selected repo to conf" {
    run "$SEED" --conf "$CONF" --scout
    grep -q "untracked" "$CONF"
}

@test "--scout reports all-tracked when nothing new" {
    echo "personal  pdbeard/untracked" >> "$CONF"
    run "$SEED" --conf "$CONF" --scout
    [ "$status" -eq 0 ]
    [[ "$output" == *"All repos are already tracked"* ]]
}

@test "--scout cancel adds nothing to conf" {
    FZF_MOCK=cancel run "$SEED" --conf "$CONF" --scout
    [ "$status" -eq 0 ]
    ! grep -q "untracked" "$CONF"
}

@test "--scout hints about --browse after adding" {
    run "$SEED" --conf "$CONF" --scout
    [[ "$output" == *"--browse"* ]]
}

@test "--scout inserts under a header that has an inline comment and trailing space" {
    printf '# [path %s]\n[path %s]   # mine\npersonal  pdbeard/alpha\n' \
        "$REPO_BASE" "$REPO_BASE" > "$CONF"
    run "$SEED" --conf "$CONF" --scout
    [ "$status" -eq 0 ]
    [ "$(sed -n 4p "$CONF")" = "personal  pdbeard/untracked" ]
    [ "$(grep -c '^\[path' "$CONF")" -eq 1 ]
}

@test "--scout appends a new section when no header matches" {
    printf 'personal  pdbeard/alpha\n' > "$CONF"
    _make_repo "$SANDBOX/elsewhere/x/new" "https://github.com/me/new.git"
    run "$SEED" --conf "$CONF" --base "$SANDBOX/elsewhere" --scout
    [ "$status" -eq 0 ]
    grep -q "^x  me/new$" "$CONF"
}

@test "--scout writes through a symlinked conf" {
    mv "$CONF" "$SANDBOX/real.conf"
    ln -s "$SANDBOX/real.conf" "$CONF"
    run "$SEED" --conf "$CONF" --scout
    [ "$status" -eq 0 ]
    [ -L "$CONF" ]
    grep -q "pdbeard/untracked" "$SANDBOX/real.conf"
}

@test "--scout keeps dots in repo names" {
    rm -rf "$REPO_BASE/personal/untracked"
    _make_repo "$REPO_BASE/personal/site.github.io" "git@github.com:pdbeard/site.github.io.git"
    run "$SEED" --conf "$CONF" --scout
    grep -q "^personal  pdbeard/site.github.io$" "$CONF"
    run "$SEED" --conf "$CONF" --status
    [[ "$output" != *"malformed"* ]]
    [[ "$output" == *"[OK]"*"pdbeard/site.github.io"* ]]
}

@test "--scout skips a clone whose folder name differs from the repo name" {
    rm -rf "$REPO_BASE/personal/untracked"
    _make_repo "$REPO_BASE/personal/old-name" "https://github.com/pdbeard/realname.git"
    run "$SEED" --conf "$CONF" --scout
    [[ "$output" == *"folder name differs"* ]]
    ! grep -q "realname" "$CONF"
}

@test "--scout skips repos without a GitHub origin" {
    rm -rf "$REPO_BASE/personal/untracked"
    _make_repo "$REPO_BASE/personal/other" "https://gitlab.com/someone/other.git"
    run "$SEED" --conf "$CONF" --scout
    [[ "$output" == *"not a GitHub repo"* ]]
    ! grep -q "other" "$CONF"
}

# ── --list ────────────────────────────────────────────────────────────

@test "--list exits 1 when gh is not on PATH" {
    # Restrict PATH to basic Unix dirs + sandbox; gh lives in homebrew so it
    # won't be found, exercising the "gh not installed" error branch.
    run env PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$HOME" CONF="$CONF" \
        "$SEED" --conf "$CONF" --list
    [ "$status" -eq 1 ]
    [[ "$output" == *"gh"* ]]
}

@test "--list --dir uses custom directory label in output" {
    # Create a mock gh that returns a known repo
    cat > "$SANDBOX/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "pdbeard/testrepo"
EOF
    chmod +x "$SANDBOX/bin/gh"

    run "$SEED" --conf "$CONF" --list --dir work
    [ "$status" -eq 0 ]
    [[ "$output" == *"work  pdbeard/testrepo"* ]]
}

@test "--list defaults to 'projects' as directory label" {
    cat > "$SANDBOX/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "pdbeard/testrepo"
EOF
    chmod +x "$SANDBOX/bin/gh"

    run "$SEED" --conf "$CONF" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"projects  pdbeard/testrepo"* ]]
}

# ── Manifest parsing edge cases ───────────────────────────────────────

@test "inline comment is stripped from repo entry" {
    echo "extra  pdbeard/gamma  # annotated" >> "$CONF"
    run "$SEED" --conf "$CONF" --sync --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would clone pdbeard/gamma"* ]]
    [[ "$output" != *"annotated"* ]]
}

@test "inline comment does not leak into the clone path" {
    echo "extra  pdbeard/gamma  # annotated" >> "$CONF"
    run "$SEED" --conf "$CONF" --sync --dry-run
    [[ "$output" == *"/extra/gamma"* ]]
}

@test "inline comment on a [path] section is stripped" {
    cat > "$CONF" <<EOF
[path $REPO_BASE]  # where things live
personal  pdbeard/alpha
EOF
    run "$SEED" --conf "$CONF" --status
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK]"* ]]
}

@test "multiple trailing slashes are stripped from repo entry" {
    cat > "$CONF" <<EOF
[path $REPO_BASE]
personal  pdbeard/alpha//
EOF
    run "$SEED" --conf "$CONF" --status
    [[ "$output" == *"[OK]      pdbeard/alpha"* ]]
}

@test "extra fields in an entry produce a warning" {
    echo "extra  pdbeard/gamma  stray" >> "$CONF"
    run "$SEED" --conf "$CONF" --status
    [[ "$output" == *"Ignoring extra fields"* ]]
}

@test "--scout does not re-offer a repo whose conf entry has an inline comment" {
    echo "personal  pdbeard/untracked  # already tracked" >> "$CONF"
    run "$SEED" --conf "$CONF" --scout
    [ "$status" -eq 0 ]
    [[ "$output" == *"All repos are already tracked"* ]]
}

# ── Argument validation ───────────────────────────────────────────────

@test "--base requires an argument" {
    run "$SEED" --base
    [ "$status" -eq 1 ]
    [[ "$output" == *"--base requires a directory argument"* ]]
}

@test "conflicting commands exit 1" {
    run "$SEED" --conf "$CONF" --sync --status
    [ "$status" -eq 1 ]
    [[ "$output" == *"Conflicting commands"* ]]
}

@test "repeating the same command is not a conflict" {
    run "$SEED" --conf "$CONF" --status --status
    [ "$status" -eq 0 ]
}

@test "--mine outside --recent exits 1" {
    run "$SEED" --conf "$CONF" --status --mine
    [ "$status" -eq 1 ]
    [[ "$output" == *"--mine only applies to --recent"* ]]
}

@test "--dir outside --list exits 1" {
    run "$SEED" --conf "$CONF" --status --dir work
    [ "$status" -eq 1 ]
    [[ "$output" == *"--dir only applies to --list"* ]]
}

@test "--dry-run outside the sync family exits 1" {
    run "$SEED" --conf "$CONF" --status --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" == *"--dry-run only applies"* ]]
}

@test "--version prints a version string" {
    run "$SEED" --version
    [ "$status" -eq 0 ]
    [[ "$output" == git-seed\ * ]]
}

# ── Repo states: BROKEN / AHEAD / detail column ───────────────────────

_make_upstream_repo() {
    # Creates a bare origin plus a clone with a real tracking branch.
    local origin="$1" clone="$2"
    git init -q --bare "$origin"
    git clone -q "$origin" "$clone" 2>/dev/null
    git -C "$clone" commit -q --allow-empty -m base
    git -C "$clone" push -q origin HEAD:refs/heads/main
    git -C "$clone" checkout -q -B main
    git -C "$clone" branch -q --set-upstream-to=origin/main main
}

@test "--status reports BROKEN for a non-empty directory that is not a repo" {
    mkdir -p "$REPO_BASE/work/notrepo"
    echo hello > "$REPO_BASE/work/notrepo/file.txt"
    echo "work  x/notrepo" >> "$CONF"
    run "$SEED" --conf "$CONF" --status
    [[ "$output" == *"[BROKEN]"* ]]
    [[ "$output" == *"not a git repo"* ]]
    [[ "$output" == *"broken: 1"* ]]
}

@test "--status reports a plain file at the clone path as BROKEN" {
    mkdir -p "$REPO_BASE/personal"
    echo "notes" > "$REPO_BASE/personal/gamma"
    echo "personal  pdbeard/gamma" >> "$CONF"
    run "$SEED" --conf "$CONF" --status
    [[ "$output" == *"[BROKEN]"*"pdbeard/gamma"* ]]
}

@test "--status reports an empty directory as MISSING, not BROKEN" {
    mkdir -p "$REPO_BASE/work/emptydir"
    echo "work  x/emptydir" >> "$CONF"
    run "$SEED" --conf "$CONF" --status
    [[ "$output" == *"[MISSING] x/emptydir"* ]]
    [[ "$output" != *"[BROKEN]"* ]]
}

@test "--sync refuses to touch a path that is not a git repo" {
    mkdir -p "$REPO_BASE/work/notrepo"
    echo hello > "$REPO_BASE/work/notrepo/file.txt"
    echo "work  x/notrepo" >> "$CONF"
    run "$SEED" --conf "$CONF" --sync
    [[ "$output" == *"path exists but is not a git repo"* ]]
    # The user's file must survive untouched.
    [ -f "$REPO_BASE/work/notrepo/file.txt" ]
}

@test "frontend commands skip broken directories" {
    mkdir -p "$REPO_BASE/work/notrepo"
    echo hello > "$REPO_BASE/work/notrepo/file.txt"
    echo "work  x/notrepo" >> "$CONF"
    run "$SEED" --conf "$CONF" --recent
    [[ "$output" != *"notrepo"* ]]
}

@test "--status reports AHEAD for a clean repo with unpushed commits" {
    _make_upstream_repo "$SANDBOX/origin.git" "$REPO_BASE/personal/ahead"
    git -C "$REPO_BASE/personal/ahead" commit -q --allow-empty -m unpushed
    echo "personal  x/ahead" >> "$CONF"
    run "$SEED" --conf "$CONF" --status
    [[ "$output" == *"[AHEAD]"* ]]
    [[ "$output" == *"1 unpushed"* ]]
    [[ "$output" == *"ahead: 1"* ]]
}

@test "a dirty repo with unpushed commits reports DIRTY plus both counts" {
    _make_upstream_repo "$SANDBOX/origin.git" "$REPO_BASE/personal/both"
    git -C "$REPO_BASE/personal/both" commit -q --allow-empty -m unpushed
    echo scratch > "$REPO_BASE/personal/both/untracked.txt"
    echo "personal  x/both" >> "$CONF"
    run "$SEED" --conf "$CONF" --status
    [[ "$output" == *"[DIRTY]"* ]]
    [[ "$output" == *"1 change, 1 unpushed"* ]]
}

@test "--status stays OK and notes when no upstream is configured" {
    run "$SEED" --conf "$CONF" --status
    [[ "$output" == *"[OK]"* ]]
    [[ "$output" == *"no upstream"* ]]
    [[ "$output" == *"ahead: 0"* ]]
}

@test "a pushed repo with nothing local reports OK with no detail" {
    _make_upstream_repo "$SANDBOX/origin.git" "$REPO_BASE/personal/clean"
    cat > "$CONF" <<EOF
[path $REPO_BASE]
personal  x/clean
EOF
    run "$SEED" --conf "$CONF" --status
    [[ "$output" == *"[OK]      x/clean"* ]]
    [[ "$output" != *"unpushed"* ]]
    [[ "$output" != *"no upstream"* ]]
}

# ── --outdated ────────────────────────────────────────────────────────

@test "--outdated is silent when the remote has nothing new" {
    _make_upstream_repo "$SANDBOX/origin.git" "$REPO_BASE/personal/up2date"
    cat > "$CONF" <<EOF
[path $REPO_BASE]
personal  x/up2date
EOF
    run "$SEED" --conf "$CONF" --outdated
    [ "$status" -eq 0 ]
    [[ "$output" != *"$REPO_BASE/personal/up2date"* ]]
    [[ "$output" == *"needing pull: 0"* ]]
}

@test "--outdated lists a repo whose remote has new commits" {
    _make_upstream_repo "$SANDBOX/origin.git" "$REPO_BASE/personal/behind"
    # Push a commit from a second clone so 'behind' has not seen it.
    git clone -q -b main "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null
    git -C "$SANDBOX/other" commit -q --allow-empty -m "upstream work"
    git -C "$SANDBOX/other" push -q origin HEAD:refs/heads/main
    cat > "$CONF" <<EOF
[path $REPO_BASE]
personal  x/behind
EOF
    run "$SEED" --conf "$CONF" --outdated
    [[ "$output" == *"$REPO_BASE/personal/behind"* ]]
    [[ "$output" == *"needing pull: 1"* ]]
}

@test "--outdated does not update remote-tracking refs" {
    _make_upstream_repo "$SANDBOX/origin.git" "$REPO_BASE/personal/behind"
    git clone -q -b main "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null
    git -C "$SANDBOX/other" commit -q --allow-empty -m "upstream work"
    git -C "$SANDBOX/other" push -q origin HEAD:refs/heads/main
    local before
    before="$(git -C "$REPO_BASE/personal/behind" rev-parse origin/main)"
    cat > "$CONF" <<EOF
[path $REPO_BASE]
personal  x/behind
EOF
    run "$SEED" --conf "$CONF" --outdated
    [ "$(git -C "$REPO_BASE/personal/behind" rev-parse origin/main)" = "$before" ]
}

@test "--outdated skips repos with no upstream" {
    run "$SEED" --conf "$CONF" --outdated
    [[ "$output" == *"no upstream: 2"* ]]
    [[ "$output" == *"checked: 0"* ]]
}

# ── Conf validation ───────────────────────────────────────────────────

@test "a mistyped section header is an error, not an entry" {
    printf '[path %s]\npersonal  pdbeard/alpha\n[Path %s/b]\nwork  testorg/beta\n' \
        "$REPO_BASE" "$SANDBOX" > "$CONF"
    run "$SEED" --conf "$CONF" --sync --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" == *"Bad section header"*"[Path"* ]]
    [[ "$output" != *"would"* ]]
}

@test "a relative [path] is an error" {
    printf '[path src]\nx  me/three\n' > "$CONF"
    run "$SEED" --conf "$CONF" --status
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be an absolute path"*"src"* ]]
}

@test "a relative --base is an error when entries use it" {
    printf 'x  me/three\n' > "$CONF"
    run "$SEED" --conf "$CONF" --base rel --status
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be an absolute path"*"rel"* ]]
}

@test "--outdated exits 1 when the conf is missing" {
    run "$SEED" --conf "$SANDBOX/nope.conf" --outdated
    [ "$status" -eq 1 ]
    [[ "$output" == *"Config file not found"* ]]
    [[ "$output" != *"checked:"* ]]
}

# ── Scout edge cases ──────────────────────────────────────────────────

@test "--scout skips a folder whose label contains a space" {
    rm -rf "$REPO_BASE/personal/untracked"
    _make_repo "$REPO_BASE/my stuff/tool" "https://github.com/me/tool.git"
    run "$SEED" --conf "$CONF" --scout
    [[ "$output" == *"contains whitespace"* ]]
    ! grep -q "me/tool" "$CONF"
}

@test "--scout files a repo under the most specific of nested sections, once" {
    printf '[path %s]\n[path %s/personal]\n' "$REPO_BASE" "$REPO_BASE" > "$CONF"
    rm -rf "$REPO_BASE/personal/untracked"
    _make_repo "$REPO_BASE/personal/x/deep" "https://github.com/me/deep.git"
    FZF_MOCK=select-all run "$SEED" --conf "$CONF" --scout
    [ "$(grep -c 'me/deep' "$CONF")" -eq 1 ]
    grep -q "^x  me/deep$" "$CONF"
}

@test "--scout treats an entry disabled with ## as known" {
    echo "## personal  pdbeard/untracked" >> "$CONF"
    run "$SEED" --conf "$CONF" --scout
    [[ "$output" == *"All repos are already tracked"* ]]
}

@test "--scout shortens a header to ~ only at a path boundary" {
    printf 'personal  pdbeard/alpha\n' > "$CONF"
    # HOME is a string prefix of REPO_BASE ($SANDBOX/re vs $SANDBOX/repos).
    HOME="$SANDBOX/re" run "$SEED" --conf "$CONF" --base "$REPO_BASE" --scout
    grep -qxF "[path $REPO_BASE]" "$CONF"
}

# ── Clone and auth ────────────────────────────────────────────────────

@test "--clone-only clones, offering the token to github.com only" {
    git clone -q --bare "$REPO_BASE/personal/alpha" "$SANDBOX/gh/pdbeard/fresh.git"
    printf '[path %s]\npersonal  pdbeard/fresh\n' "$REPO_BASE" > "$CONF"
    # Record every git invocation, then hand off to the real git.
    cat > "$SANDBOX/bin/git" <<WRAP
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX/git.log"
exec $(command -v git) "\$@"
WRAP
    chmod +x "$SANDBOX/bin/git"
    GITHUB_TOKEN=SECRET GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0="url.file://$SANDBOX/gh/.insteadOf" \
        GIT_CONFIG_VALUE_0="https://github.com/" \
        run "$SEED" --conf "$CONF" --clone-only
    [ "$status" -eq 0 ]
    [ -d "$REPO_BASE/personal/fresh/.git" ]
    grep -q "credential.https://github.com.helper=" "$SANDBOX/git.log"
    ! grep -q "credential.helper=" "$SANDBOX/git.log"
}

@test "--outdated skips a branch that tracks a local branch" {
    local base
    base="$(git -C "$REPO_BASE/personal/alpha" branch --show-current)"
    git -C "$REPO_BASE/personal/alpha" checkout -q -b feat
    git -C "$REPO_BASE/personal/alpha" branch -q -u "$base"
    printf '[path %s]\npersonal  pdbeard/alpha\n' "$REPO_BASE" > "$CONF"
    run "$SEED" --conf "$CONF" --outdated
    [ "$status" -eq 0 ]
    [[ "$output" != *"could not reach"* ]]
    [[ "$output" == *"no upstream: 1"* ]]
}

@test "an indented section header is still a header" {
    printf '[path %s]\npersonal  pdbeard/alpha\n  [path %s/b]\nwork  testorg/beta\n' \
        "$REPO_BASE" "$SANDBOX" > "$CONF"
    run "$SEED" --conf "$CONF" --sync --dry-run
    [[ "$output" == *"would clone testorg/beta → $SANDBOX/b/work/beta"* ]]
}

@test "--scout skips a folder whose label contains '#'" {
    rm -rf "$REPO_BASE/personal/untracked"
    _make_repo "$REPO_BASE/c#/tool" "https://github.com/me/tool.git"
    run "$SEED" --conf "$CONF" --scout
    [[ "$output" == *"contains whitespace or '#'"* ]]
    ! grep -q "me/tool" "$CONF"
}

@test "--scout with no conf creates it in ~/.config, not next to the script" {
    local home="$SANDBOX/home"
    _make_repo "$home/git-seed-repos/w/z" "https://github.com/me/z.git"
    ln -s "$SEED" "$SANDBOX/bin/git-seed"
    HOME="$home" run env -u XDG_CONFIG_HOME -u CONF_FILE -u BASE_DIR \
        "$SANDBOX/bin/git-seed" --scout
    [ "$status" -eq 0 ]
    grep -q "^w  me/z$" "$home/.config/git-seed/repos.conf"
    [ ! -e "$SANDBOX/bin/repos.conf" ]
}
