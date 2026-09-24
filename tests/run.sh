#!/bin/bash
# No test touches the caller's HOME, data directory, or network remotes.
set -u
# Tests drive the numbered prompts; the arrow-key checklist has its own expect test.
DOTS_PLAIN_PROMPTS=1
export DOTS_PLAIN_PROMPTS

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
DOTS=$ROOT/bin/dots
TMP=$(mktemp -d "${TMPDIR:-/tmp}/dots-tests.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
PASS=0
FAIL=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
expect_ok() { "$@" >/dev/null 2>&1; }
expect_fail() { ! "$@" >/dev/null 2>&1; }

make_mock_gitleaks() {
  MOCK=$TMP/mock-gitleaks
  cat >"$MOCK" <<'EOF'
#!/bin/sh
# Tests use this only to make scanner failures deterministic. It prints no finding.
if [ "${DOTS_TEST_GITLEAKS_FAIL:-0}" = 1 ]; then
  for arg in "$@"; do
    last=$arg
    if [ "${next:-0}" = 1 ]; then revision=$arg; next=0; fi
    [ "$arg" = --log-opts ] && next=1
  done
  case " $* " in
    *' git '*) /usr/bin/git --git-dir="$last" grep -q DOTS_TEST_SECRET "${revision:-HEAD}" && exit 1 ;;
    *) grep -R -q DOTS_TEST_SECRET "$last" 2>/dev/null && exit 1 ;;
  esac
fi
exit 0
EOF
  chmod 755 "$MOCK"
}

new_remote() {
  remote=$1
  seed=$TMP/seed-$(basename "$remote")
  rm -rf "$seed" "$remote"
  /usr/bin/git init -q "$seed" || return 1
  /usr/bin/git -C "$seed" config user.name test
  /usr/bin/git -C "$seed" config user.email test@example.invalid
  mkdir -p "$seed/.config/dots"
  mkdir -p "$seed/.config/example"
  printf '%s\n' '.config/example/settings' >"$seed/.config/dots/manifest"
  printf '%s\n' 'base' >"$seed/.config/example/settings"
  /usr/bin/git -C "$seed" add -A && /usr/bin/git -C "$seed" commit -qm seed && /usr/bin/git -C "$seed" branch -M main
  /usr/bin/git init -q --bare "$remote" && /usr/bin/git -C "$seed" remote add origin "$remote" && /usr/bin/git -C "$seed" push -q origin main
}

remote_edit() {
  remote=$1
  command=$2
  work=$TMP/edit-$(basename "$remote")-$RANDOM
  /usr/bin/git clone -q "$remote" "$work" || return 1
  /usr/bin/git -C "$work" checkout -q main
  /bin/sh -c "$command" sh "$work" || return 1
  /usr/bin/git -C "$work" add -A && /usr/bin/git -C "$work" commit -qm edit && /usr/bin/git -C "$work" push -q origin main
}

make_mock_gh() {
  MOCK_GH=$TMP/mock-gh
  MOCK_GIT=$TMP/mock-git
  cat >"$MOCK_GH" <<'EOF'
#!/bin/sh
case "$1:$2" in
  auth:status) exit 0 ;;
  api:user) printf '%s\n' example ;;
  repo:view) if [ "${DOTS_TEST_GH_PUBLIC:-0}" = 1 ]; then printf '%s\n' false; elif [ "${DOTS_TEST_GH_REPO_EXISTS:-0}" = 1 ]; then printf '%s\n' true; else exit 1; fi ;;
  repo:create) printf '%s\n' "$*" >>"$DOTS_TEST_GH_LOG"; /usr/bin/git init -q --bare "$DOTS_TEST_GH_REMOTE" ;;
  pr:create) printf '%s\n' "$*" >>"$DOTS_TEST_GH_LOG"; test "${DOTS_TEST_GH_PR_FAIL:-0}" = 0 ;;
  pr:list)
    printf '%s\n' "$*" >>"$DOTS_TEST_GH_LOG"
    case " $* " in *' --repo example/dotfiles '*'--state open '*'startswith("dots/update-")'*) ;; *) exit 3 ;; esac
    test -z "${DOTS_TEST_GH_OPEN_PR:-}" || printf '%s\n' "$DOTS_TEST_GH_OPEN_PR" ;;
  *) exit 2 ;;
esac
EOF
  cat >"$MOCK_GIT" <<'EOF'
#!/bin/sh
# Map the derived GitHub HTTPS URL to the test-local bare remote.
if [ "$1" = clone ] && [ "${4:-}" = https://github.com/example/dotfiles.git ]; then
  exec /usr/bin/git clone "$2" "$3" "$DOTS_TEST_GH_REMOTE" "$5"
fi
case " $* " in
  *' remote get-url origin'*) printf '%s\n' https://github.com/example/dotfiles.git; exit 0 ;;
esac
# Only a push to the real GitHub URL reaches the test remote; "origin" inside a
# temporary clone would be the local data repository, which is the bug this guards.
if [ "$1" = -C ] && [ "${3:-}" = push ]; then
  target=$5
  [ "$target" != origin ] || target=$(/usr/bin/git -C "$2" remote get-url origin 2>/dev/null)
  if [ "$target" = https://github.com/example/dotfiles.git ]; then
    exec /usr/bin/git -C "$2" push "$4" "$DOTS_TEST_GH_REMOTE" "$6"
  fi
fi
exec /usr/bin/git "$@"
EOF
  chmod 755 "$MOCK_GH" "$MOCK_GIT"
}

run_dots() {
  home=$1
  shift
  HOME=$home DOTS_DATA_DIR=$home/data DOTS_GITLEAKS=$MOCK GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid "$DOTS" "$@"
}

run_sync() {
  home=$1
  input=$2
  # BSD script supplies a pseudo-terminal, needed by the intentional sync guard.
  (sleep 3; printf '%s' "$input") | HOME=$home DOTS_DATA_DIR=$home/data DOTS_GITLEAKS=$MOCK GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid TERM=dumb /usr/bin/script -q /dev/null /bin/sh -c "$DOTS sync"
}

run_discover() {
  home=$1
  input=$2
  (sleep 3; printf '%s' "$input") | HOME=$home DOTS_DATA_DIR=$home/data DOTS_GITLEAKS=$MOCK GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid TERM=dumb /usr/bin/script -q /dev/null /bin/sh -c "$DOTS init --discover"
}

