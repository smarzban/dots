#!/bin/bash
# No test touches the caller's HOME, data directory, or network remotes.
set -u

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
  repo:view) if [ "${DOTS_TEST_GH_PUBLIC:-0}" = 1 ]; then printf '%s\n' false; else exit 1; fi ;;
  repo:create) printf '%s\n' "$*" >>"$DOTS_TEST_GH_LOG"; /usr/bin/git init -q --bare "$DOTS_TEST_GH_REMOTE" ;;
  *) exit 2 ;;
esac
EOF
  cat >"$MOCK_GIT" <<'EOF'
#!/bin/sh
# Map the derived GitHub HTTPS URL to the test-local bare remote.
if [ "$1" = clone ] && [ "${4:-}" = https://github.com/example/dotfiles.git ]; then
  exec /usr/bin/git clone "$2" "$3" "$DOTS_TEST_GH_REMOTE" "$5"
fi
if [ "$1" = -C ] && [ "${3:-}" = remote ] && [ "${4:-}" = add ] && [ "${6:-}" = https://github.com/example/dotfiles.git ]; then
  exec /usr/bin/git -C "$2" remote add "$5" "$DOTS_TEST_GH_REMOTE"
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
  (sleep 3; printf '%s' "$input") | HOME=$home DOTS_DATA_DIR=$home/data DOTS_GITLEAKS=$MOCK GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid /usr/bin/script -q /dev/null /bin/sh -c "$DOTS sync"
}

run_default_init() {
  home=$1
  remote=$2
  (sleep 3; printf 'y\n') | HOME=$home DOTS_DATA_DIR=$home/data DOTS_GITLEAKS=$MOCK DOTS_GH=$MOCK_GH DOTS_DEFAULT_REMOTE=$remote DOTS_DEFAULT_GITHUB_REPO=smarzban/dotfiles DOTS_TEST_GH_REMOTE=$remote GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid /usr/bin/script -q /dev/null /bin/sh -c "$DOTS init"
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
  (sleep 3; printf '%s' "$response") | HOME=$home DOTS_DATA_DIR=$home/data DOTS_GITLEAKS=$MOCK DOTS_GH=$MOCK_GH DOTS_GIT=$MOCK_GIT DOTS_TEST_GH_REMOTE=$remote DOTS_TEST_GH_LOG=$log GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid /usr/bin/script -q /dev/null /bin/sh -c "$DOTS init"
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
home=$TMP/home-idempotent; mkdir -p "$home"
if expect_ok run_dots "$home" init "$remote" main && expect_ok run_dots "$home" init "$remote" main; then pass "idempotent init"; else fail "idempotent init"; fi

# status scopes itself to the allowlist and never reports an unrelated home file.
printf private >"$home/private-token"
status=$(run_dots "$home" status 2>&1 || true)
if printf '%s' "$status" | grep -F private-token >/dev/null; then fail "unrelated-home privacy"; else pass "unrelated-home privacy"; fi
# Git's empty pathspec (`:`) must never turn a manifest entry into a broad operation.
printf ':\n' >"$home/.config/dots/manifest"
if expect_fail run_dots "$home" status; then pass "pathspec manifest attack"; else fail "pathspec manifest attack"; fi
printf '%s\n' '.config/example/settings' >"$home/.config/dots/manifest"

# Exact-path staging: an unrelated file cannot enter a local commit.
printf local >"$home/.config/example/settings"; printf unrelated >"$home/not-approved"
if run_sync "$home" $'y\nlocal change\n' >/dev/null 2>&1 && ! /usr/bin/git --git-dir="$home/data/repo.git" ls-tree -r --name-only HEAD | grep -F not-approved >/dev/null; then pass "exact-path staging"; else fail "exact-path staging"; fi

# Cancellation creates no history.
before=$(/usr/bin/git --git-dir="$home/data/repo.git" rev-parse HEAD); printf cancelled >"$home/.config/example/settings"
if run_sync "$home" $'n\n' >/dev/null 2>&1 && test "$before" = "$(/usr/bin/git --git-dir="$home/data/repo.git" rev-parse HEAD)"; then pass "cancellation"; else fail "cancellation"; fi

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

# Conflict preflight is followed by the real Git conflict state, with no auto-resolution.
remote=$TMP/conflict.git; new_remote "$remote"; a=$TMP/home-a; b=$TMP/home-b; mkdir -p "$a" "$b"; expect_ok run_dots "$a" init "$remote" main; expect_ok run_dots "$b" init "$remote" main
# Prepare B's local history without pushing, then let A push a conflicting history.
printf two >"$b/.config/example/settings"
/usr/bin/git --git-dir="$b/data/repo.git" --work-tree="$b" add -- .config/example/settings
GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid /usr/bin/git --git-dir="$b/data/repo.git" --work-tree="$b" commit -qm 'b local' || exit 1
printf one >"$a/.config/example/settings"; run_sync "$a" $'y\na change\n' >/dev/null 2>&1 || exit 1
if ! run_sync "$b" '' >/dev/null 2>&1 && /usr/bin/git --git-dir="$b/data/repo.git" diff --cached --name-only --diff-filter=U | grep -Fx .config/example/settings >/dev/null; then pass "conflict preservation"; else fail "conflict preservation"; fi

# Two clean homes can exchange an allowlisted change through the local remote.
remote=$TMP/two-machine.git; new_remote "$remote"; one=$TMP/home-one; two=$TMP/home-two; mkdir -p "$one" "$two"; expect_ok run_dots "$one" init "$remote" main; expect_ok run_dots "$two" init "$remote" main
printf synced >"$one/.config/example/settings"; run_sync "$one" $'y\nsync one\n' >/dev/null 2>&1 || exit 1
if run_sync "$two" '' >/dev/null 2>&1 && test "$(cat "$two/.config/example/settings")" = synced; then pass "successful two-machine sync"; else fail "successful two-machine sync"; fi

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

# An incoming allowlisted file cannot overwrite a live untracked file.
remote=$TMP/incoming-collision.git; new_remote "$remote"; collision_home=$TMP/home-incoming-collision; mkdir -p "$collision_home"; expect_ok run_dots "$collision_home" init "$remote" main
mkdir -p "$collision_home/.config/example"; printf local >"$collision_home/.config/example/new"
remote_edit "$remote" "printf '%s\\n' '.config/example/settings' '.config/example/new' > \"\$1/.config/dots/manifest\"; printf remote > \"\$1/.config/example/new\"" || exit 1
if ! run_sync "$collision_home" '' >/dev/null 2>&1 && test "$(cat "$collision_home/.config/example/new")" = local; then pass "incoming live collision"; else fail "incoming live collision"; fi

# Removing a manifest entry untracks it but never deletes the existing live file.
remote=$TMP/removal.git; new_remote "$remote"; removal_home=$TMP/home-removal; mkdir -p "$removal_home"; expect_ok run_dots "$removal_home" init "$remote" main
: >"$removal_home/.config/dots/manifest"
if run_sync "$removal_home" $'y\nremove approved file\n' >/dev/null 2>&1 && test -f "$removal_home/.config/example/settings" && ! /usr/bin/git --git-dir="$removal_home/data/repo.git" ls-tree -r --name-only HEAD | grep -Fx .config/example/settings >/dev/null; then pass "manifest removal preserves live file"; else fail "manifest removal preserves live file"; fi

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
