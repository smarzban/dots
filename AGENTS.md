# Project guidance

`dots` is a single-file Bash CLI (`bin/dots`) that syncs an allowlist of dotfiles between Macs through a private GitHub repository.

## Constraints
- macOS `/bin/bash` 3.2 and BSD userland only.
- Fail closed: validate the repository tree, scan with gitleaks, and refuse rather than guess. Never print file contents or secret values.
- Allowlist only: nothing outside the manifest is staged, written, or pushed.
- Tests use temporary homes and local bare remotes only, never a real home or network remote.

## Verify before publishing
`/bin/bash -n bin/dots`, `shellcheck -S warning bin/dots install.sh`, `tests/run.sh` (about a minute), `git diff --check`. Check that a new test fails without its fix before trusting it.

## Easy to break
- `git_repo` runs Git from HOME: inside a work tree, pathspecs are relative to the current folder.
- gitleaks always goes through `run_gitleaks` (a private config extending the default rules, an empty `--gitleaks-ignore-path`). `--config /dev/null` loads no rules at all.
- `sync` is a per-file three-way catch-up (this Mac, last synced HEAD, remote). Only files changed differently on both sides are asked about; the manifest is merged, never asked about. `update` catches up first and stops on a clash.
- No `set -e` and no `pipefail`: check every return, and write command output to a file before transforming it.
- Shell functions have no locals: helper variables carry prefixes (`cu_`, `dc_`, `ac_`, ...) so they cannot clobber callers.
- `write_selection use skip manifest [pending] [ignore]`: omitting pending drops pending entries; omitting ignore keeps the saved ones.

## Tests
- `tests/drive.expect` types answers when a prompt ending in `: ` or `] ` appears; new prompts must end that way.
- Write Tcl `expect { ... }` blocks multi-line; a one-line block is one literal pattern and silently times out.
- Plain lists come from `DOTS_PLAIN_PROMPTS=1` or `TERM=dumb`; arrow-key UI tests need `set stty_init "rows 30 columns 100"`.
- The git mock only redirects pushes to `https://github.com/example/dotfiles.git` and logs fetch credential settings; the gh mock only answers `pr list` scoped to `example/dotfiles`.
- The `run_*` helpers set `home`; call them in a subshell when not capturing output, or later tests use the wrong home.
- In `case` patterns, adjacent quoted pieces around `*` cannot share one space.

## Releasing
Tag `vX.Y.Z`, run `scripts/package.sh vX.Y.Z`, then `gh release create vX.Y.Z "$PWD/dist/dots" "$PWD/dist/dots.sha256" "$PWD/dist/install.sh" --verify-tag --notes-file <notes>`, and check that the README `curl` install matches `bin/dots`.
