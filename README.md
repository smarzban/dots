# dots

`dots` is a small, allowlist-only macOS shell CLI for keeping selected live files in `$HOME` in a Git repository. It has three commands: `init`, `status`, and foreground-only `sync`.

It is intentionally not a replacement for chezmoi or yadm. Snapshots, restore, cloud services, background work, templates, encryption, plugins, and auth transfer are out of scope.

## Install

After a release is published, install the checksum-verified release asset:

```sh
curl -fsSL https://github.com/smarzban/dots/releases/latest/download/install.sh | sh
```

It installs `dots` to `~/.local/bin`; ensure that directory is on your `PATH`. To select a release or destination, set `DOTS_VERSION=v0.1.0` or `DOTS_BIN_DIR=/some/bin` before running the installer.

The command requires `/usr/bin/git` and `gitleaks` at runtime. For commits and non-fast-forward merges, provide Git identity through `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL` or repository-local config, `git --git-dir="$HOME/.local/share/dots/repo.git" config user.name "Your Name"` (and `user.email`). `dots` deliberately ignores `$HOME/.gitconfig` while running Git, so a managed configuration file cannot alter its own operations.

## Repository model

Git metadata is stored separately at `~/.local/share/dots/repo.git`. Your real `$HOME` is the worktree. The tracked `.config/dots/manifest` is the authority for configuration paths.

A manifest contains one relative file path per line. Blank lines and `#` comments are allowed. Paths may not be absolute, contain `..`, globs, whitespace, controls, duplicates, directories, or symlinks. A listed directory does not approve its descendants. The manifest itself is tracked as special metadata.

```text
# Explicit files only
.gitconfig
.config/example/settings.toml
```

For the default private configuration repository, run this from a terminal:

```sh
dots init
```

`dots` derives the authenticated GitHub account from `gh`, then uses `<account>/dotfiles`. If that repository is missing, it asks before creating it privately. It seeds only an empty versioned manifest, then offers an opt-in, names-only scan for likely configuration files. You select exact numbered paths and confirm the manifest preview, `dots` never adopts files automatically. To rerun it later, use `dots init --discover`. `gh` is needed only for no-argument initialization and automatic creation.

You can also initialize an existing repository:

```sh
dots init git@github.com:example/config.git main
dots status
dots sync
```

An existing configuration repository must already contain a valid manifest. `init` clones into its private data location, validates the remote tree and manifest, scans it with gitleaks, and refuses any existing target collision before it checks out only approved paths. Running the same `init` again is a no-op. A different remote or branch is refused.

`status` validates both the repository and live manifest, fetches only remote metadata for an accurate ahead/behind report, then reports only allowlisted files. It never runs an unscoped home-directory status.

`sync` scans local approved candidates before showing a content-free exact path summary. It requires a terminal confirmation and commit message, stages only manifest-derived paths, fetches without applying, validates and scans the incoming revision, preflights the merged result in a temporary clone, then integrates and pushes. It never force-pushes or resolves a conflict. A conflict is left in normal Git conflict state for manual resolution.

## Safety boundaries and caveats

Incoming paths, manifests, revision names, and filenames are treated as untrusted. Any invalid manifest/tree, symlink, unapproved tracked file, credential scan failure, collision, or unsafe parent fails closed without printing file contents or scanner findings.

All checkable preflight happens before `$HOME` is changed. A disk, permission, or process failure while Git is actually checking out or merging can still interrupt multi-file filesystem changes, Git's normal recovery state is retained in that case. `gitleaks` reduces accidental secret commits, it is not a proof that a value is non-sensitive.

## Publishing a release

Maintainers tag the release commit, create the assets from that clean checkout, then upload `dist/dots`, `dist/dots.sha256`, and `dist/install.sh` to the matching GitHub release:

```sh
git tag v0.1.0
scripts/package.sh v0.1.0
```

## Verification

```sh
/bin/bash -n bin/dots
shellcheck -S warning bin/dots
tests/run.sh
git diff --check
```
