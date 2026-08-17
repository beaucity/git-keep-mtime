# Git Keep MTime Architecture

## 1. Overview

Git Keep MTime (`git_kmt`) is a client-side Git extension for preserving
filesystem modification time (`mtime`) across Git working copies.

Git owns file content and repository history. KMT owns preserved filesystem
mtime.

The key architectural decision is to keep KMT metadata out of the normal
working tree:

```text
project/
├── source files...
└── .git/
    └── kmt/
        └── mtime
```

The two metadata layers have different responsibilities:

```text
.git/kmt/mtime       local KMT working state / cache
refs/kmt/mtime       repository-side versioned KMT metadata
```

This keeps KMT transparent to normal Git users while allowing mtime metadata
to participate in Git repository synchronization.

---

## 2. Design Goals

1. Preserve filesystem `mtime` across Git working copies.
2. Keep KMT metadata out of the normal working tree.
3. Avoid accidental `git add`, deletion, or modification of KMT metadata.
4. Version KMT metadata through a dedicated Git ref.
5. Make local KMT state inspectable and recoverable.
6. Preserve the SVN KMT safety model for Complete, Synchronize, and Conflict.
7. Support branch switching, merge, rebase, reset, and related operations.
8. Require no Git server-side extension.
9. Keep the implementation simple and auditable.

---

## 3. Non-Goals

The first implementation does not:

- modify Git blobs;
- modify Git commit objects;
- modify the Git index format;
- emulate SVN properties;
- put `.kmt/mtime` in the working tree;
- depend on clean/smudge filters;
- require server-side KMT software;
- invent an mtime when no safe source exists.

---

## 4. Core Architecture

```text
                         git_kmt
                            |
              +-------------+-------------+
              |                           |
       Working Tree                    Git Repository
              |                           |
              |                  refs/kmt/mtime
              |                           |
              |                      KMT Git tree
              |                           |
              +-------------+-------------+
                            |
                    .git/kmt/mtime
                 local working metadata
```

`.git/kmt/mtime` is local implementation state.

`refs/kmt/mtime` is the repository-side authoritative KMT state.

The KMT working tree is synchronized from repository metadata:

```text
refs/kmt/mtime
      |
      v
.git/kmt/mtime
      |
      v
filesystem mtime
```

---

## 5. Why `.git/kmt/mtime` Cannot Be the Only Store

`.git/` is not part of the Git tree and is never included in ordinary
commits.

If `.git/kmt/mtime` were the only metadata store, this could happen:

```text
git checkout old-commit

Git content -> old version
KMT state   -> current version
```

The mtime state would then no longer correspond to the selected Git state.

Therefore the repository-side KMT state must be represented by Git objects
and a dedicated ref:

```text
refs/kmt/mtime
```

---

## 6. KMT Metadata Tree

The KMT ref points to a Git tree representing:

```text
repository-relative path -> mtime
```

The logical record format is:

```text
path<TAB>unix_timestamp
```

Example:

```text
README.md       1755361200
src/main.c      1755359800
src/test.c      1755359700
```

The exact object representation may be refined during implementation, but
path encoding must be deterministic and independent of shell word splitting.

---

## 7. Ref Semantics

The KMT ref must follow Git branch state.

Conceptually:

```text
main
  -> main KMT state

feature
  -> feature KMT state
```

Switching branches loads the corresponding KMT metadata into:

```text
.git/kmt/mtime
```

and then synchronizes the working tree as necessary.

The exact internal mapping between normal branch refs and KMT refs must be
fixed during implementation. It must support branch creation, checkout,
merge, rebase, and deletion without silently losing KMT state.

---

## 8. Fetch and Push

KMT metadata is not automatically transferred merely because it is stored
under a custom ref.

Therefore `git_kmt` must explicitly integrate:

```text
refs/kmt/mtime
```

with fetch/push operations.

Conceptually:

```text
git pull
    |
    +-- normal Git refs
    |
    +-- KMT ref
```

and:

