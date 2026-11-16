# dots

Keep a hand-picked list of dotfiles in sync across your Macs and Linux machines through a private GitHub repository.

`dots` is a single-file Bash CLI for macOS and Linux. You choose exactly which files in your home directory are tracked, changes reach the repository as pull requests, and every other machine pulls them with one command.

- **Explicit allowlist.** Only the files listed in `~/.config/dots/manifest`, plus the manifest itself, are ever tracked. No directories, globs, or symlinks.
- **Each machine picks its own files.** Choose which shared files to bring to each machine, and change your mind later with `dots select`.
- **Your real home is the working tree.** Files stay where your tools expect them. No symlink farm, no copies.
- **Changes go through pull requests.** `dots update` opens a PR, so you review every change before it lands.
- **Secret scanning built in.** Incoming and outgoing content is scanned with [gitleaks](https://github.com/gitleaks/gitleaks) before anything is written or pushed.
- **Never overwrites silently.** A local file that differs is only replaced when you choose to, and `init` backs it up first.
- **Private repository, created for you.** `dots init` sets up `<your-github-account>/dotfiles` as a private repo.

## Requirements

- macOS, or Linux (Ubuntu or Debian)
- Git and Perl: on macOS, Apple's Command Line Tools (for `/usr/bin/git`); on Linux, the `git` on your `PATH` and `/usr/bin/perl`
- [gitleaks](https://github.com/gitleaks/gitleaks)
- [GitHub CLI](https://cli.github.com/) (`gh`), signed in

On macOS:

```sh
xcode-select --install
brew install gitleaks gh
gh auth login
```

On Linux, install Git, Perl and `expect` (used by the test suite) from apt:

```sh
sudo apt-get install git perl expect curl
```

gitleaks is not in apt; download its Linux release binary for your architecture (`x64` or `arm64`) from [its releases](https://github.com/gitleaks/gitleaks/releases), check it against the release's checksums file, and put `gitleaks` on your `PATH`. Install `gh` from [GitHub's apt repository](https://github.com/cli/cli/blob/trunk/docs/install_linux.md), then sign in:

```sh
gh auth login
```

## Install

```sh
curl -fsSL https://github.com/smarzban/dots/releases/latest/download/install.sh | sh
```

The same command installs on macOS and Linux. The installer verifies the release checksum (with `shasum` or `sha256sum`) and puts `dots` in `~/.local/bin`. A fresh Mac doesn't have that folder on its `PATH`, and neither may a Linux shell; the installer then prints the full-path command to run first and the line to add it to `PATH`, naming your shell's startup file.

To pin a version or choose another directory, set `DOTS_VERSION` or `DOTS_BIN_DIR`:

```sh
curl -fsSL https://github.com/smarzban/dots/releases/latest/download/install.sh | DOTS_VERSION=v0.1.0 DOTS_BIN_DIR="$HOME/bin" sh
```

## Quickstart: your first machine

1. Preview which files `dots` would suggest. This changes nothing:

   ```sh
   dots init --discover
   ```

2. Create the private `<your-account>/dotfiles` repository and connect this machine. `dots` asks before creating it:

   ```sh
   dots init
   ```

3. Give `dots` a commit identity. It deliberately ignores `~/.gitconfig`, so set this once on its own repository:

   ```sh
   git --git-dir="$HOME/.local/share/dots/repo.git" config user.name "Your Name"
   git --git-dir="$HOME/.local/share/dots/repo.git" config user.email "you@example.com"
   ```

4. Pick the files to share. `dots update` shows a checklist of files worth sharing (see [Which files are suggested](#which-files-are-suggested)). Tick the ones you want, confirm, and give the PR a title:

   ```sh
   dots update
   ```

5. Review and merge the pull request on GitHub, then bring this machine up to date:

   ```sh
   dots sync
   ```

## Add another machine

Install `dots` and its requirements, then connect to the same repository:

```sh
dots init
```

`init` shows a checklist of the files in the repository, all ticked. Untick any you don't want on this machine. The choice is remembered for every later sync, and you can change it any time with `dots select`.

If some chosen files already exist on this machine, identical ones are adopted as they are. To replace differing ones with the repository version, keeping a backup in `~/.local/share/dots/backups/`, run:

```sh
dots init --backup-existing
```

## Commands

**`dots status`**
Shows whether this machine is up to date, which files you've edited here and not sent yet, and which files changed in the repository and aren't here yet. Changes nothing.

**`dots sync`**
Brings this machine up to date with the repository. Run it whenever another machine shared something. Your edits are kept, and it only asks about a file when the repository changed that same file too (see [When a file changed on both sides](#when-a-file-changed-on-both-sides)).

**`dots update`**
Sends your changes to the repository as a pull request: edits to files you already share, new files you want to start sharing, and files you want to stop sharing. Nothing reaches the repository until you merge the PR on GitHub. Your files on this machine only change if the repository has something new, which `update` brings in first, as `sync` would. See [The update checklist](#the-update-checklist).

**`dots select`**
Chooses which of the repository's files this machine uses. Use it when a shared file doesn't belong on this machine (a work setting on your personal Mac, say): untick it here, and this machine stops syncing it while other machines keep it. Tick it again later to bring it back. Only affects this machine.

**`dots init`**
Connects a machine to your dotfiles repository, once per machine. On your first machine it creates the private `<your-account>/dotfiles` repository; on the others it asks which of its files to bring in. You can pass a different repository and branch: `dots init <remote> [branch]`.

**`dots init --backup-existing`**
Like `init`, for a machine that already has its own versions of your dotfiles: differing files are backed up to `~/.local/share/dots/backups/`, then replaced with the repository version.

**`dots init --discover`**
Lists the files `dots` would suggest sharing. Changes nothing.

### The update checklist

`dots update` shows up to four pages, in this order, skipping empty ones. Your edits are always on the first page.

| Page | What's on it | Ticked means |
|---|---|---|
| Edits to send | Shared files you changed (or deleted) on this machine | Send this edit. Untick to leave it out of this PR; your file stays as it is and shows up again next time. |
| New files | Files you haven't shared yet | Start sharing this file. |
| Shared files | Files you share and haven't changed | Keep sharing. Untick to stop sharing it on every machine (the file stays on disk). |
| Previously ignored | New files you left unticked before | Start sharing this file. |

After you confirm, `dots` lists exactly what the PR contains and asks for a title. If the repository has changes this machine doesn't have yet (for example your last PR, just merged), `update` brings them in first, as `sync` would. If a file changed on both sides, it stops and asks you to run `dots sync`.

Keys: Up/Down move, Left/Right change page, Space ticks, `a`/`n` tick all or none on the page, Enter confirms, `q` cancels. Without a full terminal, or with `DOTS_PLAIN_PROMPTS=1`, you get a numbered list instead: type numbers such as `1,3-5` to toggle them.

### When a file changed on both sides

`sync` handles each file on its own:

| You edited it here | The repository changed it | What happens |
|---|---|---|
| no | yes | You get the repository's version. |
| yes | no | Your edit is kept. `sync` reminds you to send it with `dots update`. |
| yes | yes, to the same thing | Nothing to do (for example your own PR, merged). |
| yes | yes, differently | `sync` asks about that file. |

When it asks, you choose per file:

1. **Use the repository's version.** Yours is backed up to `~/.local/share/dots/backups/` first.
2. **Keep yours.** This machine still catches up with everything else, and your version stays as an edit. Send it with `dots update` if it should replace the repository's, or keep it on this machine.

Your list of shared files (the manifest) is never asked about: lines added on either side are combined.

When another machine starts sharing a new file, `sync` asks whether to use it here. If you already have a different copy, it asks about it as above.

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

To tune the suggestions, create `~/.config/dots/discover` with one rule per line, then share it like any other file so every machine gets the same suggestions:

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
- Which of those files this machine uses, and which suggestions it ignored, is saved in `~/.local/share/dots/selection`. It stays on this machine and is never synced.
- Before anything is written or pushed, `dots` validates the repository contents against the manifest and scans them with gitleaks. Any problem stops the command without printing file contents.
- Your home folder is stored in the repository as the placeholder `@@DOTS_HOME@@`, and each machine writes its own home folder back in. A file naming `/Users/you/bin` works on a Mac whose home folder is `/Users/someone`, and on a Linux machine whose home folder is `/home/you`. A file that already contains the text `@@DOTS_HOME@@` is refused rather than changed.
- After you upgrade from an earlier version, the first `dots update` lists the files that contain your home folder as edits to send, once, so the repository stores them portably.
- Repositories written by this version carry a format marker, `.config/dots/format`, which older versions of `dots` refuse. Upgrade `dots` on every machine.

## Development

Keep `bin/dots` compatible with macOS `/bin/bash` 3.2 and BSD tools, and with Linux (bash 5, GNU tools): use only flags both share. Tests use temporary home directories and local remotes only.

```sh
/bin/bash -n bin/dots
shellcheck -S warning bin/dots install.sh
tests/run.sh
tests/linux.sh
git diff --check
```

`tests/linux.sh` runs the same suite in a throwaway `ubuntu:24.04` Docker container, as a non-root user with no global Git identity. It needs Docker and network access for apt. It copies in a bundle of this repository with its tags, plus your working tree's tracked files, so uncommitted edits are tested too.

To publish a release, tag the commit, build the assets, and upload `dist/dots`, `dist/dots.sha256`, and `dist/install.sh` to the GitHub release:

```sh
git tag -a v0.1.0 -m "dots v0.1.0"
scripts/package.sh v0.1.0
```

## License

[MIT](LICENSE)
