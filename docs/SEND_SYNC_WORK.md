# Send and Sync standardization

Status: complete. The user-facing rules, examples and exact handle matrix are
in [CONCURRENCY.md](CONCURRENCY.md). This file remains the implementation and
verification checklist.

`Send` means one owner may move to another OS thread. `Sync` means aliases may
be used from more than one thread. Mutable aliasable values are neither unless
their API synchronizes access.

Every group below needs focused positive and negative checker tests. Compiler
changes also need deterministic output, differential parity, self-hosting, and
the fixed point.

## Work list

- [x] One source of truth
  - [x] Put builtin move and thread-safety policy in one compiler registry.
  - [x] Make trait checking and move checking consume that registry.
  - [x] Cover every reserved builtin name so new types cannot silently get a
        default policy.
- [x] Derived `Send`
  - [x] Make `List<T>`, `Box<T>`, and `Arena<T>` `Send` when `T` is `Send`.
  - [x] Make `Map<K, V>` and `OrderedMap<K, V>` `Send` when both arguments are
        `Send`.
  - [x] Derive `Send` and `Sync` for unions when every field satisfies the
        requested marker.
- [x] Standard-library unique handles
  - [x] Mark handles `Send` only after checking owned aliases, native backend
        state, and cross-thread destruction.
  - [x] Keep signal sets, reactor tasks, and child processes thread-local.
  - [x] Add cross-thread move and destruction tests for every new promise.
- [x] Mutable builtin owners
  - [x] Make `Bytes`, `File`, and `MMap` move-only.
  - [x] Make them `Send` but not `Sync`.
  - [x] Migrate bindings, fields, returns, and calls to explicit moves.
  - [x] Keep deep copying explicit and shared mutation behind `Mutex`.
- [x] Closures and C callbacks
  - [x] Add a sendable function type whose captures must be `Send`.
  - [x] Keep ordinary function values local.
  - [x] Give any-thread and same-thread stored callbacks distinct types.
- [x] Final proof
  - [x] Update the language spec and changelog.
  - [x] Run syntax, ownership, trait, differential, deterministic, platform,
        self-host, and fixed-point gates.
