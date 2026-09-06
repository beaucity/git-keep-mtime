# Git Keep MTime v0.1.3-alpha

## First GitHub Alpha Release

Git Keep MTime is an experimental Git extension for preserving filesystem modification times across Git operations.

The key goal of this release is to make file content and recorded filesystem `mtime` behave as a synchronized historical state when moving between Git revisions.

## Highlights

- Preserve mtime metadata in Git Notes rather than modifying Git's normal tree/object format.
- Use the dedicated notes ref:

  ```text
  refs/notes/kmt/mtime
  ```

- Synchronize working-tree mtimes after operations such as `git switch` and `git checkout`.
- Track mtime changes incrementally.
- Provide repository scanning, metadata completion, synchronization, and conflict resolution workflows.
- Use `<STX>` at the beginning of each note entry to support fast and exact fixed-string lookup.
- Integrate the KMT notes ref with push/pull processing for the default `origin` remote.

## Quick Start

```sh
chmod +x shell/git_kmt.sh
./shell/git_kmt.sh kmt-install
```

Then use Git normally:

```sh
git switch <branch>
git checkout <commit>
```

KMT will synchronize file mtimes according to the target Git history when applicable.

For an existing repository, inspect the state first:

```sh
git kmt-scan
git kmt-complete
```

## Important Notes

This is an **alpha** release. The implementation and interfaces may continue to change.

In particular:

- Rename-following mtime history is not yet fully implemented.
- Complex Git histories and less common operation sequences require additional testing.
- Existing repositories may need explicit metadata completion.
- `kmt-note` is intentionally not part of the public documentation yet because its inspection interface is still being developed.
