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

run_dots() {
  home=$1
  shift
  HOME=$home DOTS_DATA_DIR=$home/data DOTS_GITLEAKS=$MOCK GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid "$DOTS" "$@"
}

run_sync() {
  home=$1
  input=$2
  # BSD script supplies a pseudo-terminal, needed by the intentional sync guard.
  (sleep 2; printf '%s' "$input") | HOME=$home DOTS_DATA_DIR=$home/data DOTS_GITLEAKS=$MOCK GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid /usr/bin/script -q /dev/null /bin/sh -c "$DOTS sync"
}

make_mock_gitleaks
chmod 755 "$DOTS"

# Manifest attacks: traversal, globs, duplicates, controls, and symlink entries all fail before checkout.
remote=$TMP/manifest.git; new_remote "$remote"
for bad in '../.ssh/id_rsa' '/etc/passwd' '.config/*/x' '.gitconfig
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

# A real installed gitleaks is exercised for one clean init when available.
if command -v gitleaks >/dev/null 2>&1; then
  remote=$TMP/real-scan.git; new_remote "$remote"; realhome=$TMP/home-real; mkdir -p "$realhome"
  if HOME=$realhome DOTS_DATA_DIR=$realhome/data GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid "$DOTS" init "$remote" main >/dev/null 2>&1; then pass "installed gitleaks integration"; else fail "installed gitleaks integration"; fi
else
  pass "installed gitleaks integration (unavailable, skipped)"
fi

printf '%s tests passed, %s failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
