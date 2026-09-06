# AGENTS.md — Git Keep MTime

## Project

Git Keep MTime (`git_kmt`) is a Git extension that preserves filesystem modification times by storing mtime metadata in Git Notes and synchronizing the working tree after relevant Git operations.

Current release target: **v0.1.3-alpha**.

## Public Repository Structure

The GitHub/main-branch release exposes the KMT entry point as:

```text
shell/git_kmt.sh
```

Documentation should describe the public `main` branch layout, not the temporary internal source decomposition used by the development branch.

Do **not** document internal development files such as separate `git.sh`, `kmt.sh`, or `utility.sh` modules as part of the public program structure unless the release layout explicitly changes.

## Public Commands

Installation and upgrade are initiated through the source script:

```sh
./shell/git_kmt.sh kmt-install
./shell/git_kmt.sh kmt-upgrade
```

Uninstall is performed through the installed Git wrapper:

```sh
git kmt-uninstall
```

Main user-facing KMT operations include:

```text
git kmt-scan
git kmt-complete
git kmt-synchronize
git kmt-resolve
git kmt-version
```

`kmt-note` exists but is not yet considered a stable public inspection interface. Do not add it to README or general user documentation until its behavior and interface are sufficiently complete.

## Storage

The persistent KMT Notes namespace is:

```text
refs/notes/kmt/mtime
```

KMT note entries use the logical format:

```text
<STX>filename<ETX>mtime
```

The STX prefix is significant because KMT uses exact fixed-string searches such as:

```sh
grep -m 1 -F "$STX$filename$ETX"
```

when locating an individual file entry.

## Terminology

Use **synchronize / synchronization** for applying repository mtime metadata to the working tree.

Avoid reverting to the old SVN-oriented `restore` terminology when describing KMT's mtime operation. `restore` may still appear when referring to the actual Git command `git restore`.

## Architecture Principles

- Git continues to own repository content and commit history.
- KMT metadata is separate from Git tree content.
- Git Notes are used for versioned mtime metadata.
- Mtime changes should be handled incrementally where possible.
- Switch and checkout are important user-visible synchronization scenarios.
- Safety checks should prevent unsafe or ambiguous timestamp overwrites.

## Documentation Rules

README should focus on:

1. The user problem.
2. The switch/checkout use case.
3. Installation and Quick Start.
4. Main KMT commands.
5. Git Notes at a high level.
6. Current alpha limitations.

Detailed storage and implementation information belongs in `docs/Architecture.md` and `docs/Storage.md`.

Do not document `kmt-note` as a normal public feature until it is stable.

Do not expose the development branch's internal shell-module layout in public documentation.

## Release Discipline

Before publishing a release:

- Verify the documented version against `KMT_VERSION`.
- Verify all documented command names and invocation paths.
- Verify the Git Notes ref is `refs/notes/kmt/mtime`.
- Remove obsolete references to the former `timestamps` notes ref.
- Ensure the public documentation refers to `shell/git_kmt.sh`.
- Keep alpha limitations explicit until the corresponding features are stable.
