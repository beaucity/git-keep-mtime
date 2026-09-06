# Git Keep MTime Storage

## 1. Storage Principle

Git Keep MTime stores filesystem modification times separately from Git's normal file-content tree.

The main persistent Git-side metadata is stored in the dedicated notes ref:

```text
refs/notes/kmt/mtime
```

The design can therefore be summarized as:

```text
Git object database
├── normal commits / trees / blobs
└── KMT notes
      └── refs/notes/kmt/mtime
```

## 2. Note Entry Format

A KMT file entry has the logical form:

```text
<STX>filename<ETX>mtime
```

`<STX>` and `<ETX>` are control characters, not the literal strings `STX` and `ETX`.

For example, conceptually:

```text
<STX>src/main.c<ETX>1785934828
```

The fields are:

| Field | Meaning |
|---|---|
| `<STX>` | Start-of-entry marker. |
| `filename` | Repository-relative file path. |
| `<ETX>` | Field separator. |
| `mtime` | Unix filesystem modification timestamp. |

## 3. Why the STX Prefix Exists

The leading STX marker is deliberately part of the storage format.

KMT frequently needs to find one exact file entry in a note. With the entry beginning at STX, an exact fixed-string lookup can be performed using:

```sh
grep -m 1 -F "$STX$filename$ETX"
```

This has two useful properties:

1. It avoids treating a filename as a prefix of another filename.
2. It allows KMT to stop after the first exact matching entry.

For example, searching for `foo.txt` should not accidentally select:

```text
foo.txt.bak
myfoo.txt
path/foo.txt
```

The STX + filename + ETX sequence provides an explicit record boundary for this lookup strategy.

## 4. Mtime Representation

KMT stores mtime as a Unix timestamp. The value represents the filesystem modification time that KMT wants to preserve.

The timestamp is kept as metadata rather than encoded into the file content or Git tree.

## 5. Incremental and Full Metadata

KMT uses incremental metadata to avoid regenerating the complete repository mtime state for every commit.

The internal processing model contains concepts corresponding to:

```text
mtime delta
    │
    ▼
commit-level changes
    │
    ▼
merged/full state
    │
    ▼
working-tree synchronization
```

A delta records the mtime information that needs to change. A full state can represent the effective mtime of the repository files at a particular point in history.

The precise internal temporary-file layout is an implementation detail of the current alpha implementation and is intentionally not treated as a public storage API.

## 6. Notes Namespace

The KMT notes namespace is:

```text
refs/notes/kmt/mtime
```

Keeping KMT under its own notes namespace prevents it from mixing with unrelated Git Notes applications.

## 7. Transport

Because the KMT metadata is stored in Git Notes, normal Git commits alone are not sufficient to reproduce the complete KMT state in another clone.

The notes ref must also be available:

```text
refs/notes/kmt/mtime
```

The KMT wrapper integrates this ref with push/pull for the default `origin` remote.

## 8. Compatibility Principle

KMT does not require a custom Git object type or a modified Git repository format. The repository continues to contain ordinary Git commits, trees, and blobs, with KMT metadata represented through standard Git Notes.
