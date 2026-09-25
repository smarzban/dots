#!/bin/sh
# Install a released dots binary into ~/.local/bin without changing configuration.
set -eu

REPOSITORY=${DOTS_RELEASE_REPOSITORY:-smarzban/dots}
DESTINATION=${DOTS_BIN_DIR:-"$HOME/.local/bin"}
VERSION=${DOTS_VERSION:-latest}

command -v curl >/dev/null 2>&1 || { printf '%s\n' 'dots installer: curl is required' >&2; exit 1; }
command -v shasum >/dev/null 2>&1 || { printf '%s\n' 'dots installer: shasum is required' >&2; exit 1; }

temp=$(mktemp -d "${TMPDIR:-/tmp}/dots-install.XXXXXX") || exit 1
trap 'rm -rf "$temp"' EXIT HUP INT TERM

if test -n "${DOTS_RELEASE_BASE_URL:-}"; then
  base=$DOTS_RELEASE_BASE_URL
else
  case $VERSION in
    latest) base="https://github.com/$REPOSITORY/releases/latest/download" ;;
    *) base="https://github.com/$REPOSITORY/releases/download/$VERSION" ;;
  esac
fi

curl --fail --location --silent --show-error "$base/dots" -o "$temp/dots"
curl --fail --location --silent --show-error "$base/dots.sha256" -o "$temp/dots.sha256"
expected=$(awk 'NR == 1 { print $1 }' "$temp/dots.sha256")
actual=$(shasum -a 256 "$temp/dots" | awk '{ print $1 }')
test -n "$expected" && test "$expected" = "$actual" || { printf '%s\n' 'dots installer: checksum verification failed' >&2; exit 1; }

mkdir -p "$DESTINATION"
install -m 755 "$temp/dots" "$DESTINATION/dots"
printf 'Installed dots to %s/dots\n' "$DESTINATION"

# The shell only finds commands in PATH folders, and a fresh Mac does not list
# ~/.local/bin, so say how to run dots rather than leave "command not found".
case $DESTINATION in
  "$HOME"/*) shown="\$HOME/${DESTINATION#"$HOME"/}" ;;
  *) shown=$DESTINATION ;;
esac
case ":$PATH:" in
  *":$DESTINATION:"*|*":$DESTINATION/:"*)
    found=$(command -v dots 2>/dev/null || true)
    if test -n "$found" && test "$found" != "$DESTINATION/dots"; then
      printf 'Note: %s comes first on your PATH, so "dots" runs that copy. Remove it, or run %s/dots.\n' "$found" "$DESTINATION"
    fi ;;
  *)
    printf '%s is not on your PATH, so the dots command will not be found. Either:\n' "$DESTINATION"
    printf '  run it by full path:  %s/dots init\n' "$DESTINATION"
    printf '  or add it to PATH:    echo '"'"'export PATH="%s:$PATH"'"'"' >> ~/.zprofile && exec zsh\n' "$shown" ;;
esac
