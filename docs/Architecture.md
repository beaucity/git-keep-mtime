# Git Keep MTime Architecture

## 1. Overview

Git Keep MTime (KMT) adds filesystem modification-time preservation to Git without modifying Git's normal tree or commit object format.

The fundamental model is:

```text
                    Git repository
                         │
                  Git commits / trees
                         │
                         │ content + history
                         │
                         ▼
                 Git working tree
                         ▲
                         │
                  mtime synchronize
                         │
                         │ KMT metadata
                         │
                  Git Notes ref
                         │
             refs/notes/kmt/mtime
```

Git remains responsible for file contents and history. KMT stores the additional filesystem metadata and applies it back to the working tree when necessary.

## 2. Public Program Structure

The GitHub release exposes the KMT program as:

```text
shell/
└── git_kmt.sh
```

`git_kmt.sh` is the public entry point. Internal development source organization is intentionally not part of the public architecture documentation.

## 3. Git Wrapper Model

KMT is implemented as a Git wrapper. During installation, the normal Git command is kept available behind the KMT wrapper.

Conceptually:

```text
user
 │
 ▼
git <command>
 │
 ▼
Git Keep MTime wrapper
 │
 ├── KMT-specific command
 │      └── execute KMT operation
 │
 └── normal Git command
        │
        ▼
   original Git
```

For ordinary Git operations, KMT delegates to the original Git executable. For operations that can affect mtime state, KMT performs additional processing before or after the Git operation.

## 4. Commit and MTime Relationship

A Git commit identifies a specific version of repository content. KMT associates mtime metadata with that commit through a Git Note.

Conceptually:

```text
Commit A ──────────► KMT Note A
                       │
                       ├── a.txt → mtime T1
                       └── b.txt → mtime T1

Commit B ──────────► KMT Note B
                       │
                       ├── a.txt → mtime T2
                       └── b.txt → mtime T1
```

A later commit does not need to duplicate unchanged metadata unnecessarily. KMT maintains incremental metadata and can construct a full state when required for synchronization.

## 5. Why Git Notes?

Putting mtime into Git's normal tree would make filesystem metadata part of the content tree and would require changing the representation of ordinary files.

Git Notes provide a separate metadata channel:

```text
Git tree / commit
    = repository content and history

Git Notes
    = KMT filesystem metadata
```

This keeps the KMT information logically separate from repository content while still allowing it to be versioned and transported using Git's object model.

The dedicated KMT notes ref is:

```text
refs/notes/kmt/mtime
```

## 6. Incremental Metadata

KMT is designed around incremental changes rather than rebuilding metadata for every commit.

A simplified flow is:

```text
previous mtime state
        │
        ▼
changed files in Git operation
        │
        ▼
mtime delta
        │
        ▼
commit note
        │
        ▼
new mtime state
```

For operations that require a complete state, KMT can merge the relevant incremental information into a full note representation.

## 7. Working-Tree Synchronization

Synchronization is the point where repository metadata becomes filesystem state.

For a target commit:

```text
Target commit
     │
     ▼
KMT mtime metadata
     │
     ▼
file → mtime lookup
     │
     ▼
set filesystem mtime
```

The synchronization process is intentionally separate from Git content checkout. Git first performs its normal operation; KMT then applies the target mtime information to the resulting working tree.

## 8. Switch and Checkout

This is the primary user-visible feature.

Suppose two branches contain the same file with different historical mtimes:

```text
branch-A
  a.txt → T1

branch-B
  a.txt → T2
```

After:

```sh
git switch branch-A
```

KMT synchronizes `a.txt` to `T1`.

After:

```sh
git switch branch-B
```

KMT synchronizes it to `T2`.

The same principle applies when checking out another commit.

This makes Git branch switching behave more like switching between complete historical filesystem states: content and recorded mtime are synchronized together.

## 9. Other Git Operations

KMT also handles mtime-related consequences of operations including:

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

The exact handling differs by operation. Operations that create or modify repository history create/update KMT metadata; operations that move the working tree synchronize mtime as appropriate.

## 10. Existing Repository Completion

When KMT is introduced to an existing repository, historical mtime metadata may be missing.

The completion process is:

```text
existing working tree
        │
        ▼
kmt-scan
        │
        ▼
identify files with missing metadata
        │
        ▼
kmt-complete
        │
        ▼
KMT metadata becomes available
```

The local filesystem timestamp is used as the source for completion. Therefore KMT requires the working tree to contain trustworthy timestamps before completion.

## 11. Safety Model

KMT does not blindly overwrite every timestamp it encounters. Its scan/complete/synchronize workflow distinguishes states such as:

- completed
- completable
- synchronizable
- conflict
- unsynchronizable

This is particularly important for existing repositories and for local files whose current mtime conflicts with repository metadata.

## 12. Git Push and Pull

KMT uses the dedicated notes ref alongside normal Git history.

For the default `origin` remote, the wrapper integrates the KMT notes ref into push/pull processing:

```text
push
 ├── normal Git push
 └── push refs/notes/kmt/mtime

pull
 ├── normal Git fetch/integration
 └── fetch refs/notes/kmt/mtime
```

The notes ref therefore needs to be treated as part of the repository's KMT metadata when repositories are shared or migrated.
