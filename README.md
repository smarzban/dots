# dots

Keep a hand-picked list of dotfiles in sync across your Macs through a private GitHub repository.

`dots` is a single-file Bash CLI for macOS. You choose exactly which files in your home directory are tracked, changes reach the repository as pull requests, and every other Mac pulls them with one command.

- **Explicit allowlist.** Only the files listed in `~/.config/dots/manifest`, plus the manifest itself, are ever tracked. No directories, globs, or symlinks.
- **Each Mac picks its own files.** Choose which shared files to bring to each Mac, and change your mind later with `dots select`.
- **Your real home is the working tree.** Files stay where your tools expect them. No symlink farm, no copies.
- **Changes go through pull requests.** `dots update` opens a PR, so you review every change before it lands.
- **Secret scanning built in.** Incoming and outgoing content is scanned with [gitleaks](https://github.com/gitleaks/gitleaks) before anything is written or pushed.
- **Never overwrites silently.** A local file that differs is only replaced when you choose to, and `init` backs it up first.
- **Private repository, created for you.** `dots init` sets up `<your-github-account>/dotfiles` as a private repo.

## Requirements

- macOS, with Apple's Command Line Tools (for `/usr/bin/git`)
- [gitleaks](https://github.com/gitleaks/gitleaks)
- [GitHub CLI](https://cli.github.com/) (`gh`), signed in

```sh
xcode-select --install
brew install gitleaks gh
gh auth login
```

## Install

```sh
curl -fsSL https://github.com/smarzban/dots/releases/latest/download/install.sh | sh
```

The installer verifies the release checksum and puts `dots` in `~/.local/bin`. Make sure that directory is on your `PATH`.

To pin a version or choose another directory, set `DOTS_VERSION` or `DOTS_BIN_DIR`:

```sh
curl -fsSL https://github.com/smarzban/dots/releases/latest/download/install.sh | DOTS_VERSION=v0.1.0 DOTS_BIN_DIR="$HOME/bin" sh
```

## Quickstart: your first Mac

1. Preview which files `dots` would suggest. This changes nothing:

   ```sh
   dots init --discover
   ```

2. Create the private `<your-account>/dotfiles` repository and connect this Mac. `dots` asks before creating it:

   ```sh
   dots init
   ```

3. Give `dots` a commit identity. It deliberately ignores `~/.gitconfig`, so set this once on its own repository:

   ```sh
   git --git-dir="$HOME/.local/share/dots/repo.git" config user.name "Your Name"
   git --git-dir="$HOME/.local/share/dots/repo.git" config user.email "you@example.com"
   ```

4. Pick the files to share. `dots update` opens a checklist of candidate files (see [Which files are suggested](#which-files-are-suggested)). Tick the ones you want, confirm, and give the PR a title. The checklist has up to three pages: new files, files you already share, and files you unticked before (empty pages are skipped), so later runs start with what is new:

   ```sh
   dots update
   ```

5. Review and merge the pull request on GitHub, then bring this Mac up to date:

   ```sh
   dots sync
   ```

## Add another Mac

Install `dots` and its requirements, then connect to the same repository:

```sh
dots init
```

`init` shows a checklist of the files in the repository, all ticked. Untick any you don't want on this Mac. The choice is remembered for every later sync, and you can change it any time with `dots select`.

If some chosen files already exist on this Mac, identical ones are adopted as they are. To replace differing ones with the repository version, keeping a backup in `~/.local/share/dots/backups/`, run:

```sh
dots init --backup-existing
```

## Everyday use

| You want to | Run |
|---|---|
| See what changed locally and whether the repository is ahead | `dots status` |
| Share a local change, or start sharing a new file | `dots update`, then merge the PR |
| Stop sharing a file on every Mac | `dots update`, untick it, then merge the PR |
| Choose which shared files this Mac uses | `dots select` |
| Get the latest configuration on this Mac | `dots sync` |

When another Mac starts sharing a new file, the next `dots sync` asks whether to use it here, and asks again before replacing a different local copy (which is backed up first). Your answer is remembered once that sync applies the repository configuration.

When `dots sync` finds local changes, it asks what to do:

1. Use the repository version and replace the local files
2. Keep the local files and change nothing
3. Create a PR from the local changes
4. Merge the repository changes into the local files only

If a merge conflicts, `dots` prints the path of a private workspace. Resolve and commit there with normal Git, then run:

```sh
dots sync --continue
```

## Commands

```text
dots init [--discover] [--backup-existing] [remote] [branch]
dots select
dots status
dots sync [--continue]
dots update
```

| Command | What it does |
|---|---|
| `init` | Connects this Mac to your repository and asks which files to bring here. With no arguments it uses `<your-account>/dotfiles`, creating it privately if needed. Pass a remote (and branch) to use a different repository, which must already contain a manifest. |
| `init --discover` | Lists candidate configuration files by name, without changing anything. |
| `init --backup-existing` | Backs up differing local files, then uses the repository version. |
| `select` | Changes which repository files this Mac uses. Newly chosen files are brought in; a differing local copy is backed up first, after you confirm. Unchosen files stay on disk but stop syncing. |
| `status` | Shows the branch, how far this Mac is ahead or behind, how many repository files this Mac uses, and which of them changed locally. |
| `sync` | Fetches, checks, and applies the repository configuration to the files this Mac uses. It only pushes if you choose to create a PR from local changes. |
| `update` | Opens a pull request with local changes, newly ticked files, and unticked files to remove from the repository. Its checklist shows new files first, then shared files, then previously ignored ones; unticked new files move to previously ignored. Never changes local files. |

In checklists, use Up/Down to move, Left/Right to change folder page, Space to toggle, `a` or `n` to tick all or none on the page, Enter to confirm, and `q` to cancel. Without a full terminal, or with `DOTS_PLAIN_PROMPTS=1`, `dots` shows a numbered list instead: type numbers such as `1,3-5` to toggle them.

## Which files are suggested

`dots` doesn't keep a list of tools. It suggests:

- dotfiles directly in your home folder, such as `.zshrc`, `.zprofile`, and `.gitconfig`
- every file under `~/.config`
- inside any other `~/.<name>` folder, files up to two levels deep whose names look like configuration (`.json`, `.toml`, `.yaml`, `.conf`, `.ini`, `.md`, `.sh`, `.lua`, names ending in `rc`, and similar)

Only small text files (up to 64 KB) are suggested. Always left out:

- keys and credentials: `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `.netrc`, `.npmrc`, and names containing `token`, `secret`, `auth`, `private`, `password`, or `mcp` (MCP server configs usually hold API keys)
- caches, logs, history, sessions, and similar machine-local state
- files inside a Git checkout, which belong to that project (unless an `include` rule names them, see below)

Whatever you tick is still scanned with gitleaks, using its default rules, before it is pushed.

To tune the suggestions, create `~/.config/dots/discover` with one rule per line, then share it like any other file so every Mac gets the same suggestions:

```text
# Folders deeper than the scan looks
include .pi/agent/agents/*
include .claude/skills/*/SKILL.md
# Things you never want suggested
exclude .config/some-app/*
```

Patterns are relative to your home folder and `*` also matches `/`. Write out the first folder (`.claude/…`, not `.*/…`); a pattern without a folder matches files directly in your home folder. Exclusions win over includes. An include can reach into a Git checkout (for example a folder you used to sync with its own repository), but the built-in credential and state exclusions always apply.

## How it works

- Git metadata lives in `~/.local/share/dots/repo.git`. Your home directory is its working tree.
- The manifest at `~/.config/dots/manifest` lists one relative path per line. `#` comments and blank lines are allowed:

  ```text
  # Shell and Git
  .zshrc
  .gitconfig
  .config/starship.toml
  ```

- Paths must be plain files inside your home directory: no absolute paths, `..`, globs, whitespace, or symlinks.
- Which of those files this Mac uses, and which suggestions it ignored, is saved in `~/.local/share/dots/selection`. It stays on this Mac and is never synced.
- Before anything is written or pushed, `dots` validates the repository contents against the manifest and scans them with gitleaks. Any problem stops the command without printing file contents.

## Development

Keep `bin/dots` compatible with macOS `/bin/bash` 3.2. Tests use temporary home directories and local remotes only.

```sh
/bin/bash -n bin/dots
shellcheck -S warning bin/dots
tests/run.sh
git diff --check
```

To publish a release, tag the commit, build the assets, and upload `dist/dots`, `dist/dots.sha256`, and `dist/install.sh` to the GitHub release:

```sh
git tag -a v0.1.0 -m "dots v0.1.0"
scripts/package.sh v0.1.0
```
