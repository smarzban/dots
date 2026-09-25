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
# PATH entries are compared without trailing slashes, and an empty entry means the
# current folder, as the shell treats it.
strip_slashes() {
  s_dir=$1
  while test "${#s_dir}" -gt 1 && test "${s_dir%/}" != "$s_dir"; do s_dir=${s_dir%/}; done
  printf '%s' "$s_dir"
}
destination=$(strip_slashes "$DESTINATION")
on_path=false
first_dots=
old_ifs=$IFS
IFS=:
# No globbing while splitting, and a trailing ":" is one more empty entry.
set -f
path_entries=$PATH
case $path_entries in *:) path_entries="$path_entries:." ;; esac
for entry in $path_entries""; do
  test -n "$entry" && test "$entry" != . || entry=$PWD
  entry=$(strip_slashes "$entry")
  test "$entry" = "$destination" && on_path=true
  if test -z "$first_dots" && test -f "$entry/dots" && test -x "$entry/dots"; then first_dots=$entry; fi
done
IFS=$old_ifs
set +f
if test "$on_path" = true; then
  if test -n "$first_dots" && test "$first_dots" != "$destination"; then
    printf 'Note: %s/dots comes first on your PATH, so the dots command runs that copy. Remove it, or run the one just installed by its full path.\n' "$first_dots"
  fi
else
  printf '%s is not on your PATH, so the dots command will not be found.\n' "$destination"
  # Copy-paste commands only for plain folder names; anything else is described.
  case $destination in
    *[!A-Za-z0-9._/-]*)
      printf 'Run dots by its full path, or add that folder to PATH in ~/.zprofile.\n' ;;
    *)
      case $destination in
        "$HOME"/*) shown="\$HOME/${destination#"$HOME"/}" ;;
        *) shown=$destination ;;
      esac
      printf 'Either:\n'
      printf '  run it by full path:  %s/dots init\n' "$destination"
      printf '  or add it to PATH:    echo '"'"'export PATH="%s:$PATH"'"'"' >> ~/.zprofile && exec zsh -l\n' "$shown" ;;
  esac
fi
