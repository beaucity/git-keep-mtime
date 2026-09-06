# Git Keep MTime

**Git Keep MTime** preserves filesystem modification times (`mtime`) when working with Git.

Git tracks file content and history, but filesystem `mtime` is not part of a Git tree. As a result, operations such as switching branches or checking out another commit can change the contents of files without restoring the modification times that those files had at the target revision.

Git Keep MTime records file modification times as Git Notes and synchronizes the working tree after relevant Git operations.

The most useful case is simple:

```text
branch A                         branch B
  a.txt                           a.txt
  mtime = T1                      mtime = T2
       │                               │
       └──── git switch ──────────────┘
                       ↓
                 working tree
                 mtime follows
                 the target commit
```

After `git switch` or `git checkout`, files can regain the modification times associated with the target commit instead of receiving only the filesystem timestamps produced by Git's checkout operation.

> **Status:** v0.1.3-alpha. This is an early release and should be considered experimental.

## Why Git Keep MTime?

Filesystem modification time is useful to many tools and workflows. A Git checkout normally restores file contents, but it does not preserve the original filesystem `mtime` from the historical working tree.

For projects where `mtime` carries useful information, this can be inconvenient. Git Keep MTime adds that information without changing Git's normal object format:

- Git continues to store files and history normally.
- KMT stores mtime metadata separately in Git Notes.
- KMT synchronizes the working tree mtime when the relevant Git state changes.

## Key Features

- Preserve file `mtime` across Git branch switches and checkouts.
- Synchronize mtime after relevant Git operations such as `switch`, `checkout`, `reset`, `revert`, `merge`, `pull`, and `restore`.
- Track mtime changes incrementally rather than rebuilding all metadata for every commit.
- Store KMT metadata in a dedicated Git Notes namespace.
- Support completing missing historical mtime metadata from a working tree that still has the original timestamps.
- Detect mtime conflicts and unsafe synchronization cases instead of silently overwriting them.
- Implemented as a POSIX shell program.

## How It Works

KMT uses the Git Notes namespace:

```text
refs/notes/kmt/mtime
```

Each relevant Git commit has an associated KMT note containing the file mtime information needed to reconstruct the working-tree state.

KMT also maintains internal note files while calculating and processing metadata. These are implementation details; users normally interact with KMT through `git` commands after installation.

### Note entry format

A file entry is represented conceptually as:

```text
<STX>filename<ETX>mtime
```

where:

- `<STX>` marks the beginning of an entry.
- `filename` is the repository-relative path.
- `<ETX>` separates the filename from the Unix timestamp.
- `mtime` is the filesystem modification time represented as a Unix timestamp.

The leading `<STX>` is intentional. It allows KMT to locate an exact file entry efficiently with a fixed-string search such as:

```sh
grep -m 1 -F "<STX>filename<ETX>"
```

This avoids ambiguous prefix matches and is important for fast metadata lookup.

## Installation

The GitHub release uses `shell/git_kmt.sh` as the public KMT program.

From the repository root:

```sh
chmod +x shell/git_kmt.sh
./shell/git_kmt.sh kmt-install
```

Installation places the KMT wrapper into the command path and keeps the original Git executable available behind the wrapper.

### Development / link installation

The installer also supports its link mode:

```sh
./shell/git_kmt.sh kmt-install --link
```

This is useful when developing KMT from a working source tree because the installed KMT entry can point back to the source script.

## Quick Start

### 1. Install KMT

```sh
chmod +x shell/git_kmt.sh
./shell/git_kmt.sh kmt-install
```

### 2. Work with Git normally

After installation, use normal Git commands:

```sh
git add .
git commit -m "Update files"
git switch another-branch
git checkout <commit-or-branch>
```

KMT intercepts the Git operations it needs to handle and performs the corresponding mtime processing automatically.

### 3. Complete existing history when needed

For a repository that already contains history, KMT metadata may not exist for all historical files. If the working tree still contains useful/original mtimes, inspect the repository first:

