# git_kmt Design Documents

Initial design documents for Git Keep MTime.

## Documents

- `Architecture.md` — overall architecture and KMT metadata model.
- `Command-State-Model.md` — public commands, states, safety rules, and
  state transitions.

## Key Architecture Decision

KMT metadata is intentionally hidden from the normal working tree.

```text
.git/kmt/mtime       local KMT working state/cache
refs/kmt/mtime       repository-side versioned KMT metadata
```

The normal project tree therefore does not contain a `.kmt/mtime` file.

`refs/kmt/mtime` is the repository-side authoritative KMT state, while
`.git/kmt/mtime` is recoverable local working state.