```text
git push
    |
    +-- normal Git refs
    |
    +-- KMT ref
```

Users should not need to manipulate `refs/kmt/mtime` manually.

The exact refspec and synchronization mechanism is an implementation
decision, but it must be treated as a first-class part of the Git backend.

---

## 9. Source of Truth

Git is authoritative for:

- file content;
- file existence;
- file path;
- file mode;
- branches;
- commits;
- merge history.

KMT is authoritative for:

- preserved filesystem mtime.

For synchronization:

```text
repository KMT state
        |
        v
.git/kmt/mtime
        |
        v
working-tree mtime
```

---

## 10. Git Wrapper

Recommended installed components:

```text
git
git_kmt
git_kmt_org
```

After installation:

```text
git -> git_kmt
```

The original Git executable is preserved as:

```text
git_kmt_org
```

The wrapper must never recursively invoke itself.

Basic flow:

```text
user
 |
 v
git_kmt
 |
 +-- KMT pre-processing
 |
 +-- git_kmt_org
 |
 +-- KMT post-processing
 |
 v
result
```

---

## 11. Git Operations Requiring KMT Integration

Operations that can change the selected tree or working-tree files include:

```text
commit
checkout
switch
merge
rebase
reset
restore
revert
cherry-pick
pull
```

The first implementation may integrate them incrementally.

Read-only operations such as:

```text
status
log
show
diff
branch
remote
```

normally do not change KMT state.

---

## 12. Scanner Contract

The scanner should produce conceptually:

```text
path
file_ts
metadata_ts
version_ts
tracked
modified
conflicted
exists
future
```

Where:

- `file_ts` is local filesystem mtime.
- `metadata_ts` comes from `.git/kmt/mtime`.
- `version_ts` is the relevant Git history timestamp.
- `tracked` indicates Git tracking.
- `modified` indicates Git working-tree/index changes.
- `conflicted` indicates an unmerged path.
- `future` indicates `file_ts > current_time`.

The scanner discovers facts. The KMT classifier applies policy.

---

## 13. Git Version Timestamp

Git has no SVN-style per-file revision timestamp.

When needed, KMT derives a safety reference from Git history, conceptually:

```text
git log -1 --format=%ct -- <path>
```

This is:

```text
version_ts
```

It is not the original filesystem mtime and must not be presented as such.

---

## 14. Complete

`complete` means:

> Record a safe local filesystem mtime into repository KMT metadata.

Direction:

```text
LOCAL -> KMT REPOSITORY
```

Flow:

```text
working tree
    |
    v
scan
    |
    v
Completable
    |
    v
validate local mtime
    |
    v
.git/kmt/mtime
    |
    v
refs/kmt/mtime
```

The KMT ref must then be synchronized through the Git backend.

---

## 15. Synchronize

`synchronize` means:

> Apply repository KMT metadata to the local filesystem.

Direction:

```text
KMT REPOSITORY -> LOCAL
```

Flow:

```text
refs/kmt/mtime
      |
      v
.git/kmt/mtime
      |
      v
filesystem mtime
```

Synchronize does not modify file content or repository KMT metadata.

---

## 16. Conflict

A conflict exists when KMT cannot safely determine which timestamp is
authoritative.

Example:

```text
repository mtime = 1755361000
local mtime      = 1755362000
```

KMT must not silently select one value.

The result is:

```text
Conflict
```

---

## 17. Resolve

`resolve` means:

> Use a validated local filesystem mtime as the new KMT metadata value.

It is not an unconditional force operation.

Flow:

```text
Conflict
   |
   v
inspect local mtime
   |
   v
validate
   |
   v
.git/kmt/mtime
   |
   v
refs/kmt/mtime
```

Future timestamps remain forbidden.

---

## 18. Safety Rules

The SVN KMT safety rules are retained.

### Future timestamps

Never accept:

```text
file_ts > current_time
```

### No unnecessary rewrite

If:

```text
file_ts == metadata_ts
```

do not rewrite KMT metadata.

### No silent regression

