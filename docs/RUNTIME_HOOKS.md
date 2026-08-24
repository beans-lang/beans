# Beans runtime hooks

Status: implemented. `@test` is not part of this work.

Runtime hooks are compiler-wired calls made from annotations. They are not
text macros, and the runtime does not scan reflection metadata on every call.
The compiler resolves every hook, checks its signature, and emits an ordinary
direct call.

## Version-one surface

An annotation declaration becomes active with `@runtime_hook`:

```beans
@runtime_hook(before: "log_before", after_return: "log_after_return")
@target(value: ["function", "method"])
annotation log {
    level: string = "info"
}

fn log_before(target: string, level: string) {
    // Short, synchronous work. A logger may enqueue an owned event here.
}

fn log_after_return(target: string, level: string) {
}

@log(level: "debug")
fn calculate() {
}
```

The handler names are top-level functions in the annotation's package. At
least one of `before` or `after_return` is required. A handler takes the
qualified target name followed by every annotation field in schema order.
It must be synchronous, non-generic, non-extern, return no value, and borrow
all arguments. Hook annotations may target only concrete functions and
methods in this version. Async completion needs a separate later design.

Before handlers run in annotation source order. After-return handlers run in
reverse order. An after-return handler runs for every normal return, including
`?` propagation, but not for panic or `os.exit`. Hooks cannot read or change
the call's arguments, receiver, or result.

Application lifecycle uses two compiler annotations:

```beans
@runtime_start
fn open_services() {
}

@runtime_stop
fn close_services() {
}
```

Lifecycle callbacks must be top-level functions in the root application
package. They take no arguments, return no value, and are synchronous,
non-generic, and non-extern. Starts run in declaration order after the Beans
runtime is ready and before `main` begins. Stops run in reverse order after a
normal exit from `main`. They are not promised after panic, `os.exit`, forced
termination, or power loss. Libraries cannot start work merely because they
were imported.

Hooks run on the caller's current thread. They never create one thread per
call. A hook that needs background work must enqueue an owned, `Send` value to
an explicitly managed worker. Lifecycle callbacks own starting, stopping,
joining, and draining that worker.

While a handler is running, nested annotated functions still run their normal
body, but their hook handlers are skipped. This prevents accidental recursion.
The guard is separate for each thread. A handler panic follows the normal
Beans panic rule; it does not turn into a swallowed logging error.

`init` and `deinit` remain the object lifecycle. Runtime hooks do not add a
second construction or destruction system.

## Implementation checklist

- [x] Reserve and parse `@runtime_hook`, `@runtime_start`, and `@runtime_stop`
      in both compilers without adding special lexer tokens.
- [x] Carry resolved hook and lifecycle metadata through checked HIR and MIR.
- [x] Resolve handler names inside the annotation package and check the full
      handler contract with matching diagnostics in both compilers.
- [x] Reject hook use on abstract, extern, generic-template, `init`, and
      `deinit` declarations in version one.
- [x] Emit before calls in source order and after-return calls in reverse order
      for every normal exit.
- [x] Suppress nested hook dispatch while a handler is running, separately for
      each thread.
- [x] Run root application starts in declaration order and stops in reverse
      order; do not attach lifecycle behavior to imported libraries.
- [x] Support the tree interpreters, native LLVM emitters, debug mode, release
      mode, and the fixed point.
- [x] Show active wiring in HIR/MIR output so generated behavior is inspectable.
- [x] Add positive runtime tests, ordering tests, early-return tests, method
      tests, lifecycle tests, real thread-local dispatch tests, and exact
      negative diagnostics.
- [x] Add valid and invalid runtime-hook cases to the frontend fuzz corpus.
- [x] Document the public surface in the language spec, annotation guide,
      website, changelog, and examples.
- [x] Run focused tests, all tests, frontend fuzz, semantic differential fuzz,
      reflection fuzz, sanitizers, and the fixed-point gate.

## Later work

The first version does not provide `around`/`proceed`, argument or result
mutation, local-variable runtime hooks, dependency injection scopes, request
lifecycle, or a test runner. Each needs its own
ownership and failure rules instead of being hidden in the first ABI.
