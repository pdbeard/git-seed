#!/usr/bin/env bats

SEED="$BATS_TEST_DIRNAME/../git-seed"

# ── Helpers ───────────────────────────────────────────────────────────

_make_repo() {
    local path="$1" remote="$2" msg="${3:-init}"
    mkdir -p "$path"
    git -C "$path" init -q
    git -C "$path" -c user.email=test@test.com -c user.name=Test \
        remote add origin "$remote"
    echo "# $(basename "$path")" > "$path/README.md"
    git -C "$path" add .
    git -C "$path" -c user.email=test@test.com -c user.name=Test \
        commit -qm "$msg"
}

setup() {
    SANDBOX=$(mktemp -d)
    REPO_BASE="$SANDBOX/repos"
    CONF="$SANDBOX/repos.conf"

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

# ── --pick ────────────────────────────────────────────────────────────

@test "--pick returns a valid path" {
    run "$SEED" --conf "$CONF" --pick
    [ "$status" -eq 0 ]
    [[ "$output" == "$REPO_BASE"* ]]
    [ -d "$output" ]
}

@test "--pick exits 1 when selection is cancelled" {
    FZF_MOCK=cancel run "$SEED" --conf "$CONF" --pick
    [ "$status" -eq 1 ]
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

@test "--open exits 1 when no editor found and EDITOR unset" {
    # /bin contains bash but not vim or code; /usr/bin/env can find bash via /bin.
    # Stripping homebrew and /usr/bin ensures no vim or code fallback is found.
    run env PATH="/bin:$SANDBOX/bin" HOME="$HOME" CONF="$CONF" \
        "$SEED" --conf "$CONF" --open
    [ "$status" -eq 1 ]
    [[ "$output" == *"No editor found"* ]]
}

# ── --sync / --clone-only / --pull-only ───────────────────────────────

@test "--sync --dry-run prints DRY lines without modifying files" {
    run "$SEED" --conf "$CONF" --sync --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY]"* ]]
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
    local bare="$SANDBOX/bare-alpha.git"
    local upstream="$SANDBOX/upstream-alpha"
    git clone -q --bare "$REPO_BASE/personal/alpha" "$bare"
    git -C "$REPO_BASE/personal/alpha" remote set-url origin "file://$bare"
    git clone -q "file://$bare" "$upstream"
    git -C "$upstream" -c user.email=test@test.com -c user.name=Test \
        commit -qm "upstream change" --allow-empty
    git -C "$upstream" push -q origin HEAD

    run "$SEED" --conf "$CONF" --pull-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"[PULL]"*"alpha"* ]]
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

# ── --list ────────────────────────────────────────────────────────────

@test "--list exits 1 when gh is not on PATH" {
    # Restrict PATH to basic Unix dirs + sandbox; gh lives in homebrew so it
    # won't be found, exercising the "gh not installed" error branch.
    run env PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$HOME" CONF="$CONF" \
        "$SEED" --conf "$CONF" --list
    [ "$status" -eq 1 ]
    [[ "$output" == *"gh"* ]]
}