If existing repository metadata is newer than a local candidate, do not
silently replace it with the older value.

### No silent conflict resolution

When the state is ambiguous:

```text
report
do not guess
```

### Content and mtime are independent

KMT must never modify content merely to preserve mtime.

---

## 19. Existing Repository Initialization

For an existing repository without KMT metadata, the original mtime may
still exist in only some working copies.

A scan classifies files as:

```text
Completable
Unsynchronizable
```

A working copy with a safe original timestamp can run:

```text
git kmt-complete
```

Other working copies can later run:

```text
git kmt-synchronize
```

If no working copy contains a trustworthy timestamp, KMT reports the file as
unsynchronizable instead of inventing a timestamp.

---

## 20. Branches

KMT metadata follows Git branch state.

Example:

```text
main:
foo.txt -> 10:00

feature:
foo.txt -> 11:00
```

After switching to `main`, KMT loads the main state.

After switching to `feature`, KMT loads the feature state.

The active state is materialized into:

```text
.git/kmt/mtime
```

---

## 21. Merge and Rebase

KMT must distinguish:

```text
Git content conflict
```

from:

```text
KMT mtime conflict
```

Possible combinations include:

```text
content clean + mtime clean
content clean + mtime conflict
content conflict + mtime clean
content conflict + mtime conflict
```

Neither conflict type is automatically considered resolved by resolving
the other.

---

## 22. Deleted and Renamed Paths

When a tracked file is deleted, its KMT metadata must also be removed.

For:

```text
old.txt -> new.txt
```

KMT should preserve the metadata association when Git provides enough
evidence of a safe rename.

Ambiguous rename/copy situations must not silently assign the wrong mtime.

---

## 23. Submodules

Each submodule is an independent Git repository.

The parent KMT metadata does not manage files inside the submodule.

Each submodule can independently use:

```text
.git/kmt/mtime
refs/kmt/mtime
```

---

## 24. Git LFS

Git LFS is compatible with the KMT model.

KMT operates on the materialized working-tree file and stores no LFS-specific
metadata.

---

## 25. Automatic Synchronization

The Git wrapper is the primary integration mechanism.

Potential hooks:

```text
post-checkout
post-merge
post-rewrite
```

may be added later.

Hooks are not required for the initial architecture.

---

## 26. Local State Recovery

If:

```text
.git/kmt/mtime
```

is missing or corrupted, KMT should reconstruct it from:

```text
refs/kmt/mtime
```

when available.

This makes `.git/kmt/mtime` a recoverable local state/cache rather than the
ultimate repository source.

---

## 27. Installation

The distribution script is:

```text
git_kmt.sh
```

The installed wrapper is:

```text
git_kmt
```

The original Git executable is:

```text
git_kmt_org
```

Installation must preserve rollback behavior.

If installation fails, the user must retain a usable original Git.

---

## 28. Uninstallation

The original Git executable must be restored before the wrapper is removed.

Conceptually:

```text
git -> git_kmt
        |
        v
restore git_kmt_org -> git
        |
        v
remove git_kmt
```

Uninstall must not silently destroy repository KMT metadata unless explicit
repository cleanup is requested.

---

## 29. Final Architecture

```text
                         Git KMT
                            |
        +-------------------+-------------------+
        |                                       |
    Working Tree                           Git Repository
        |                                       |
        |                                normal Git refs
        |                                       |
        |                                refs/kmt/mtime
        |                                       |
        |                                  KMT Git tree
        |                                       |
        +-------------------+-------------------+
                            |
                    .git/kmt/mtime
                  local KMT work state
                            |
                            v
                    KMT decision engine
                            |
            +---------------+---------------+
            |               |               |
        Complete       Synchronize       Resolve
            |               |               |
            v               v               v
       Repository        Filesystem      Repository
         metadata          mtime          metadata
```

Fundamental invariant:

```text
Git owns content.
KMT owns preserved filesystem mtime.
.git/kmt/mtime is local state.
refs/kmt/mtime is repository KMT state.
```
