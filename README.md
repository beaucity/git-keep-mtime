# Git Keep MTime

![Version](https://img.shields.io/badge/version-v0.4.6-alpha.1-blue)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)

**Git Keep MTime (`git-kmt`)** is a client-side Git wrapper that preserves
filesystem timestamps when Git changes the working tree.

Git restores file contents, but it does not normally restore the original
filesystem **mtime**. KMT records timestamp metadata separately from the
commit tree and applies it after operations such as `switch`, `checkout`,
`merge`, `rebase`, `reset`, and `pull`.

On macOS it can also preserve filesystem **birth time (btime)** where the
filesystem exposes it.

## Why

A checkout should restore more than the bytes of a file. Build tools, backup
tools, and humans often use modification time as meaningful state.

KMT keeps that state in Git notes:

```text
refs/notes/kmt/mtime
```

It does not rewrite tracked files and does not add timestamp fields to normal
commit trees.

## Features

- Preserves file mtime across Git working-tree changes.
- Preserves btime on macOS where the filesystem supports it.
- Works from the repository root and from subdirectories.
- Stores authoritative metadata in Git notes.
- Uses rebuildable local indexes under `.git/kmt/`.
- Handles history rewriting with `rebase` and `pull --rebase`.
- Synchronizes notes through intercepted `fetch`, `pull`, and `push`.
- Handles explicit `<remote> <branch>` arguments and remotes with multiple push
  URLs.
- Supports explicit completion and synchronization for existing repositories.
- Keeps notes atomic per commit; conflicting notes are selected as a whole,
  never merged field-by-field.
- Rejects manual notes refspecs that could bypass KMT's merge logic.

## Requirements

- Git
- A POSIX-compatible shell
- macOS or Linux
- Standard Unix utilities used by Git and the installer
- macOS: `setfile` for btime support (provided by the Xcode command-line tools)
- Optional: Python 3 for the faster scan backend

Linux currently supports mtime; btime remains platform-dependent.

## Installation

From the repository root:

```sh
chmod +x shell/git_kmt.sh
./shell/git_kmt.sh kmt-install
```

For development, link mode is also available:

```sh
./shell/git_kmt.sh kmt-install --link
```

Verify the installation:

```sh
git kmt-version
```

Upgrade an installed copy:

```sh
./shell/git_kmt.sh kmt-upgrade
```

Uninstall through the installed Git wrapper:

```sh
git kmt-uninstall
```

The installer keeps the original Git executable behind the wrapper, so normal
Git commands continue to work.

## Quick start

```sh
cd my-repository

git add file.txt
git commit -m "Add file"

git switch another-branch
git switch -
```

KMT records timestamp metadata when the commit is created and restores it when
Git changes the working tree.

Inspect the current repository state:

```sh
git kmt-scan
```

Complete metadata for an existing repository:

```sh
git kmt-scan          # inspect first
git kmt-complete      # record eligible local mtimes
```

Apply repository metadata to the working tree:

```sh
git kmt-synchronize
```

## Commands

| Command | Purpose |
| --- | --- |
| `git kmt` | Interactive KMT UI |
| `git kmt-scan` | Report completed, completable, synchronizable, conflicting, and unsynchronizable files |
| `git kmt-complete` | Record eligible local mtime/btime into KMT notes |
| `git kmt-synchronize` | Apply repository timestamp metadata to the working tree |
| `git kmt-resolve` | Resolve mtime conflicts using the local filesystem value |
| `git kmt-diff` | List files whose filesystem timestamps differ from notes |
| `git kmt-version` | Print the installed version |
| `./shell/git_kmt.sh kmt-install` | Install the wrapper |
| `./shell/git_kmt.sh kmt-upgrade` | Upgrade the wrapper |
| `git kmt-uninstall` | Remove the installed wrapper |

## Supported Git operations

KMT intercepts timestamp-sensitive behavior for:

```text
add    rm      mv      commit   merge
restore revert reset   rebase   switch
checkout clone push    fetch   pull
```

Commands that do not need timestamp handling are forwarded to the original Git
executable.

## How it works

For each relevant commit, KMT stores a note in:

```text
refs/notes/kmt/mtime
```

Each entry has the logical form:

```text
<STX>path<ETX>mtime<ETX>btime
```

- `path` is repository-relative.
- `mtime` and `btime` are Unix epoch seconds.
- An empty field means the value is unknown or intentionally blank.
- `D` in the mtime field marks a deleted path.
- A note whose entries all have empty time fields is a placeholder, not real
  metadata.

A commit note is atomic: on a conflict, KMT chooses the whole local note or the
whole remote note according to `NOTE_CONFLICT_POLICY` (default: `local`).

Local indexes under:

```text
.git/kmt/
```

are caches. They can be deleted and rebuilt from Git history and KMT notes.

## Sharing timestamp metadata

KMT's intercepted `fetch`, `pull`, and `push` handle the notes ref
automatically, including explicit remote and branch forms:

```sh
git fetch upstream feature
git pull upstream feature
git push upstream feature
```

If a remote has multiple push URLs, KMT fetches and merges the notes from each
URL before publishing the shared notes ref. This keeps the notes in sync when,
for example, one URL points to GitHub and another to a local NAS.

The notes ref is global, not per-branch. When it is published to a remote, it
may contain notes for commits that are not on that remote's branches.

Do **not** add `refs/notes/kmt/mtime` to `remote.<name>.fetch` or
`remote.<name>.push`. Those refspecs are rejected so that Git cannot update or
publish the KMT notes ref before KMT has merged it.

If notes are shared by a team, all users who care about timestamps should use
the KMT wrapper for the relevant Git operations.

## Mixed KMT and plain Git usage

Plain Git does not create KMT notes, and a plain `git pull` does not fetch the
KMT notes ref.

Consequences:

- Commits created with plain Git have no timestamp metadata until a KMT user
  completes them.
- After a plain `git pull`, run KMT `git fetch` before `git kmt-synchronize` to
  avoid applying stale notes.
- KMT does not fabricate a placeholder note for a fast-forward upstream
  commit. If a plain-Git author later publishes a real note, KMT can import it.
- KMT may warn when a commit has no note; this is expected in mixed workflows.

For reliable timestamp preservation, use KMT for `add`, `commit`, `fetch`,
`pull`, and `push`.

## Existing repositories

Installing KMT does not automatically reconstruct historical timestamps.

Typical migration:

```sh
git kmt-scan
# verify that local file times are the ones you want to preserve
git kmt-complete
```

If metadata already exists, use `git kmt-synchronize` instead of completion.

## Limitations

- btime support depends on the platform and filesystem; Linux currently does not
  provide btime restoration.
- KMT does not preserve access time (`atime`).
- Directory timestamp restoration is conservative when uncommitted files or
  structural changes make the expected state ambiguous.
- File names are stored in a line-oriented metadata format; unusual path
  encodings may be unsupported.
- Some advanced history-rewrite cases may require additional testing.
- Timestamp metadata is only as good as the notes that were completed and
  shared. Plain Git users do not produce metadata automatically.
- KMT is a client-side wrapper; it cannot control users who invoke the real Git
  binary directly.

## Documentation

- [Usage](docs/Usage.md)
- [Storage format](docs/Storage.md)
- [Architecture](docs/Architecture.md)
- [Release notes](RELEASE_NOTES.md)

## License

GNU General Public License v3.0. See [LICENSE.txt](LICENSE.txt).
