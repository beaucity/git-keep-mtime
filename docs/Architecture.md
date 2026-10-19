# Architecture

Git Keep MTime is a client-side Git wrapper. It does not change Git's commit or
tree object model. Instead, it records filesystem timestamp metadata in Git
notes and applies that metadata around working-tree operations.

## High-level model

```text
git command
    |
    v
KMT wrapper
    |
    +----------------------+
    |                      |
    v                      v
original Git          KMT metadata
    |                      |
    v                      v
repository objects    refs/notes/kmt/mtime
working tree          .git/kmt caches
```

Git remains responsible for commits, trees, blobs, branches, merges, rebases,
and the working tree.

KMT adds:

- timestamp notes keyed by commit;
- working-tree timestamp capture and restoration;
- note synchronization through fetch/pull/push;
- local, rebuildable indexes;
- completion and conflict workflows.

## Wrapper lifecycle

The installed `git` command is a wrapper. The original Git executable is kept
behind it. A command goes through roughly this sequence:

```text
parse command
  -> pre-operation checks and snapshots
  -> original Git operation
  -> post-operation timestamp sync
  -> note/index updates
```

Commands that do not need timestamp handling are forwarded to the original Git
executable.

## Commit notes

The authoritative metadata ref is:

```text
refs/notes/kmt/mtime
```

For each relevant commit, the notes tree maps the commit ID to a note containing
repository-relative paths and timestamp fields.

The note is atomic per commit. KMT does not merge individual fields from two
different versions of the same commit note.

See [Storage](Storage.md) for the on-disk format.

## Working-tree synchronization

When Git changes the working tree, KMT:

1. finds the target commit;
2. reads the target full index and commit note;
3. compares target timestamps with the current filesystem state;
4. avoids overwriting newer local timestamps when the target metadata is older;
5. applies mtime, and btime where supported.

The filesystem is modified; tracked file content is not.

Uncommitted and staged files are excluded from unsafe restoration paths.

## Local indexes

`.git/kmt/` contains derived indexes and temporary state. These files accelerate
lookups and can be rebuilt from Git history and notes. They are not part of the
shared metadata.

## Fetch, pull, and push

Branch refs and notes refs are independent in Git. KMT coordinates them:

- `fetch`/`pull` fetch branch data and the notes ref;
- `push` publishes the local notes ref after the branch push.

KMT may create a notes merge commit when local and remote notes have diverged.
The merge commit keeps both histories while selecting the configured whole-note
state.

KMT rejects manual notes refspecs that could update or publish the KMT notes ref
outside its synchronization logic.

## Conflicts

A conflict occurs when the same commit has different local and remote notes.

The default policy is:

```text
local  -> keep the whole local note
remote -> use the whole remote note
```

Normal linear notes updates are fast-forwards, not conflicts.

Placeholder notes whose entries all have empty time fields may be replaced by a
real remote note even under the local policy.

## History rewriting

Rebase and pull --rebase create new commit IDs. KMT uses rewritten-commit
information and range comparison to migrate notes from the old commits to the
new ones.

The notes stay associated with the rewritten history rather than obsolete commit
IDs.

## Mixed KMT and plain Git

The original Git binary does not create KMT notes and does not fetch the notes
ref.

KMT therefore:

- does not fabricate a placeholder note for a fast-forward upstream commit;
- warns when an upstream commit has no note;
- imports a later real note when it becomes available;
- requires an explicit KMT fetch before synchronizing after a plain Git pull.

Mixed workflows cannot guarantee timestamp fidelity for commits that never pass
through KMT metadata completion.

## Recovery boundaries

The notes ref is the authoritative mapping from commits to timestamp notes.
Commit content alone cannot reconstruct historical mtimes.

Recovery relies on one of:

- a reachable notes ref or backup ref;
- another remote notes ref;
- an explicit completion from the local filesystem.

KMT does not invent historical timestamps from commit diffs or current checkout
times.

## Trust and security

KMT notes are normal mutable Git refs. Anyone with push access to the notes ref
can change timestamp metadata.

KMT does not sign notes or verify remote authors. Use repository permissions,
review, and normal Git security controls.
