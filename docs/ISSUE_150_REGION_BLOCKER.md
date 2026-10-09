# Issue 150: verified ownership contract gap

Status: investigation only. This checkout has no request-region language or
runtime implementation. This record does not resolve issue 150. A TLS allocator
switch must not be enabled before the ownership rules below are implemented.

The list-inline-backing half already exists in `runtime/beans_rt.c`:
`beans_list_new_typed` and `list_new_capacity` put a small backing behind the
48-byte header, while `list_backing_grow` migrates growing inline storage to a
separate buffer. The existing scored `bench/record_build.b` row in
`bench/suite.tsv` covers record construction. Neither needs another owner.

## The blocker is object provenance, not binding scope

`spec/SYNTAX.md` permits mutable class aliases, including through `let`.
`src/hir_node.b`'s `LocalBinding` tracks binding depth and move/borrow state;
`HirNode` carries binding identity. These describe names, not the lifetime of
objects reachable through those names. `src/hir.b`'s `HirFunction` carries
parameter ownership modes but no receiver/argument lifetime or escape effect.
`src/mir.b`'s `escapes = true` marks closure capture only.

A binding-depth ban misses this ordinary, valid program:

```beans
class Sink {
    value: string = "empty"
    fn init() {}
}
fn store(sink: Sink, value: string) { sink.value = value }
fn main() {
    let outer: Sink = new Sink()
    if true {
        let alias: Sink = outer
        alias.value = "alias-{7}"
    }
    if true { store(outer, "call-{8}") }
}
```

Replacing the inner block with a region would not make `alias` region-owned.
Its declaration is local, but its referent survives. The store destination must
carry the provenance of `outer`, including after assignments, branches,
aggregate field reads, container reads, and parameter passing.

Suspending the arena around `store` only changes allocations *inside* `store`.
It does not prevent `store` retaining a region argument in `sink.value`.
Therefore ordinary calls must refuse region-bearing arguments unless a checked
non-escape contract exists. Merely marking a function `region fn` cannot make
arbitrary heap receiver/parameter mutation safe either.

## Teardown is an escape edge too

A legal finalizer can publish its own child to an external object:

```beans
class Finalizer {
    sink: Sink
    value: string
    fn init(sink: Sink, value: string) {
        self.sink = sink
        self.value = value
    }
    fn deinit() { self.sink.value = self.value }
}
```

If `value` belongs to a region, running this deinit before bulk reclamation
creates a dangling reference. Suspending allocation during deinit does not
repair it. Blanket refusal of all classes with finalizers would be an explicit
feature restriction, not satisfaction of the issue's deinit requirement.
A finalizer needs the same checked receiver/child provenance and escape effects
as an explicit call. Existing `beans_do_deinit`, `cc_release_children`, and the
interpreter's object-finalization paths remain the owners of cleanup.

## Required contract before implementation

These are design requirements, not additions to the supported language spec:

1. Every region has a distinct lexical lifetime. Reference-bearing expressions
   carry the lifetimes of their reachable children, not just their outer shell.
   A heap container holding a region child still carries the region lifetime.
2. Stores require the destination's lifetime to be no longer than every stored
   region lifetime. A locally declared alias retains its referent's provenance.
   Existing branch scope undo/merge must preserve this information.
3. A `region fn` allocates in its caller's region. Its signature defines which
   argument/receiver provenance can appear in its result and which destinations
   may receive region-bearing values. Its body verifies that contract locally.
   Interface methods, overrides, generic instantiation and function values must
   preserve it; unknown dispatch and FFI cannot silently assume non-escape.
4. Ordinary callees allocate with the region suspended and cannot receive
   region-bearing values without a verified non-escape contract. Restoration
   must cover return, `?`, contained panic and fiber context switching.
5. Closures, thread/fiber/channel payloads, shared/weak handles, raw pointers and
   reflection must enforce the same provenance boundary. An unsafe escape is
   not a sound substitute for the checked guarantee requested by this issue.
6. Region teardown runs each deinit once while its observable graph is intact,
   releases each owned external child once, frees backing buffers, then reclaims
   slabs. Region cycles need no ARC traversal for reclamation, but their
   finalizers still obey the no-publication contract.
7. Nested regions cannot publish inner objects to outer regions. Repeated
   execution cannot reuse a slab until all cleanup for its previous lifetime
   completes. Cleanup that allocates or panics needs a defined suspension and
   unwind policy shared by both backends.

The existing nominal Brew/TaskGroup restrictions cannot establish these rules
for ordinary string, Record and List values. The authoritative extension point
is checked HIR provenance and function contracts, consumed by both backends;
adding only parser syntax, a MIR local flag or a runtime TLS pointer would leave
one or more verified escape paths open.

## Local evidence

On macOS ARM64, the worktree compiler was built with:

```
make BEANSC_BOOT=/Users/julfikar/Documents/Beans/beans/build/issue-audit/beansc-comments-bootstrap
```

`build/issue150/escape_witness.b` combines alias publication, publication through
an ordinary borrowed-parameter call, and publication through deinit. `check`
accepted it; interpreter and native execution both printed:

```
alias-7
call-8
deinit-9
```

These are valid heap programs, not failing region regressions. They demonstrate
why a proposed region checker must model all three edges. Captured command
outputs are in `build/issue150/{check,interpreter,native-build,native}.log`.
The programs and logs are ignored build artifacts, not new regression gates.
No unsafe runtime prototype was run and no sanitizer, region parity, region
cycle, self-host fixed-point or performance-improvement claim is made.

No runtime, language contract, API, dependency, storage or background work was
added. The only tracked addition is this evidence record. There is no allocation
improvement in this change. Espresso annotations and documentation-site updates
remain future integration work after the compiler contract is implemented.

The existing record benchmark was compiled with `build --release --lto --cpu
native`; a second binary was linked from the same `build/record_build.ll` with
`clang -O3 -march=native -pthread -DBEANS_ARC_STATS -Wno-override-module`, the
current `build/beans_rt.c` and `-lm`, matching `bench/profile.sh`'s counter path.
At seed 17 the captured baseline is:

| Records | Object allocations | List backing allocations | Freed shells |
| ---: | ---: | ---: | ---: |
| 1,000 | 4,007 | 1 | 4,007 |
| 4,000,000 | 16,000,007 | 2 | 16,000,007 |

Logs: `build/issue150/record-build.log`, `arc-build.log`,
`record-1000.stdout`, `record-1000.stats`, `record-scored.stdout` and
`record-scored.stats`. This confirms four objects per record plus fixed
setup costs and the retained inline-backing improvement. Counter-instrumented
execution is allocation evidence, not timing evidence. A future region
benchmark must preserve the observable output and surviving-record semantics:
this existing benchmark deliberately keeps one record in a thousand, so wrapping
its complete loop in a region and reclaiming it before `keep` dies is invalid.
