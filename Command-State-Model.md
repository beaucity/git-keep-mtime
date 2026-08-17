# Git Keep MTime Command and State Model

## 1. Purpose

This document defines the public commands, KMT states, Git working-tree
states, and state transitions of `git_kmt`.

The model follows the SVN KMT 0.7.8 terminology and safety principles.

The primary operation name is:

```text
synchronize
```

not `restore`.

---

## 2. Public Commands

Recommended commands:

```text
git kmt
git kmt-complete
git kmt-synchronize
git kmt-sync
git kmt-resolve
git kmt-version
git kmt-uninstall
```

Installation and upgrade:

```text
./git_kmt.sh kmt-install
./git_kmt.sh kmt-upgrade
```

---

## 3. Interactive Manager

`git kmt` provides:

```text
1  Scan directories
2  List mtime completed files
3  List mtime completable files
4  List mtime synchronizable files
5  List files with mtime conflicts
6  List mtime unsynchronizable files
7  Complete mtime from local file mtime
8  Synchronize local mtime from repository metadata
9  Resolve mtime conflicts using local file mtime
```

The terminology intentionally stays aligned with SVN KMT.

---

## 4. Core KMT States

Each tracked file receives one primary KMT state:

```text
Completed
Completable
Synchronizable
Conflict
Unsynchronizable
```

Classification uses:

```text
file_ts
metadata_ts
version_ts
Git status
file existence
timestamp validity
```

---

## 5. Completed

A file is `Completed` when KMT metadata exists and local filesystem mtime
is already synchronized.

Typical condition:

```text
file_ts == metadata_ts
```

No KMT action is required.

---

## 6. Completable

A file is `Completable` when:

- KMT metadata is missing;
- local mtime is valid;
- the working copy appears able to provide a safe timestamp;
- initialization safety rules pass.

For existing repositories, a primary heuristic is:

```text
file_ts < version_ts
```

This is a safety heuristic, not proof of historical correctness.

---

## 7. Synchronizable

A file is `Synchronizable` when:

- KMT metadata exists;
- metadata is valid;
- there is no active mtime conflict;
- applying repository metadata is safe.

Operation:

```text
metadata_ts -> filesystem mtime
```

---

## 8. Conflict

A file is `Conflict` when local and repository timestamps disagree in a way
that cannot be safely resolved automatically.

Example:

```text
metadata_ts = 1755361000
file_ts     = 1755362000
```

KMT must not silently select one value.

---

## 9. Unsynchronizable

A file is `Unsynchronizable` when KMT metadata is missing and the current
working copy cannot safely provide an original timestamp.

Typical example:

```text
metadata missing
file_ts >= version_ts
```

Another working copy may still be able to complete the file.

---

## 10. Git Working-Tree States

KMT also considers:

```text
Clean
Modified
Added
Deleted
Renamed
Unmerged
```

These are Git states, separate from KMT states.

Example:

```text
Git: Modified
KMT: Conflict
```

is valid.

---

## 11. Scanner Data

The scanner conceptually produces:

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

`metadata_ts` comes from:

```text
.git/kmt/mtime
```

which is materialized from:

```text
refs/kmt/mtime
```

when needed.

---

## 12. State Classification

Recommended order:

```text
1. Invalid / unsupported
2. Conflict
3. Metadata exists
   |
   +-- synchronized -> Completed
   +-- safe synchronization -> Synchronizable
   +-- unsafe -> Conflict
4. Metadata missing
   |
   +-- safe candidate -> Completable
   +-- unsafe -> Unsynchronizable
```

All scanner backends must produce equivalent KMT states.

---

## 13. Complete

Direction:

```text
LOCAL -> KMT REPOSITORY
```

Flow:

```text
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

The resulting KMT ref state must be synchronized with remote KMT state by
the Git backend.

---

## 14. Synchronize

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
filesystem
```

Synchronize changes only local filesystem mtime.

---

## 15. Resolve

Direction:

```text
LOCAL -> KMT REPOSITORY
```

but only for a known conflict.

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

`resolve` is not an unconditional force operation.

---

## 16. Complete vs Resolve

Mandatory distinction:

```text
Completable -> complete
Conflict     -> resolve
```

`complete` creates missing metadata.

`resolve` replaces conflicting metadata after explicit validation.

---

## 17. Complete vs Synchronize

Complete:

```text
LOCAL -> REPOSITORY
```

Synchronize:

```text
REPOSITORY -> LOCAL
```

Complete may change KMT repository state.

Synchronize must not.

---

