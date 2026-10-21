# Usage

This guide covers installation, daily use, migration, notes synchronization,
and the mixed KMT/plain-Git workflow.

## Requirements

KMT is a POSIX shell wrapper around Git. It currently supports macOS and Linux.

Required:

- Git
- a POSIX-compatible shell
- standard Unix utilities used by Git and the installer

Optional:

- Python 3 for the faster scan backend
- `setfile` on macOS for btime restoration

Linux supports mtime restoration; btime is platform-dependent and is currently
not restored on Linux.

## Install

From the repository root:

```sh
chmod +x shell/git_kmt.sh
./shell/git_kmt.sh kmt-install
```

For development, install a symlink instead of a copy:

```sh
./shell/git_kmt.sh kmt-install --link
```

Verify:

```sh
git kmt-version
```

The wrapper keeps the original Git executable behind `.git_kmt/git` and forwards
unhandled commands to it.

## Upgrade and uninstall

Upgrade through the source script:

```sh
./shell/git_kmt.sh kmt-upgrade
```

Uninstall through the installed wrapper:

```sh
git kmt-uninstall
```

## Daily use

After installation, continue using Git normally:

```sh
git add file.txt
git commit -m "Update file"
git switch another-branch
git pull
```

KMT records metadata around intercepted operations and restores timestamps when
Git changes the working tree.

The most visible use case is switching between branches or checking out an
older commit:

```sh
git switch branch-a
git switch branch-b
git checkout <commit>
```

Each operation should restore the timestamp metadata associated with the target
state.

KMT works from subdirectories as well as the repository root.

## Inspect the repository

```sh
git kmt-scan
```

The scan reports categories such as:

- completed
- completable
- synchronizable
- conflicts
- unsynchronizable

Use the scan before migration or before changing timestamp metadata.

An interactive UI is also available:

```sh
git kmt
```

## Complete missing metadata

For an existing repository whose files do not have KMT notes yet:

```sh
git kmt-scan
# verify that the current local file times are the ones to preserve
git kmt-complete
```

Completion records eligible local mtime/btime values into KMT notes.

Important:

- Complete only when the local filesystem contains the timestamps you intend to
  preserve.
- KMT rejects future timestamps and timestamps outside the valid history range.
- Uncommitted changes can make completion unsafe; KMT may refuse to proceed.
- Existing timestamp metadata is not arbitrarily overwritten.

Typical migration flow:

```text
install
  -> git kmt-scan
  -> verify local timestamps
  -> git kmt-complete
  -> subsequent Git operations maintain metadata
```

## Synchronize the working tree

Apply repository metadata to the working tree:

```sh
git kmt-synchronize
```

This is useful after metadata was fetched or after a plain Git operation left
the working tree timestamps in a generic state.

If the local notes are stale, fetch them first through the KMT wrapper:

```sh
git fetch
git kmt-synchronize
```

A plain `git pull` does not fetch KMT notes.

## Resolve conflicts

A conflict means the local filesystem timestamp and the repository note disagree
in a way KMT does not want to resolve silently.

Inspect first:

```sh
git kmt-scan
```

Then explicitly resolve using the local filesystem timestamp:

```sh
git kmt-resolve
```

KMT treats a commit note as an atomic snapshot. On a fetch conflict it keeps the
whole local note by default, or the whole remote note when
`NOTE_CONFLICT_POLICY=remote` is set. It never merges individual files or fields
from two versions of the same commit note.

## Diff against notes

List files whose filesystem timestamps differ from the notes:

```sh
git kmt-diff
```

## Notes synchronization

The authoritative notes ref is:

```text
refs/notes/kmt/mtime
```

KMT's intercepted `fetch`, `pull`, and `push` handle this ref automatically.
Explicit remote and branch forms are supported:

```sh
git fetch upstream feature
git pull upstream feature
git push upstream feature
```

For a remote with multiple push URLs, KMT merges notes from each URL before
pushing the shared notes ref to all of them. This prevents a stale notes ref on
one URL from rejecting a push after another URL has already advanced.

If you need to refresh local notes manually after a mixed workflow:

```sh
git fetch nas
```

The notes ref is global, not per-branch. It may contain notes for commits that
are not present on every remote that receives the ref.

Do **not** configure it in the remote refspecs:

```text
remote.<name>.fetch = +refs/notes/kmt/mtime:refs/notes/kmt/mtime
remote.<name>.push  = refs/notes/kmt/mtime:refs/notes/kmt/mtime
```

KMT rejects refspecs that can cover `refs/notes/kmt/mtime`, including broad
`refs/notes/*` and `refs/*` patterns. Other notes namespaces are not blocked.

If an existing repository has such a refspec, remove only the KMT notes entry
and keep the normal branch refspecs.

KMT also keeps local backup refs under:

```text
refs/kmt/backup/
```

These are internal recovery aids. Do not push, delete, or configure them
manually.

## Mixed KMT and plain-Git users

A user who runs the original Git binary does not create KMT notes and does not
automatically fetch the KMT notes ref.

Recommended behavior:

- Use the KMT wrapper for `add`, `commit`, `fetch`, `pull`, and `push` when
  timestamp preservation matters.
- After a plain `git pull`, run `git fetch` through KMT before
  `git kmt-synchronize`.
- A plain-Git commit can be completed later with `git kmt-complete`, then
  published with the KMT wrapper.
- KMT does not fabricate a placeholder note for a fast-forward upstream commit.
  It warns instead; a later real note can be imported cleanly.

A mixed team should agree that timestamp metadata is only guaranteed for
commits processed through KMT.

## Supported Git operations

KMT intercepts:

```text
add    rm      mv      commit   merge
restore revert reset   rebase   switch
checkout clone push    fetch   pull
```

Commands that do not require timestamp handling are forwarded unchanged.

## Rebase and pull --rebase

Rebase creates new commit IDs. KMT migrates notes from the old commits to the
rewritten commits using Git's rewritten-commit information and range comparison.

The same logic is used for `pull --rebase`.

## Environment

`NOTE_CONFLICT_POLICY` controls the whole-note conflict choice:

```sh
NOTE_CONFLICT_POLICY=local git fetch   # default: keep local note
NOTE_CONFLICT_POLICY=remote git fetch  # take the remote note
```

The policy applies only to genuinely divergent notes, not to normal fast-forward
updates.

## Troubleshooting

### A file's mtime is not restored

1. Run `git kmt-scan`.
2. Check whether the commit note exists.
3. If the note is missing, run `git kmt-complete` while the local timestamp is
   still meaningful.
4. If notes were fetched by a plain Git command, run a KMT `git fetch` and then
   `git kmt-synchronize`.

### Notes were changed manually

KMT keeps the notes ref authoritative. If it was changed by an external tool,
KMT may report conflicts or use a backup ref for recovery. Do not edit the notes
tree directly.

### A manual notes refspec is rejected

Remove the KMT notes refspec from `remote.<name>.fetch` or
`remote.<name>.push`. KMT manages that ref internally.

## Limitations

- btime restoration is not available on Linux.
- atime is not preserved.
- Directory restoration is conservative when the target directory state is
  ambiguous.
- Path encoding is constrained by the line-oriented metadata format.
- KMT does not control users who invoke the real Git binary directly.