run_default_init() {
  home=$1
  remote=$2
  (sleep 3; printf 'y\n') | HOME=$home DOTS_DATA_DIR=$home/data DOTS_GITLEAKS=$MOCK DOTS_GH=$MOCK_GH DOTS_DEFAULT_REMOTE=$remote DOTS_DEFAULT_GITHUB_REPO=smarzban/dotfiles DOTS_TEST_GH_REMOTE=$remote GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid TERM=dumb /usr/bin/script -q /dev/null /bin/sh -c "$DOTS init"
}

run_existing_default_init() {
  home=$1
  remote=$2
  HOME=$home DOTS_DATA_DIR=$home/data DOTS_GITLEAKS=$MOCK DOTS_DEFAULT_REMOTE=$remote DOTS_DEFAULT_GITHUB_REPO=example/dotfiles GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid "$DOTS" init
}

run_public_default_init() {
  home=$1
  DOTS_TEST_GH_PUBLIC=1 HOME=$home DOTS_DATA_DIR=$home/data DOTS_GITLEAKS=$MOCK DOTS_GH=$MOCK_GH GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid "$DOTS" init
}

run_derived_default_init() {
  home=$1
  remote=$2
  response=$3
  log=$TMP/gh-create.log
  : >"$log"
  (sleep 3; printf '%s' "$response") | HOME=$home DOTS_DATA_DIR=$home/data DOTS_GITLEAKS=$MOCK DOTS_GH=$MOCK_GH DOTS_GIT=$MOCK_GIT DOTS_TEST_GH_REMOTE=$remote DOTS_TEST_GH_LOG=$log GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid TERM=dumb /usr/bin/script -q /dev/null /bin/sh -c "$DOTS init"
}

run_update() {
  home=$1
  remote=$2
  input=$3
  log=$TMP/gh-update.log
  : >"$log"
  (sleep 3; printf '%s' "$input") | DOTS_TEST_GH_REPO_EXISTS=1 HOME=$home DOTS_DATA_DIR=$home/data DOTS_GITLEAKS=$MOCK DOTS_GH=$MOCK_GH DOTS_GIT=$MOCK_GIT DOTS_TEST_GH_REMOTE=$remote DOTS_TEST_GH_LOG=$log GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid TERM=dumb /usr/bin/script -q /dev/null /bin/sh -c "$DOTS update"
}

run_dots_pty() {
  home=$1
  input=$2
  shift 2
  (sleep 3; printf '%s' "$input") | HOME=$home DOTS_DATA_DIR=$home/data DOTS_GITLEAKS=$MOCK GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid TERM=dumb /usr/bin/script -q /dev/null "$DOTS" "$@"
}

make_mock_gitleaks
make_mock_gh
chmod 755 "$DOTS"

# Manifest attacks: traversal, globs, duplicates, controls, and symlink entries all fail before checkout.
remote=$TMP/manifest.git; new_remote "$remote"
for bad in '../.ssh/id_rsa' '/etc/passwd' '.config/*/x' '.config/\\*/x' '.gitconfig
.gitconfig' '.config/dots/manifest'; do
  case $bad in '.config/dots/manifest') continue ;; esac
  remote_edit "$remote" "mkdir -p \"\$1/.config/dots\"; printf '%s\\n' '$bad' > \"\$1/.config/dots/manifest\"" || exit 1
  home=$TMP/home-bad-$RANDOM; mkdir -p "$home"
  if expect_fail run_dots "$home" init "$remote" main && test ! -e "$home/.gitconfig"; then pass "manifest attack refused"; else fail "manifest attack refused"; fi
  # restore a clean remote for the next independent malicious candidate.
  remote=$TMP/manifest-$RANDOM.git; new_remote "$remote"
done
# A candidate symlink is unsafe even when named in the manifest.
remote=$TMP/symlink.git; new_remote "$remote"
remote_edit "$remote" "ln -sf /tmp/x \"\$1/.gitconfig\"" || exit 1
home=$TMP/home-symlink; mkdir -p "$home"
if expect_fail run_dots "$home" init "$remote" main; then pass "symlink candidate refused"; else fail "symlink candidate refused"; fi

# The default missing GitHub repository is explicitly confirmed, made private, and seeded only with its empty manifest.
remote=$TMP/default-created.git; home=$TMP/home-default-created; mkdir -p "$home"
if run_default_init "$home" "$remote" >/dev/null 2>&1 && test -f "$home/.config/dots/manifest" && /usr/bin/git --git-dir="$remote" show main:.config/dots/manifest >/dev/null; then pass "default GitHub repository creation"; else fail "default GitHub repository creation"; fi
# An existing default uses its remote HEAD rather than assuming main.
remote=$TMP/default-trunk.git; new_remote "$remote"; work=$TMP/default-trunk-work; /usr/bin/git clone -q "$remote" "$work"; /usr/bin/git -C "$work" branch -m main trunk; /usr/bin/git -C "$work" push -q origin trunk; /usr/bin/git --git-dir="$remote" symbolic-ref HEAD refs/heads/trunk
home=$TMP/home-default-trunk; mkdir -p "$home"
if expect_ok run_existing_default_init "$home" "$remote" && test "$(/usr/bin/git --git-dir="$home/data/repo.git" config --get dots.branch)" = trunk; then pass "existing default branch"; else fail "existing default branch"; fi
# Normal no-argument derivation creates <authenticated-user>/dotfiles and asks first.
remote=$TMP/derived-created.git; home=$TMP/home-derived-created; mkdir -p "$home"
if run_derived_default_init "$home" "$remote" $'y\n' >/dev/null 2>&1 && test -f "$home/.config/dots/manifest" && grep -F -- '--private' "$TMP/gh-create.log" >/dev/null; then pass "derived private default creation"; else fail "derived private default creation"; fi
remote=$TMP/derived-cancelled.git; home=$TMP/home-derived-cancelled; mkdir -p "$home"
if run_derived_default_init "$home" "$remote" $'n\n' >/dev/null 2>&1 && test ! -e "$remote"; then pass "derived default cancellation"; else fail "derived default cancellation"; fi
# Normal no-argument derivation rejects a public <authenticated-user>/dotfiles repo.
home=$TMP/home-public-default; mkdir -p "$home"
if expect_fail run_public_default_init "$home"; then pass "derived public default refused"; else fail "derived public default refused"; fi

