# dots

Keep a hand-picked list of dotfiles in sync across your Macs through a private GitHub repository.

`dots` is a single-file Bash CLI for macOS. You choose exactly which files in your home directory are tracked, changes reach the repository as pull requests, and every other Mac pulls them with one command.

- **Explicit allowlist.** Only the files listed in `~/.config/dots/manifest`, plus the manifest itself, are ever tracked. No directories, globs, or symlinks.
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

4. Pick the files to track. `dots update` lists candidates by name, you choose them (for example `1,3-5`), confirm, and give the PR a title:

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

If some tracked files already exist on this Mac, identical ones are adopted as they are. To replace differing ones with the repository version, keeping a backup in `~/.local/share/dots/backups/`, run:

```sh
dots init --backup-existing
```

## Everyday use

| You want to | Run |
|---|---|
| See what changed locally and whether the repository is ahead | `dots status` |
| Share a local change, or start tracking a new file | `dots update`, then merge the PR |
| Get the latest configuration on this Mac | `dots sync` |

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
dots status
dots sync [--continue]
dots update
```

| Command | What it does |
|---|---|
| `init` | Connects this Mac to your repository. With no arguments it uses `<your-account>/dotfiles`, creating it privately if needed. Pass a remote (and branch) to use a different repository, which must already contain a manifest. |
| `init --discover` | Lists candidate configuration files by name, without changing anything. |
| `init --backup-existing` | Backs up differing local files, then uses the repository version. |
| `status` | Shows the branch, how far this Mac is ahead or behind, and which tracked files changed locally. |
| `sync` | Fetches, checks, and applies the repository configuration. It only pushes if you choose to create a PR from local changes. |
| `update` | Opens a pull request with local changes and any newly selected files. Never changes local files. |

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
