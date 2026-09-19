#!/bin/sh
# Build the three assets uploaded to a GitHub release.
set -eu

VERSION=${1:?usage: scripts/package.sh <version>}
case $VERSION in v[0-9]*|[0-9]*) ;; *) printf '%s\n' 'package: version must start with a number or v followed by a number' >&2; exit 2 ;; esac

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"
test -z "$(git status --porcelain)" || { printf '%s\n' 'package: working tree must be clean' >&2; exit 1; }
tag_commit=$(git rev-parse -q --verify "$VERSION^{commit}") || { printf '%s\n' "package: tag $VERSION is required" >&2; exit 1; }
test "$tag_commit" = "$(git rev-parse HEAD)" || { printf '%s\n' "package: tag $VERSION must identify HEAD" >&2; exit 1; }

DIST=$ROOT/dist
rm -rf "$DIST"
mkdir -p "$DIST"
cp "$ROOT/bin/dots" "$DIST/dots"
chmod 755 "$DIST/dots"
shasum -a 256 "$DIST/dots" >"$DIST/dots.sha256"
cp "$ROOT/install.sh" "$DIST/install.sh"
printf 'Release assets for %s are in %s\n' "$VERSION" "$DIST"
