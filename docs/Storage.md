# Storage

This document describes the persistent and local storage used by KMT.

## Authoritative metadata

KMT stores timestamp metadata in the Git notes ref:

```text
refs/notes/kmt/mtime
```

The notes ref is a normal Git ref whose commits contain a notes tree. The tree
maps a commit object ID to that commit's timestamp note.

The notes ref is independent of branch history. Branch commits and KMT notes are
fetched and pushed separately, although KMT coordinates both operations through
its Git wrapper.

## Note entries

Each note entry has the logical form:

```text
<STX>path<ETX>mtime<ETX>btime
```

`STX` and `ETX` are control characters, not literal text.

| Field | Meaning |
| --- | --- |
| `path` | Repository-relative path |
| `mtime` | Unix epoch seconds, `D` for deleted, or empty |
| `btime` | Unix epoch seconds, or empty |

Examples:

```text
<STX>src/main.c<ETX>1785934828<ETX>1785930000
<STX>old/file.c<ETX>D<ETX>
<STX>new/file.c<ETX><ETX>
```

An entry with both time fields empty is a placeholder. A note whose entries all
have empty time fields contains no usable timestamp metadata. KMT may replace
such a placeholder when a real remote note becomes available.

The leading `STX` gives an explicit record boundary. KMT can locate an exact
path with a fixed-string search instead of matching a filename prefix.

## One note per commit

A commit note is the complete timestamp snapshot for the files changed by that
commit. KMT treats it as atomic:

- it does not merge individual paths from two versions of the same commit note;
- on a conflict it chooses the whole local note or the whole remote note;
- the default policy is `local`;
- `NOTE_CONFLICT_POLICY=remote` selects the remote note.

A note for a commit is not part of the commit object and does not change the
commit ID.

## Empty and deleted entries

- Empty `mtime`/`btime` means the value is unknown or not available.
- `D` in the mtime field marks a deletion.
- Empty entries still preserve path-level state and are not equivalent to a
  missing note.

Placeholder notes are intentionally ignored when KMT looks for real timestamp
metadata.

## Notes history

The notes ref points to a commit history, not to a mutable directory. Each notes
commit contains a complete tree snapshot for that point in time.

KMT may create a merge commit on the notes ref when local and remote note
histories have diverged. The resulting tree contains the selected note state,
and both note histories remain parents of the merge commit.

A linear remote notes update is handled as a fast-forward when the local tree
does not need a conflicting choice.

## Local cache

KMT maintains rebuildable indexes under:

```text
.git/kmt/
```

They contain derived state such as:

- per-commit delta/stage metadata
- full timestamp indexes
- temporary rebuild data

These files are caches. They are not portable user data and are not a second
authoritative copy of the notes. Deleting `.git/kmt/` is safe; KMT can rebuild it
from Git history and notes.

## Backup refs

KMT may keep local recovery refs under:

```text
refs/kmt/backup/
```

These refs are internal implementation state. They are not part of the shared
metadata format and should not be pushed, deleted, or configured manually.

The pre-fetch backup exists so an intercepted Git fetch cannot make local-only
notes unreachable before KMT merges them.

## Fetch and push

KMT's intercepted `fetch`, `pull`, and `push` operations synchronize the notes
ref.

Do not add the KMT notes ref to `remote.<name>.fetch` or
`remote.<name>.push`. KMT rejects refspecs that cover
`refs/notes/kmt/mtime`, including broad `refs/notes/*` and `refs/*` patterns.

Other notes namespaces are not managed by KMT and are not blocked.

## Rebuilding indexes

The notes ref is authoritative. The local cache is rebuilt when needed.

If the notes tree for a commit is missing, KMT cannot invent historical
timestamps from commit content. It can only:

- use existing note data;
- use a known-good note ref or remote note;
- complete metadata from the local filesystem if the user explicitly requests
  it.

## Trust model

KMT does not sign notes or verify remote authors. Anyone who can push the notes
ref can change timestamp metadata, subject to normal Git permissions and review.
Treat KMT notes with the same trust you give any other mutable branch or ref in
the repository.
