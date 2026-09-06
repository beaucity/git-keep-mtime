# Git Keep MTime Usage

## 1. Requirements

Git Keep MTime v0.1.3-alpha is implemented as a POSIX shell program and is intended to run in a Unix-like environment with Git and the standard command-line utilities used by the script.

The release entry point is:

```text
shell/git_kmt.sh
```

## 2. Installation

From the repository root:

```sh
chmod +x shell/git_kmt.sh
./shell/git_kmt.sh kmt-install
```

For development, the installer also supports link mode:

```sh
./shell/git_kmt.sh kmt-install --link
```

## 3. Verify Installation

```sh
git kmt-version
```

Expected form:

```text
Git Keep MTime. Version: 0.1.3-alpha
```

## 4. Normal Git Usage

Once installed, continue to use Git normally:

```sh
git add <files>
git commit -m "message"
git switch <branch>
git checkout <commit-or-branch>
```

KMT is invoked automatically by the Git wrapper for supported operations.

## 5. The Main Use Case

The key behavior can be demonstrated with two branches containing different historical mtimes for the same file.

```sh
git switch branch-a
```

KMT synchronizes the working-tree mtimes for the target state.

Then:

```sh
git switch branch-b
```

KMT synchronizes them again according to the target history.

Likewise:

```sh
git checkout <commit>
```

causes KMT to synchronize the resulting working tree with the mtime information associated with the target history.

## 6. Scan Repository Status

Use:

```sh
git kmt-scan
```

The scan reports categories including:

- completed
- completable
- synchronizable
- conflicts
- unsynchronizable files

The scan is useful before modifying metadata, especially for an existing repository.

## 7. Complete Missing Metadata

If an existing repository has files whose mtime metadata is missing, use:

```sh
git kmt-complete
```

Completion uses the current local filesystem mtime as the source.

Before doing this, make sure the local file timestamps are the timestamps you intend to preserve. KMT checks for uncommitted changes and other conditions that can make completion unsafe.

A typical migration flow is:

```text
install
  ↓
kmt-scan
  ↓
verify current mtimes
  ↓
kmt-complete
  ↓
future Git operations maintain metadata
```

## 8. Synchronize Mtime

To explicitly synchronize the current working tree from repository metadata:

```sh
git kmt-synchronize
```

A specific commit can also be supplied where supported:

```sh
git kmt-synchronize <commit>
```

## 9. Resolve Conflicts

If a file's local mtime conflicts with KMT metadata, inspect the scan result first:

```sh
git kmt-scan
```

Then resolve using the local filesystem mtime:

```sh
git kmt-resolve
```

The intent is to make the choice explicit rather than silently replacing a potentially meaningful local timestamp.

## 10. Upgrade

Upgrade must be initiated through the release/source script:

```sh
./shell/git_kmt.sh kmt-upgrade
```

Do not use `git kmt-upgrade` as the normal upgrade path.

## 11. Uninstall

Uninstall the installed wrapper through Git:

```sh
git kmt-uninstall
```

Do not normally run:

```sh
./shell/git_kmt.sh kmt-uninstall
```

The distinction is intentional: install/upgrade operate through the source script, while uninstall operates through the installed Git wrapper.

## 12. Notes Synchronization

The KMT notes ref is:

```text
refs/notes/kmt/mtime
```

For the default `origin` remote, the wrapper integrates the notes ref into `git push` and `git pull` processing.

When moving repositories manually or using custom remote workflows, make sure this notes ref is transferred as well.

## 13. Supported Git Operations

The current alpha wrapper intercepts:

```text
add
rm
rename
commit
merge
restore
revert
reset
rebase
switch
checkout
pull
push
```

Not every operation has the same mtime behavior. The general rule is:

```text
Git changes content/history
        ↓
KMT updates or reads metadata
        ↓
KMT synchronizes filesystem mtime when needed
```

## 14. Important Precautions

### Existing repository

Installing KMT does not automatically reconstruct all historical mtimes. Use `kmt-scan` and `kmt-complete` when appropriate.

### Local changes

Do not run completion or other metadata-changing operations while relying on uncommitted local changes as the source of historical truth. KMT may refuse to proceed when it detects unsafe working-tree state.

### Conflicts

Treat reported mtime conflicts as meaningful. Resolve them explicitly.

### Remotes

KMT metadata is stored in Git Notes, so a repository clone must have the KMT notes ref as well as ordinary commits if historical mtime preservation is required.

## 15. Not Yet Publicly Documented

The program contains `kmt-note` for note inspection, but the command is still under development. It is intentionally not documented as part of the public v0.1.3 usage interface.
