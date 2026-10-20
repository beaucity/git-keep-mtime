# Release Notes

## v0.4.6-alpha.1

Git Keep MTime is a client-side Git wrapper for preserving file mtime and,
where supported, btime across working-tree changes.

### Highlights

- Preserves mtime for intercepted Git operations including `switch`,
  `checkout`, `merge`, `rebase`, `reset`, `restore`, `revert`, `pull`, and
  `clone`.
- Preserves btime on macOS where the filesystem exposes it.
- Stores authoritative metadata in:

  ```text
  refs/notes/kmt/mtime
  ```

- Keeps metadata out of tracked content and commit trees.
- Maintains rebuildable local indexes under `.git/kmt/`.
- Supports repository scanning, metadata completion, synchronization, conflict
  resolution, and a diff view.
- Migrates notes across rebase and pull --rebase history rewriting.
- Synchronizes notes through intercepted `fetch`, `pull`, and `push`.
- Uses whole-note conflict selection; it never merges fields from two versions
  of the same commit note.
- Defaults to the local note on a genuine note conflict; the remote note can be
  selected with `NOTE_CONFLICT_POLICY=remote`.
- Rejects manual notes refspecs that could bypass KMT's notes synchronization.

### Mixed KMT and plain-Git use

- Plain Git commits do not create KMT notes.
- Plain `git pull` does not fetch the KMT notes ref.
- KMT does not create a placeholder note for a fast-forward upstream commit
  that has no note; a later real note can be imported.
- KMT notes are published through the KMT wrapper, not through user-configured
  notes refspecs.

### Platform support

- macOS: mtime and btime (btime requires `setfile`).
- Linux: mtime.
- Other Unix-like systems are not currently supported.

### Installation

```sh
chmod +x shell/git_kmt.sh
./shell/git_kmt.sh kmt-install
git kmt-version
```

Upgrade:

```sh
./shell/git_kmt.sh kmt-upgrade
```

Uninstall through the installed wrapper:

```sh
git kmt-uninstall
```

### Existing repositories

```sh
git kmt-scan
# verify local timestamps
git kmt-complete
```

Metadata already present in notes can be applied with:

```sh
git kmt-synchronize
```

### Known limitations

- atime is not preserved.
- btime is platform-dependent and not restored on Linux.
- Directory restoration is conservative when the target state is ambiguous.
- The metadata format is line-oriented; unusual path encodings may be
  unsupported.
- Mixed plain-Git workflows cannot guarantee timestamps for commits that never
  passed through KMT.
- The project is licensed under GPL-3.0; see `LICENSE.txt`.

See [README.md](README.md), [Usage](docs/Usage.md), [Storage](docs/Storage.md),
and [Architecture](docs/Architecture.md) for details.