# Initial collisions are never overwritten, and repeating a successful init is a no-op.
remote=$TMP/collision.git; new_remote "$remote"; home=$TMP/home-collision; mkdir -p "$home/.config/example"; printf old >"$home/.config/example/settings"
if expect_fail run_dots "$home" init "$remote" main && test "$(cat "$home/.config/example/settings")" = old; then pass "collision refused"; else fail "collision refused"; fi
# A second machine: identical files are adopted, different files need --backup-existing.
home=$TMP/home-identical; mkdir -p "$home/.config/example"; printf 'base\n' >"$home/.config/example/settings"
if expect_ok run_dots "$home" init "$remote" main && test ! -e "$home/data/backups"; then pass "identical existing file is adopted"; else fail "identical existing file is adopted"; fi
home=$TMP/home-collision-hint; mkdir -p "$home/.config/example"; printf old >"$home/.config/example/settings"
if run_dots "$home" init "$remote" main 2>&1 | grep -F -- --backup-existing >/dev/null; then pass "collision error names --backup-existing"; else fail "collision error names --backup-existing"; fi
if expect_ok run_dots "$home" init --backup-existing "$remote" main && test "$(cat "$home/.config/example/settings")" = base; then pass "backup-existing applies repository version"; else fail "backup-existing applies repository version"; fi
backup=$(find "$home/data/backups" -path '*/.config/example/settings' -type f 2>/dev/null | head -1)
if test -n "$backup" && test "$(cat "$backup")" = old && test "$(stat -f %Lp "$(dirname "$(dirname "$(dirname "$backup")")")")" = 700; then pass "backup-existing keeps a private backup"; else fail "backup-existing keeps a private backup"; fi
# A checkout failure after backup names the backup and leaves init retryable.
home=$TMP/home-backup-retry; mkdir -p "$home/.config/example"; printf old >"$home/.config/example/settings"; chmod 555 "$home/.config/example"
failure=$(run_dots "$home" init --backup-existing "$remote" main 2>&1); chmod 755 "$home/.config/example"
if printf '%s' "$failure" | grep -F 'backup:' >/dev/null && test ! -e "$home/data/repo.git" && expect_ok run_dots "$home" init --backup-existing "$remote" main && test "$(cat "$home/.config/example/settings")" = base; then pass "failed backup init names the backup and can be retried"; else fail "failed backup init names the backup and can be retried"; fi
home=$TMP/home-backup-symlink; mkdir -p "$home/.config/example"; ln -s /tmp "$home/.config/example/settings"
if expect_fail run_dots "$home" init --backup-existing "$remote" main && test -L "$home/.config/example/settings"; then pass "backup-existing refuses symlink targets"; else fail "backup-existing refuses symlink targets"; fi
home=$TMP/home-backup-dir; mkdir -p "$home/.config/example/settings"
if expect_fail run_dots "$home" init --backup-existing "$remote" main && test -d "$home/.config/example/settings"; then pass "backup-existing refuses directory targets"; else fail "backup-existing refuses directory targets"; fi
home=$TMP/home-idempotent; mkdir -p "$home"
if expect_ok run_dots "$home" init "$remote" main && expect_ok run_dots "$home" init "$remote" main; then pass "idempotent init"; else fail "idempotent init"; fi

# Discovery is a names-only preview and never changes an initialized manifest.
printf git >"$home/.gitconfig"; printf shell >"$home/.zshrc"
discovery=$(run_dots "$home" init --discover 2>&1)
if printf '%s\n' "$discovery" | grep -F .gitconfig >/dev/null && ! grep -Fx .gitconfig "$home/.config/dots/manifest" >/dev/null; then pass "read-only candidate discovery"; else fail "read-only candidate discovery"; fi

# Discovery covers agent sources, keeps exclusions, and renders one candidate per line.
disc=$TMP/home-discovery; outside=$TMP/outside-discovery; mkdir -p "$disc" "$outside"
printf git >"$disc/.gitconfig"; printf shell >"$disc/.zshrc"
mkdir -p "$disc/.claude" "$disc/.pi/agent/agents" "$disc/.codex/skills/demo" "$disc/.config/mcp" "$disc/.config/pass"
printf '{}' >"$disc/.claude/settings.json"; printf agent >"$disc/.pi/agent/agents/helper.md"
printf skill >"$disc/.codex/skills/demo/SKILL.md"; printf notes >"$disc/.codex/skills/demo/notes.md"
printf '{}' >"$disc/.config/mcp/settings.json"; printf ref >"$disc/.config/pass/dev.env.tmpl"; printf '{}' >"$disc/.pi/web-search.json"
# A symlinked parent must not expose files from outside HOME.
printf outside >"$outside/config.toml"; ln -s "$outside" "$disc/.grok"
# A newline inside a filename must not forge a second HOME path.
printf private >"$disc/.forged"; printf x >"$disc/.pi/agent/agents/a
.forged"
discovery=$(run_dots "$disc" init --discover 2>&1)
listed() { printf '%s\n' "$discovery" | grep -E "^ *[0-9]+  $1\$" >/dev/null; }
if listed .gitconfig && listed .zshrc && ! printf '%s' "$discovery" | grep -F '\n' >/dev/null; then pass "discovery renders one candidate per line"; else fail "discovery renders one candidate per line"; fi
if listed .claude/settings.json && listed .pi/agent/agents/helper.md && listed .codex/skills/demo/SKILL.md; then pass "discovery includes agent sources"; else fail "discovery includes agent sources"; fi
if ! printf '%s' "$discovery" | grep -F -e notes.md -e .config/mcp/ -e .config/pass/ -e .pi/web-search.json >/dev/null; then pass "discovery keeps exclusions"; else fail "discovery keeps exclusions"; fi
if ! printf '%s' "$discovery" | grep -F -e .grok/config.toml -e .forged >/dev/null; then pass "discovery refuses symlinked parents and forged names"; else fail "discovery refuses symlinked parents and forged names"; fi

# status scopes itself to the allowlist and never reports an unrelated home file.
printf private >"$home/private-token"
status=$(run_dots "$home" status 2>&1 || true)
if printf '%s' "$status" | grep -F private-token >/dev/null; then fail "unrelated-home privacy"; else pass "unrelated-home privacy"; fi
# Git's empty pathspec (`:`) must never turn a manifest entry into a broad operation.
printf ':\n' >"$home/.config/dots/manifest"
if expect_fail run_dots "$home" status; then pass "pathspec manifest attack"; else fail "pathspec manifest attack"; fi
printf '%s\n' '.config/example/settings' >"$home/.config/dots/manifest"