```sh
git kmt-scan
```

Then complete missing metadata:

```sh
git kmt-complete
```

After metadata has been completed, it can be synchronized from the repository:

```sh
git kmt-synchronize
```

## KMT Commands

The main user-facing commands in this release are:

| Command | Purpose |
|---|---|
| `git kmt-scan` | Scan files and report KMT/mtime status. |
| `git kmt-complete` | Complete missing KMT metadata using current local file mtimes. |
| `git kmt-synchronize` | Synchronize local file mtimes from repository metadata. |
| `git kmt-resolve` | Resolve mtime conflicts by using local file mtimes. |
| `git kmt-version` | Show the installed KMT version. |
| `./shell/git_kmt.sh kmt-install` | Install KMT. |
| `./shell/git_kmt.sh kmt-upgrade` | Upgrade KMT. |
| `git kmt-uninstall` | Uninstall KMT. |

`kmt-note` is intentionally not documented as a public command in this release. Its inspection functionality is still being developed and will be documented when it becomes sufficiently stable.

## Git Operations

KMT integrates with Git operations that can change the working tree or commit history, including:

- `add`
- `rm`
- `rename`
- `commit`
- `merge`
- `restore`
- `revert`
- `reset`
- `rebase`
- `switch`
- `checkout`
- `pull`
- `push`

The most important user-visible behavior is synchronization after a change of the checked-out Git state. For example:

```sh
git switch feature-a
```

or:

```sh
git checkout <commit>
```

KMT detects the resulting HEAD change and synchronizes the affected files using the mtime metadata associated with the target history.

## Git Notes and Remotes

KMT uses a dedicated notes ref:

```text
refs/notes/kmt/mtime
```

The KMT wrapper also integrates this notes ref with normal `git push` and `git pull` operations for the default `origin` remote, so mtime metadata can travel with the repository's Git history.

When moving an existing repository or manually working with remotes, make sure the KMT notes ref is available on the target repository as well as the normal Git commits.

## Existing Repositories

Installing KMT does **not** automatically create complete mtime metadata for every historical file.

For an existing repository, the important distinction is:

```text
install KMT
     ↓
existing working tree
     ↓
scan metadata status
     ↓
complete missing metadata when possible
     ↓
future Git operations maintain KMT metadata
```

`kmt-complete` uses the current filesystem mtime as the source for missing metadata. Therefore, it should be run only when the current working-tree timestamps are still the timestamps you want to preserve.

KMT also checks for conditions that make completion or synchronization unsafe. Files with unresolved mtime conflicts should be handled explicitly rather than silently overwritten.

## Installation, Upgrade, and Uninstall Rules

There is an intentional distinction between the installation script and the installed Git command.

### Install

Run through the source script:

```sh
./shell/git_kmt.sh kmt-install
```

### Upgrade

Run through the source script:

```sh
./shell/git_kmt.sh kmt-upgrade
```

### Uninstall

Once installed, uninstall through Git:

```sh
git kmt-uninstall
```

Do not use `./shell/git_kmt.sh kmt-uninstall` as the normal uninstall command.

## Limitations and Alpha Status

v0.1.3 is an alpha release. The following areas should be considered subject to further development and testing:

- Rename-following mtime history is not yet fully implemented.
- Complex Git histories and less common combinations of Git operations require continued testing.
- KMT metadata is separate from normal Git tree objects and therefore must be transferred through the KMT notes ref.
- Existing repositories may require an explicit metadata completion step.
- Platform-specific filesystem timestamp behavior can differ between operating systems.
- `kmt-note` exists in the program but its user-facing inspection interface is not yet considered stable and is intentionally omitted from this README.

## Architecture and Storage

For implementation details, see:

- [Architecture](docs/Architecture.md)
- [Usage](docs/Usage.md)
- [Storage](docs/Storage.md)

## License

License information should be added here when the project license is finalized.

## Version

**Git Keep MTime v0.1.3-alpha**