## 18. Future Timestamp

Any:

```text
file_ts > current_time
```

is invalid.

It must never be written to KMT repository metadata.

Affected operations include:

```text
complete
resolve
automatic commit processing
```

---

## 19. Existing Metadata Must Not Move Backwards

If:

```text
metadata_ts > local_candidate_ts
```

KMT must not silently replace newer metadata with an older local timestamp.

The file remains a conflict or the operation is rejected.

---

## 20. Identical Timestamp

If:

```text
file_ts == metadata_ts
```

KMT must not rewrite metadata.

The file remains:

```text
Completed
```

---

## 21. Initialization State Transition

```text
metadata missing
        |
        +---- safe local timestamp ----> Completable
        |                                  |
        |                               complete
        |                                  |
        |                                  v
        |                              repository
        |                              KMT metadata
        |
        +---- unsafe -----------------> Unsynchronizable
```

---

## 22. Normal Synchronization

```text
Synchronizable
      |
      | synchronize
      v
Completed
```

If synchronization discovers an unsafe local condition:

```text
Synchronizable
      |
      v
Conflict
```

Repository metadata is not changed.

---

## 23. Conflict Resolution

```text
Conflict
    |
    | resolve
    v
validate local mtime
    |
    +---- invalid ----> Conflict
    |
    +---- valid ------> repository metadata
                             |
                             v
                         Completed
```

---

## 24. Working-Tree Clean State

The preferred state for explicit KMT operations is:

```text
no uncommitted content changes
no unresolved Git conflicts
```

Especially:

```text
complete
resolve
```

should operate only when Git state is sufficiently well-defined.

---

## 25. Modified Files

A modified Git file must not automatically become `Completable`.

KMT must distinguish content modification from an mtime-only difference.

This prevents KMT from recording a timestamp belonging to a newly modified
file.

---

## 26. Unmerged Files

For an unmerged Git path:

```text
Git state = Unmerged
```

KMT should not modify repository metadata automatically.

Preferred sequence:

```text
resolve Git content conflict
        |
        v
inspect KMT state
        |
        v
resolve KMT conflict if required
        |
        v
commit
```

---

## 27. Added Files

A new file has no previous Git path history.

Its local mtime may become KMT metadata if it passes validation.

A future timestamp must still be rejected.

---

## 28. Deleted Files

When a tracked file is deleted, its KMT metadata must also be removed.

The deletion and metadata removal should normally be represented by the same
logical Git operation.

---

## 29. Renamed Files

For:

```text
old.txt -> new.txt
```

KMT should preserve the mtime association when Git provides enough evidence
of a safe rename.

Ambiguous rename/copy situations must not silently assign the wrong mtime.

---

## 30. Branch Switching

Example:

```text
main:
foo.txt -> 10:00

feature:
foo.txt -> 11:00
```

After:

```text
git switch main
```

KMT loads the main state.

After:

```text
git switch feature
```

KMT loads the feature state.

The active state is materialized into:

```text
.git/kmt/mtime
```

and the working tree is synchronized as necessary.

---

## 31. Merge

A merge can produce two independent conflict classes:

```text
Git content conflict
KMT mtime conflict
```

Possible combinations:

```text
content clean + mtime clean
content clean + mtime conflict
content conflict + mtime clean
content conflict + mtime conflict
```

Resolving one does not automatically resolve the other.

---

## 32. Rebase

Rebase can rewrite Git history containing KMT metadata.

KMT follows the resulting Git state rather than inferring mtime from rewritten
filesystem timestamps.

Affected files are rescanned after rebase.

---

## 33. Reset / Restore / Revert

These operations can replace working-tree content:

```text
git reset
git restore
git revert
```

Afterward KMT reevaluates affected paths.

They may become:

```text
Synchronizable
Completable
Unsynchronizable
Conflict
```

depending on the metadata and safety rules.

---

## 34. Pull

A pull may update:

```text
normal Git refs
KMT ref
```

The wrapper should refresh KMT state consistently:

```text
pull
  |
  v
refresh KMT metadata
  |
  v
scan
  |
  v
synchronize / report conflict
```

---

## 35. Push

A push should include KMT repository state when changed:

```text
git push
    |
    +-- normal refs
    |
    +-- refs/kmt/mtime
```

Users should not need a separate KMT push command.

---

## 36. Commit

Normal:

```text
git commit
```

may perform KMT processing:

```text
1. inspect affected files
2. validate mtime
3. update local KMT metadata
4. update KMT repository state
5. commit
```