# Sync never stages unrelated files or creates history from local edits.
printf local >"$home/.config/example/settings"; printf unrelated >"$home/not-approved"
before=$(/usr/bin/git --git-dir="$home/data/repo.git" rev-parse HEAD)
if run_sync "$home" $'2\n' >/dev/null 2>&1 && test "$before" = "$(/usr/bin/git --git-dir="$home/data/repo.git" rev-parse HEAD)" && test "$(cat "$home/.config/example/settings")" = local && ! /usr/bin/git --git-dir="$home/data/repo.git" ls-tree -r --name-only HEAD | grep -F not-approved >/dev/null; then pass "sync keeps local changes"; else fail "sync keeps local changes"; fi

# Choosing the repository version discards approved local changes without history.
printf cancelled >"$home/.config/example/settings"
if run_sync "$home" $'1\n' >/dev/null 2>&1 && test "$before" = "$(/usr/bin/git --git-dir="$home/data/repo.git" rev-parse HEAD)"; then pass "sync repository override"; else fail "sync repository override"; fi

# Mocked scanner failure blocks known secret-shaped local and incoming candidates without exposing a finding.
printf DOTS_TEST_SECRET >"$home/.config/example/settings"
DOTS_TEST_GITLEAKS_FAIL=1
export DOTS_TEST_GITLEAKS_FAIL
if ! run_sync "$home" $'y\nshould not commit\n' >/dev/null 2>&1; then pass "local secret-scan failure"; else fail "local secret-scan failure"; fi
unset DOTS_TEST_GITLEAKS_FAIL
remote=$TMP/incoming-secret.git; new_remote "$remote"; home2=$TMP/home-incoming; mkdir -p "$home2"; expect_ok run_dots "$home2" init "$remote" main
remote_edit "$remote" "printf '%s\\n' DOTS_TEST_SECRET > \"\$1/.config/example/settings\"" || exit 1
DOTS_TEST_GITLEAKS_FAIL=1
export DOTS_TEST_GITLEAKS_FAIL
if ! run_sync "$home2" '' >/dev/null 2>&1; then pass "incoming secret-scan failure"; else fail "incoming secret-scan failure"; fi
unset DOTS_TEST_GITLEAKS_FAIL

# Incoming unapproved content is rejected before it reaches the live home.
remote=$TMP/unapproved.git; new_remote "$remote"; home3=$TMP/home-unapproved; mkdir -p "$home3"; expect_ok run_dots "$home3" init "$remote" main
remote_edit "$remote" "printf bad > \"\$1/.unapproved\"" || exit 1
if ! run_sync "$home3" '' >/dev/null 2>&1 && test ! -e "$home3/.unapproved"; then pass "incoming unapproved content"; else fail "incoming unapproved content"; fi
# A repository-supplied gitleaks policy cannot weaken the scanner.
remote=$TMP/scanner-config.git; new_remote "$remote"
remote_edit "$remote" "printf '%s\\n' '.config/example/settings' '.gitleaks.toml' > \"\$1/.config/dots/manifest\"; printf 'allowlist = [\"DOTS_TEST_SECRET\"]\\n' > \"\$1/.gitleaks.toml\"; printf DOTS_TEST_SECRET > \"\$1/.config/example/settings\"" || exit 1
home4=$TMP/home-scanner-config; mkdir -p "$home4"
if expect_fail run_dots "$home4" init "$remote" main && test ! -e "$home4/.config/example/settings"; then pass "scanner config refused"; else fail "scanner config refused"; fi

# A local-only merge conflict stays in a private workspace, never in live files.
remote=$TMP/conflict.git; new_remote "$remote"; b=$TMP/home-b; mkdir -p "$b"; expect_ok run_dots "$b" init "$remote" main
printf two >"$b/.config/example/settings"
remote_edit "$remote" "printf one > \"\$1/.config/example/settings\"" || exit 1
if run_sync "$b" $'4\n' >/dev/null 2>&1 && test "$(cat "$b/.config/example/settings")" = two && test -d "$b/data/conflict-workspace/.git"; then pass "conflict workspace preservation"; else fail "conflict workspace preservation"; fi
workspace=$b/data/conflict-workspace
/usr/bin/git -C "$workspace" checkout --theirs -- .config/example/settings && /usr/bin/git -C "$workspace" add -- .config/example/settings && /usr/bin/git -C "$workspace" commit -qm resolve || exit 1
if expect_ok run_dots "$b" sync --continue && test "$(cat "$b/.config/example/settings")" = one && test ! -e "$workspace"; then pass "conflict workspace continuation"; else fail "conflict workspace continuation"; fi

# Two clean homes can apply an allowlisted remote change without pushing.
remote=$TMP/two-machine.git; new_remote "$remote"; one=$TMP/home-one; two=$TMP/home-two; mkdir -p "$one" "$two"; expect_ok run_dots "$one" init "$remote" main; expect_ok run_dots "$two" init "$remote" main
remote_edit "$remote" "printf synced > \"\$1/.config/example/settings\"" || exit 1
if run_sync "$two" '' >/dev/null 2>&1 && test "$(cat "$two/.config/example/settings")" = synced; then pass "successful two-machine sync"; else fail "successful two-machine sync"; fi

