#!/bin/bash
# Run tests/run.sh in a throwaway ubuntu:24.04 container: tests/linux.sh
#
# The container gets a bundle of this repository (every ref, so tags such as
# v0.2.3 are there) with the working tree's tracked files laid over it, so
# uncommitted edits are tested too. Inside, apt installs git, perl, expect and
# curl (the installer tests fetch file:// URLs), and a non-root user with no
# global Git identity runs the suite.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
IMAGE=${DOTS_LINUX_IMAGE:-ubuntu:24.04}
command -v docker >/dev/null 2>&1 || { echo "tests/linux.sh needs docker" >&2; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/dots-linux.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

git -C "$ROOT" bundle create "$TMP/dots.bundle" --all 2>/dev/null || { echo "could not bundle the repository" >&2; exit 1; }
git -C "$ROOT" rev-parse HEAD >"$TMP/head" || exit 1
(cd "$ROOT" && git ls-files -z | tar --null -T - -cf "$TMP/tree.tar") || { echo "could not pack the working tree" >&2; exit 1; }
chmod 644 "$TMP/dots.bundle" "$TMP/tree.tar" "$TMP/head"
chmod 755 "$TMP"

cat >"$TMP/inside.sh" <<'EOF'
set -u
export DEBIAN_FRONTEND=noninteractive
{ apt-get update -qq && apt-get install -y -qq --no-install-recommends git perl expect curl; } >/tmp/apt.log 2>&1 || { cat /tmp/apt.log >&2; echo "apt-get failed" >&2; exit 1; }
useradd -m dotstest || exit 1
su dotstest -c '
  set -u
  git clone -q --no-checkout /in/dots.bundle "$HOME/dots" || exit 1
  git -C "$HOME/dots" checkout -q -b linux-test "$(cat /in/head)" || exit 1
  tar --warning=no-unknown-keyword -xf /in/tree.tar -C "$HOME/dots" || exit 1
  if git config --global --get user.email >/dev/null; then echo "a global Git identity is set" >&2; exit 1; fi
  "$HOME/dots/tests/run.sh"
'
EOF

docker run --rm -v "$TMP:/in:ro" "$IMAGE" /bin/sh /in/inside.sh