If required KMT metadata cannot be safely generated, the commit should be
aborted before the original Git commit.

---

## 37. Commit Failure

Example:

```text
future mtime
    |
    v
KMT validation failure
    |
    v
git commit aborted
```

The goal is to avoid committing Git content without required KMT metadata.

---

## 38. Synchronize Failure

If filesystem mtime cannot be applied:

```text
Synchronize
    |
    v
filesystem operation failed
```

KMT reports the affected path.

It must not report `Completed` until the filesystem timestamp has actually
been verified.

---

## 39. Scan Output

Recommended output:

```text
Versioned files checked: N
Completed: N
Completable: N
Synchronizable: N
Conflicts: N
Unsynchronizable: N
```

State semantics must remain stable even if wording changes later.

---

## 40. Command Safety Matrix

| Command | Read KMT | Write local mtime | Write KMT repo state | Commit/push |
|---|---:|---:|---:|---:|
| `git kmt` | Yes | No | No | No |
| `git kmt-complete` | Yes | No | Yes | Yes, as designed |
| `git kmt-synchronize` | Yes | Yes | No | No |
| `git kmt-resolve` | Yes | No | Yes | Yes, as designed |
| `git commit` | Yes | No | Yes, when needed | Yes |
| `git checkout` | Yes | Yes, when needed | No | No |
| `git switch` | Yes | Yes, when needed | No | No |
| `git merge` | Yes | Yes, when needed | Possibly | Yes/No |
| `git status` | Yes | No | No | No |

---

## 41. Initialization Workflow

For an existing repository:

```text
1. git pull
2. ensure working tree is clean
3. git kmt
4. Scan
5. Complete eligible files
6. synchronize KMT ref as required
7. other working copies refresh KMT state
8. Synchronize
9. repeat until initialization is complete
```

Desired final state:

```text
Completed:          all eligible tracked files
Completable:        0
Synchronizable:     0
Conflicts:          0
Unsynchronizable:   0
```

---

## 42. Multiple Working Copies

Different working copies may contain different portions of the original mtime.

Example:

```text
Host A:
file A -> Completable
file B -> Unsynchronizable

Host B:
file A -> Unsynchronizable
file B -> Completable
```

After completion and KMT ref synchronization:

```text
repository KMT state:
file A -> metadata
file B -> metadata
```

Both hosts can then synchronize.

---

## 43. Normal Daily Workflow

After initialization, users normally use standard Git:

```text
git pull
git switch feature
edit files
git add .
git commit
git push
```

KMT handles safe metadata processing transparently.

Explicit KMT commands are mainly for:

- initialization;
- inspection;
- repair;
- conflict resolution.

---

## 44. Fundamental Invariants

1. Git content is never changed merely to preserve mtime.
2. KMT metadata never contains a future timestamp.
3. Synchronize never changes repository KMT metadata.
4. Complete never uses an unsafe local timestamp.
5. Resolve is not an unconditional force operation.
6. Missing metadata never means arbitrary local mtime.
7. Conflicts are never silently resolved.
8. All scanner implementations produce equivalent KMT states.
9. Git owns content; KMT owns preserved filesystem mtime.
10. `.git/kmt/mtime` is recoverable local state.
11. `refs/kmt/mtime` is repository-side authoritative KMT state.

---

## 45. First Alpha Scope

Recommended implementation order:

```text
1. Git wrapper
2. Original Git detection
3. .git/kmt/mtime local state
4. KMT metadata representation
5. refs/kmt/mtime
6. Git status/path enumeration
7. Git history timestamp lookup
8. Scanner
9. State classifier
10. kmt-complete
11. kmt-synchronize
12. kmt-resolve
13. Interactive manager
14. commit integration
15. checkout/switch integration
16. pull/push KMT ref synchronization
17. merge/rebase/reset integration
18. installation/uninstallation
19. automated tests
```

Git hooks should be considered only after wrapper behavior is stable.

---

## 46. Alpha Success Criteria

A first alpha should demonstrate:

```text
Repository A
    |
    +-- commit file + KMT mtime
    |
    +-- push KMT ref
    |
    v
Repository B
    |
    +-- clone/fetch
    |
    +-- load KMT metadata
    |
    +-- synchronize
    |
    v
same filesystem mtime
```

It should also demonstrate:

```text
local mtime conflict
    |
    v
Conflict detected
    |
    v
Resolve
    |
    v
KMT metadata updated
    |
    v
push
    |
    v
another working copy
    |
    v
Synchronize
```

without corrupting normal Git content or silently losing timestamp
information.