# Update creates a GitHub PR branch from selected local candidates without changing HOME.
remote=$TMP/update.git; update_home=$TMP/home-update; mkdir -p "$update_home"
run_derived_default_init "$update_home" "$remote" $'y\n' >/dev/null 2>&1 || exit 1
printf shell >"$update_home/.zshrc"
if run_update "$update_home" "$remote" $'1\ny\nAdd shell configuration\n' >/dev/null 2>&1 && ! grep -Fx .zshrc "$update_home/.config/dots/manifest" >/dev/null && /usr/bin/git --git-dir="$remote" show-ref | grep -F 'refs/heads/dots/update-' >/dev/null && grep -F 'pr create' "$TMP/gh-update.log" >/dev/null && grep -Fx 'pending .zshrc' "$update_home/data/selection" >/dev/null; then pass "update creates candidate PR"; else fail "update creates candidate PR"; fi
# While that PR is open, another update is refused instead of racing it.
refs_before=$(/usr/bin/git --git-dir="$remote" for-each-ref | wc -l)
open_out=$(DOTS_TEST_GH_OPEN_PR=https://github.com/example/dotfiles/pull/1 run_update "$update_home" "$remote" $'1\ny\nsecond\n' 2>&1)
if printf '%s' "$open_out" | grep -F 'still open' >/dev/null && ! printf '%s' "$open_out" | grep -F 'PR title' >/dev/null && test "$(/usr/bin/git --git-dir="$remote" for-each-ref | wc -l)" = "$refs_before"; then pass "update refuses while an update PR is open"; else fail "update refuses while an update PR is open"; fi
# Pending ticks are pre-ticked next time, for example after a failed PR attempt.
if run_update "$update_home" "$remote" $'\n' 2>&1 | grep -F '[x] .zshrc' >/dev/null; then pass "update remembers pending ticks"; else fail "update remembers pending ticks"; fi
# Once the PR is merged, sync treats the file as used here without asking.
merged_ref=$(/usr/bin/git --git-dir="$remote" for-each-ref --format='%(refname)' 'refs/heads/dots/update-*' | head -1)
/usr/bin/git --git-dir="$remote" update-ref refs/heads/main "$merged_ref"
merge_out=$(run_sync "$update_home" '' 2>&1)
if ! printf '%s' "$merge_out" | grep -F 'New files in the repository' >/dev/null && grep -Fx 'use .zshrc' "$update_home/data/selection" >/dev/null && ! grep -F 'pending' "$update_home/data/selection" >/dev/null && grep -Fx .zshrc "$update_home/.config/dots/manifest" >/dev/null; then pass "merged pending files become used without asking"; else fail "merged pending files become used without asking"; fi

# ── Per-Mac file selection ─────────────────────────────────
# Checklist rows list home-folder files first, sorted, then other directories.
remote=$TMP/selection.git; new_remote "$remote"
remote_edit "$remote" "printf '%s\\n' '.config/example/settings' '.zshrc' > \"\$1/.config/dots/manifest\"; printf 'repo shell\\n' > \"\$1/.zshrc\"" || exit 1
all_home=$TMP/home-select-all; mkdir -p "$all_home"
if expect_ok run_dots "$all_home" init "$remote" main && grep -Fx 'use .zshrc' "$all_home/data/selection" >/dev/null && test -f "$all_home/.zshrc"; then pass "noninteractive init uses every file"; else fail "noninteractive init uses every file"; fi
pick_home=$TMP/home-select-pick; mkdir -p "$pick_home"
run_dots_pty "$pick_home" $'1\n' init "$remote" main >/dev/null 2>&1
if test ! -e "$pick_home/.zshrc" && test -f "$pick_home/.config/example/settings" && grep -Fx 'skip .zshrc' "$pick_home/data/selection" >/dev/null; then pass "init brings only the chosen files"; else fail "init brings only the chosen files"; fi
status=$(run_dots "$pick_home" status 2>&1)
if printf '%s\n' "$status" | grep -Fx 'files used on this Mac: 1 of 2' >/dev/null && printf '%s\n' "$status" | grep -Fx 'tracked configuration changes: none' >/dev/null; then pass "status ignores files this Mac does not use"; else fail "status ignores files this Mac does not use"; fi
remote_edit "$remote" "printf 'repo shell 2\\n' > \"\$1/.zshrc\"" || exit 1
if run_sync "$pick_home" '' >/dev/null 2>&1 && test ! -e "$pick_home/.zshrc" && test "$(/usr/bin/git --git-dir="$pick_home/data/repo.git" rev-parse HEAD)" = "$(/usr/bin/git --git-dir="$remote" rev-parse main)"; then pass "sync skips files this Mac does not use"; else fail "sync skips files this Mac does not use"; fi
printf 'mine\n' >"$pick_home/.zshrc"
if run_dots_pty "$pick_home" $'1\ny\n' select >/dev/null 2>&1 && test "$(cat "$pick_home/.zshrc")" = 'repo shell 2' && grep -Fx 'use .zshrc' "$pick_home/data/selection" >/dev/null; then pass "select brings in a newly chosen file"; else fail "select brings in a newly chosen file"; fi
backup=$(find "$pick_home/data/backups" -path '*select-*/.zshrc' -type f 2>/dev/null | head -1)
if test -n "$backup" && test "$(cat "$backup")" = mine; then pass "select backs up a differing local file"; else fail "select backs up a differing local file"; fi
# A file another Mac adds is offered once; declining it is remembered.
remote_edit "$remote" "printf '%s\\n' '.config/example/settings' '.zshrc' '.config/example/extra' > \"\$1/.config/dots/manifest\"; printf extra > \"\$1/.config/example/extra\"" || exit 1
if run_sync "$pick_home" $'1\n' >/dev/null 2>&1 && test ! -e "$pick_home/.config/example/extra" && grep -Fx 'skip .config/example/extra' "$pick_home/data/selection" >/dev/null; then pass "sync offers new repository files"; else fail "sync offers new repository files"; fi
remote_edit "$remote" "printf more > \"\$1/.config/example/extra\"" || exit 1
if run_sync "$pick_home" '' >/dev/null 2>&1 && test ! -e "$pick_home/.config/example/extra"; then pass "declined repository files are not offered again"; else fail "declined repository files are not offered again"; fi
if run_sync "$all_home" $'\n' >/dev/null 2>&1 && test "$(cat "$all_home/.config/example/extra")" = more; then pass "accepted repository files are applied"; else fail "accepted repository files are applied"; fi
# Without a saved selection (an older install), every repository file counts as used.
mv "$all_home/data/selection" "$TMP/selection.saved"
if run_dots "$all_home" status 2>&1 | grep -Fx 'files used on this Mac: 3 of 3' >/dev/null; then pass "missing selection uses every file"; else fail "missing selection uses every file"; fi
mv "$TMP/selection.saved" "$all_home/data/selection"
# The arrow-key checklist: Space unticks the first page's file, Right changes page, Enter confirms; q cancels.
if command -v expect >/dev/null 2>&1; then
  tui_script=$TMP/checklist.expect
  cat >"$tui_script" <<'EXPECT'
# Keys: S space, R right arrow, E enter, Q q. Every redraw ends with the count line.
set timeout 20
set keys [lindex $argv 0]
set stty_init "rows 30 columns 100"
spawn -noecho {*}[lrange $argv 1 end]
expect {
  "selected" {}
  timeout { exit 1 }
}
foreach key [split $keys ""] {
  if {$key eq "S"} { send " " }
  if {$key eq "R"} { send "\033\[C" }
  if {$key eq "E" || $key eq "Q"} {
    if {$key eq "E"} { send "\r" } else { send "q" }
    expect {
      eof { exit 0 }
      timeout { exit 1 }
    }
  }
  expect {
    "selected" {}
    timeout { exit 1 }
  }
}
exit 1
EXPECT
  tui_home=$TMP/home-tui; mkdir -p "$tui_home"
  if HOME=$tui_home DOTS_DATA_DIR=$tui_home/data DOTS_GITLEAKS=$MOCK DOTS_PLAIN_PROMPTS=0 TERM=xterm-256color expect "$tui_script" SRE "$DOTS" init "$remote" main >/dev/null 2>&1 &&
    test ! -e "$tui_home/.zshrc" && test -f "$tui_home/.config/example/settings" && grep -Fx 'skip .zshrc' "$tui_home/data/selection" >/dev/null; then pass "arrow-key checklist selects files"; else fail "arrow-key checklist selects files"; fi
  tui_cancel=$TMP/home-tui-cancel; mkdir -p "$tui_cancel"
  if HOME=$tui_cancel DOTS_DATA_DIR=$tui_cancel/data DOTS_GITLEAKS=$MOCK DOTS_PLAIN_PROMPTS=0 TERM=xterm-256color expect "$tui_script" Q "$DOTS" init "$remote" main >/dev/null 2>&1 &&
    test ! -e "$tui_cancel/data/repo.git" && test ! -e "$tui_cancel/.config/example/settings"; then pass "arrow-key checklist cancel changes nothing"; else fail "arrow-key checklist cancel changes nothing"; fi
  restore_script=$TMP/restore.expect
  cat >"$restore_script" <<'EXPECT'
# After the checklist ends (q or Ctrl-C), the terminal must be back in canonical, echoing mode.
set timeout 20
set key [lindex $argv 0]
set stty_init "rows 30 columns 100"
spawn -noecho /bin/sh -c "\"[lindex $argv 1]\" init \"[lindex $argv 2]\" main; stty -a"
expect { "selected" {} timeout { exit 1 } }
if {$key eq "Q"} { send "q" } else { send "\003" }
expect {
  -re {lflags:[^\r\n]*} { set flags $expect_out(0,string) }
  timeout { exit 1 }
}
if {[string match "*-icanon*" $flags] || [string match "*-echo *" $flags]} { exit 1 }
expect eof
exit 0
EXPECT
  for key in Q C; do
    restore_home=$TMP/home-restore-$key; mkdir -p "$restore_home"
    if HOME=$restore_home DOTS_DATA_DIR=$restore_home/data DOTS_GITLEAKS=$MOCK DOTS_PLAIN_PROMPTS=0 TERM=xterm-256color expect "$restore_script" "$key" "$DOTS" "$remote" >/dev/null 2>&1; then pass "checklist restores the terminal ($key)"; else fail "checklist restores the terminal ($key)"; fi
  done
else
  pass "arrow-key checklist (expect unavailable, skipped)"
fi
# Confirmed ticks are saved before publishing, so a failed PR creation keeps them.
remote=$TMP/update-fail.git; fail_home=$TMP/home-update-fail; mkdir -p "$fail_home"
run_derived_default_init "$fail_home" "$remote" $'y\n' >/dev/null 2>&1 || exit 1
printf shell >"$fail_home/.zshrc"
if ! DOTS_TEST_GH_PR_FAIL=1 run_update "$fail_home" "$remote" $'1\ny\nFirst upload\n' >/dev/null 2>&1 && grep -Fx 'pending .zshrc' "$fail_home/data/selection" >/dev/null && run_update "$fail_home" "$remote" $'\n' 2>&1 | grep -F '[x] .zshrc' >/dev/null; then pass "failed PR creation keeps the ticks"; else fail "failed PR creation keeps the ticks"; fi
# Pending entries survive select and unrelated syncs, and count as used once in the manifest.
remote=$TMP/pending-keep.git; new_remote "$remote"; keep_home=$TMP/home-pending-keep; mkdir -p "$keep_home"; expect_ok run_dots "$keep_home" init "$remote" main
printf 'pending .zshrc\n' >>"$keep_home/data/selection"
run_dots_pty "$keep_home" $'\n' select >/dev/null 2>&1
remote_edit "$remote" "printf changed > \"\$1/.config/example/settings\"" || exit 1
if grep -Fx 'pending .zshrc' "$keep_home/data/selection" >/dev/null && run_sync "$keep_home" '' >/dev/null 2>&1 && grep -Fx 'pending .zshrc' "$keep_home/data/selection" >/dev/null; then pass "pending entries survive select and sync"; else fail "pending entries survive select and sync"; fi
printf '%s\n' '.config/example/settings' '.zshrc' >"$keep_home/.config/dots/manifest"; printf shell >"$keep_home/.zshrc"
if run_dots "$keep_home" status 2>&1 | grep -Fx 'files used on this Mac: 2 of 2' >/dev/null; then pass "pending files in the manifest count as used"; else fail "pending files in the manifest count as used"; fi
# A merged own file edited since its PR is confirmed before replacing, instead of blocking sync.
edit_remote=$TMP/update-edited.git; edit_home=$TMP/home-update-edited; mkdir -p "$edit_home"
run_derived_default_init "$edit_home" "$edit_remote" $'y\n' >/dev/null 2>&1 || exit 1
printf 'v1\n' >"$edit_home/.zshrc"
run_update "$edit_home" "$edit_remote" $'1\ny\nShare shell\n' >/dev/null 2>&1
edit_ref=$(/usr/bin/git --git-dir="$edit_remote" for-each-ref --format='%(refname)' 'refs/heads/dots/update-*' | head -1)
test -n "$edit_ref" && /usr/bin/git --git-dir="$edit_remote" update-ref refs/heads/main "$edit_ref"
printf 'v2\n' >"$edit_home/.zshrc"
if run_sync "$edit_home" $'n\n' >/dev/null 2>&1 && test "$(cat "$edit_home/.zshrc")" = v2 && grep -Fx 'skip .zshrc' "$edit_home/data/selection" >/dev/null; then pass "edited own file is confirmed, not a stuck sync"; else fail "edited own file is confirmed, not a stuck sync"; fi

# Update: unticking a shared file removes it from the repository only; files this Mac skips keep their repository version.
remote=$TMP/update-remove.git; new_remote "$remote"
remote_edit "$remote" "printf '%s\\n' '.config/example/settings' '.zshrc' '.gitconfig' > \"\$1/.config/dots/manifest\"; printf 'shell\\n' > \"\$1/.zshrc\"; printf 'git\\n' > \"\$1/.gitconfig\"" || exit 1
remove_home=$TMP/home-update-remove; mkdir -p "$remove_home"
run_dots_pty "$remove_home" $'1\n' init "$remote" main >/dev/null 2>&1
printf 'local git\n' >"$remove_home/.gitconfig"
# Declining the confirmation changes nothing.
run_update "$remove_home" "$remote" $'1\nn\n' >/dev/null 2>&1
if test -z "$(/usr/bin/git --git-dir="$remote" for-each-ref 'refs/heads/dots/update-*')"; then pass "declined update removal changes nothing"; else fail "declined update removal changes nothing"; fi
if run_update "$remove_home" "$remote" $'1\ny\nStop sharing shell\n' >/dev/null 2>&1; then
  update_ref=$(/usr/bin/git --git-dir="$remote" for-each-ref --format='%(refname)' 'refs/heads/dots/update-*' | head -1)
  proposed=$(/usr/bin/git --git-dir="$remote" show "$update_ref:.config/dots/manifest" 2>/dev/null)
  if test -n "$update_ref" && ! printf '%s\n' "$proposed" | grep -Fx .zshrc >/dev/null && printf '%s\n' "$proposed" | grep -Fx .gitconfig >/dev/null && test "$(/usr/bin/git --git-dir="$remote" show "$update_ref:.gitconfig")" = git && test -f "$remove_home/.zshrc"; then pass "update removes unticked files and keeps skipped ones"; else fail "update removes unticked files and keeps skipped ones"; fi
else
  fail "update removes unticked files and keeps skipped ones"
fi

# Accepting a new repository file whose local copy differs asks first; yes backs it up, no leaves it unused.
remote=$TMP/sync-differing.git; new_remote "$remote"
yes_home=$TMP/home-sync-differing-yes; no_home=$TMP/home-sync-differing-no; mkdir -p "$yes_home" "$no_home"
expect_ok run_dots "$yes_home" init "$remote" main; expect_ok run_dots "$no_home" init "$remote" main
printf 'mine\n' >"$yes_home/.zshrc"; printf 'mine\n' >"$no_home/.zshrc"
remote_edit "$remote" "printf '%s\\n' '.config/example/settings' '.zshrc' > \"\$1/.config/dots/manifest\"; printf 'theirs\\n' > \"\$1/.zshrc\"" || exit 1
if run_sync "$yes_home" $'\ny\n' >/dev/null 2>&1 && test "$(cat "$yes_home/.zshrc")" = theirs && test "$(cat "$(find "$yes_home/data/backups" -path '*sync-*/.zshrc' -type f | head -1)")" = mine; then pass "sync backs up a differing local copy after confirmation"; else fail "sync backs up a differing local copy after confirmation"; fi
if run_sync "$no_home" $'\nn\n' >/dev/null 2>&1 && test "$(cat "$no_home/.zshrc")" = mine && grep -Fx 'skip .zshrc' "$no_home/data/selection" >/dev/null; then pass "sync leaves a differing local copy when declined"; else fail "sync leaves a differing local copy when declined"; fi
# Keeping local changes does not save choices about new files; they are offered again.
remote_edit "$remote" "printf '%s\\n' '.config/example/settings' '.zshrc' '.config/example/later' > \"\$1/.config/dots/manifest\"; printf later > \"\$1/.config/example/later\"" || exit 1
printf 'dirty\n' >"$yes_home/.config/example/settings"
run_sync "$yes_home" $'\n2\n' >/dev/null 2>&1
if ! grep -F '.config/example/later' "$yes_home/data/selection" >/dev/null && run_sync "$yes_home" $'\n2\n' 2>&1 | grep -F 'New files in the repository' >/dev/null; then pass "kept local changes leave new files unanswered"; else fail "kept local changes leave new files unanswered"; fi
# A local-only merge keeps the repository version of files this Mac does not use.
remote=$TMP/merge-unused.git; new_remote "$remote"
remote_edit "$remote" "printf '%s\\n' '.config/example/settings' '.zshrc' > \"\$1/.config/dots/manifest\"; printf 'shell\\n' > \"\$1/.zshrc\"" || exit 1
merge_home=$TMP/home-merge-unused; mkdir -p "$merge_home"
run_dots_pty "$merge_home" $'1\n' init "$remote" main >/dev/null 2>&1
printf 'local\n' >"$merge_home/.config/example/settings"
remote_edit "$remote" "printf 'shell 2\\n' > \"\$1/.zshrc\"" || exit 1
if run_sync "$merge_home" $'4\n' >/dev/null 2>&1 && test ! -e "$merge_home/.zshrc" && test "$(cat "$merge_home/.config/example/settings")" = local && test "$(/usr/bin/git --git-dir="$merge_home/data/repo.git" show HEAD:.zshrc)" = 'shell 2'; then pass "local merge keeps files this Mac does not use"; else fail "local merge keeps files this Mac does not use"; fi
# select can stop using a file: later repository changes leave the local copy alone.
remote=$TMP/select-stop.git; new_remote "$remote"; stop_home=$TMP/home-select-stop; mkdir -p "$stop_home"; expect_ok run_dots "$stop_home" init "$remote" main
if run_dots_pty "$stop_home" $'1\n' select >/dev/null 2>&1 && grep -Fx 'skip .config/example/settings' "$stop_home/data/selection" >/dev/null; then pass "select stops using a file"; else fail "select stops using a file"; fi
remote_edit "$remote" "printf changed > \"\$1/.config/example/settings\"" || exit 1
if run_sync "$stop_home" '' >/dev/null 2>&1 && test "$(cat "$stop_home/.config/example/settings")" = base; then pass "sync leaves files this Mac stopped using"; else fail "sync leaves files this Mac stopped using"; fi
# Declining select's backup confirmation changes nothing.
printf 'mine\n' >"$stop_home/.config/example/settings"
run_dots_pty "$stop_home" $'1\nn\n' select >/dev/null 2>&1
if test "$(cat "$stop_home/.config/example/settings")" = mine && grep -Fx 'skip .config/example/settings' "$stop_home/data/selection" >/dev/null; then pass "declined select changes nothing"; else fail "declined select changes nothing"; fi
# DOTS_PLAIN_PROMPTS=1 forces the numbered list even in a capable terminal.
plain_home=$TMP/home-plain; mkdir -p "$plain_home"
plain=$( (sleep 3; printf '\n') | HOME=$plain_home DOTS_DATA_DIR=$plain_home/data DOTS_GITLEAKS=$MOCK DOTS_PLAIN_PROMPTS=1 TERM=xterm-256color /usr/bin/script -q /dev/null "$DOTS" init "$TMP/merge-unused.git" main 2>&1)
if printf '%s' "$plain" | grep -F 'Toggle numbers' >/dev/null; then pass "DOTS_PLAIN_PROMPTS forces numbered prompts"; else fail "DOTS_PLAIN_PROMPTS forces numbered prompts"; fi

# Repository internals are never valid manifest targets, even when DOTS_DATA is under HOME.
remote=$TMP/reserved-path.git; new_remote "$remote"
remote_edit "$remote" "printf '%s\\n' 'data/repo.git/hooks/pre-commit' > \"\$1/.config/dots/manifest\"; mkdir -p \"\$1/data/repo.git/hooks\"; printf unsafe > \"\$1/data/repo.git/hooks/pre-commit\"" || exit 1
reserved_home=$TMP/home-reserved-path; mkdir -p "$reserved_home"
if expect_fail run_dots "$reserved_home" init "$remote" main; then pass "repository internals refused"; else fail "repository internals refused"; fi

# Status fetches remote metadata and reports the resulting divergence.
remote=$TMP/status-divergence.git; new_remote "$remote"; status_home=$TMP/home-status-divergence; mkdir -p "$status_home"; expect_ok run_dots "$status_home" init "$remote" main
remote_edit "$remote" "printf remote > \"\$1/.config/example/settings\"" || exit 1
status=$(run_dots "$status_home" status 2>&1)
if printf '%s\n' "$status" | grep -Fx 'initialized: yes' >/dev/null && printf '%s\n' "$status" | grep -Fx 'divergence: ahead 0, behind 1' >/dev/null; then pass "status divergence"; else fail "status divergence"; fi

# An incoming file this Mac already chose (for example shared by its own update, then
# edited again) cannot overwrite a differing live file.
remote=$TMP/incoming-collision.git; new_remote "$remote"; collision_home=$TMP/home-incoming-collision; mkdir -p "$collision_home"; expect_ok run_dots "$collision_home" init "$remote" main
mkdir -p "$collision_home/.config/example"; printf local >"$collision_home/.config/example/new"
printf 'use .config/example/new\n' >>"$collision_home/data/selection"
remote_edit "$remote" "printf '%s\\n' '.config/example/settings' '.config/example/new' > \"\$1/.config/dots/manifest\"; printf remote > \"\$1/.config/example/new\"" || exit 1
if ! run_sync "$collision_home" '' >/dev/null 2>&1 && test "$(cat "$collision_home/.config/example/new")" = local; then pass "incoming live collision"; else fail "incoming live collision"; fi

# After an update PR merges, the originating machine already has the new file; identical content syncs.
remote=$TMP/incoming-identical.git; new_remote "$remote"; identical_home=$TMP/home-incoming-identical; mkdir -p "$identical_home"; expect_ok run_dots "$identical_home" init "$remote" main
printf 'shell\n' >"$identical_home/.zshrc"
remote_edit "$remote" "printf '%s\\n' '.config/example/settings' '.zshrc' > \"\$1/.config/dots/manifest\"; printf 'shell\\n' > \"\$1/.zshrc\"" || exit 1
if run_sync "$identical_home" $'\n' >/dev/null 2>&1 && test "$(/usr/bin/git --git-dir="$identical_home/data/repo.git" rev-parse HEAD)" = "$(/usr/bin/git --git-dir="$remote" rev-parse main)" && test "$(cat "$identical_home/.zshrc")" = shell; then pass "incoming file identical to live file syncs"; else fail "incoming file identical to live file syncs"; fi

# A live symlink is refused during status, without following its target.
remote=$TMP/live-symlink.git; new_remote "$remote"; symlink_home=$TMP/home-live-symlink; mkdir -p "$symlink_home"; expect_ok run_dots "$symlink_home" init "$remote" main
rm "$symlink_home/.config/example/settings"; ln -s /tmp "$symlink_home/.config/example/settings"
if expect_fail run_dots "$symlink_home" status; then pass "live symlink refused"; else fail "live symlink refused"; fi

# Packaging emits all release assets and a portable checksum filename.
package_repo=$TMP/package-repo; /usr/bin/git clone -q "$ROOT" "$package_repo"; /usr/bin/git -C "$package_repo" config user.name test; /usr/bin/git -C "$package_repo" config user.email test@example.invalid; cp "$ROOT/scripts/package.sh" "$package_repo/scripts/package.sh"; /usr/bin/git -C "$package_repo" add scripts/package.sh; /usr/bin/git -C "$package_repo" commit -qm 'package test'; /usr/bin/git -C "$package_repo" tag v0.0.0-test
if "$package_repo/scripts/package.sh" v0.0.0-test >/dev/null 2>&1 && test -x "$package_repo/dist/dots" && test -x "$package_repo/dist/install.sh" && (cd "$package_repo/dist" && shasum -a 256 --check dots.sha256) >/dev/null 2>&1; then pass "release packaging"; else fail "release packaging"; fi

# The installer verifies release checksums before copying a binary.
assets=$TMP/release-assets; destination=$TMP/installed-bin; mkdir -p "$assets"; printf '#!/bin/sh\necho dots\n' >"$assets/dots"; shasum -a 256 "$assets/dots" >"$assets/dots.sha256"
if DOTS_RELEASE_BASE_URL="file://$assets" DOTS_BIN_DIR="$destination" "$ROOT/install.sh" >/dev/null 2>&1 && test -x "$destination/dots"; then pass "installer checksum success"; else fail "installer checksum success"; fi
printf tampered >"$assets/dots"
if ! DOTS_RELEASE_BASE_URL="file://$assets" DOTS_BIN_DIR="$TMP/unsafe-bin" "$ROOT/install.sh" >/dev/null 2>&1 && test ! -e "$TMP/unsafe-bin/dots"; then pass "installer checksum refusal"; else fail "installer checksum refusal"; fi

# A real installed gitleaks is exercised for one clean init when available.
if command -v gitleaks >/dev/null 2>&1; then
  remote=$TMP/real-scan.git; new_remote "$remote"; realhome=$TMP/home-real; mkdir -p "$realhome"
  if HOME=$realhome DOTS_DATA_DIR=$realhome/data GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid "$DOTS" init "$remote" main >/dev/null 2>&1; then pass "installed gitleaks integration"; else fail "installed gitleaks integration"; fi
else
  pass "installed gitleaks integration (unavailable, skipped)"
fi

printf '%s tests passed, %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
