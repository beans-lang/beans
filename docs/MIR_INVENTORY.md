# MIR inventory

This file is the promotion checklist for the two MIR models. The C++ model is
the stage-0 reference. The Beans model is the input to the promoted LLVM
emitter. A checked program may not skip MIR or ask `beansc0` to emit it.

## C++ stage-0 MIR

`compiler/bootstrap/mir.h` defines these operations:

`statement`, `evaluate`, `borrow`, `move`, `local_init`, `pattern_bind`,
`assign`, `defer_register`, `run_defer`, `drop_local`, `retain`, `release`,
`edge_drop`, `allocate`, `unwrap`, `phi`, `branch`, `iterate_init`, `iterate`,
`match`, `try_branch`, `propagate`, `jump`, and `return`.

Expression data covers integer, folded layout, float, string and boolean
constants; identifiers and `self`; unary, binary and range expressions; calls,
construction, fields, indexes, lists and initializers; casts, `?`, closures,
`if`, and `match`. Statement data covers declarations, assignment, expression
statements, return, break, continue, all loop forms, `if`, `defer`, and
`unsafe`.

Calls are `named`, `qualified`, `member`, or `value`. Each argument carries
`borrow`, `move`, or `inout`, plus a separate runtime-consumed bit. Fused calls
are `channel_recv_or`, `map_get_or`, and `list_pop_or`. Places are `local`,
`global`, `field`, or `index`. Aggregates are `list`, `new_object`, or
`initializer`. Patterns are wildcard, literal, range, name/payload, or
alternative. Constants are signed integer, unsigned integer, or boolean.
Values are represented as a value, address, or range.

Ownership is `trivial`, `borrowed`, `owned`, or `moved`. Instructions carry
explicit retains and releases. Blocks carry per-successor edge drops.
Closures and deferred cleanups have stable IDs and explicit capture
source/target locals.

Effects are `may_allocate`, `may_panic`, `may_mutate`, `may_escape`, and
`external_call`.

## Self-hosted MIR

`compiler/beans/mir.b` defines these value-producing or effect operations:

`type`, `layout_query`, `literal`, `field_init`, `initializer`, `list`, `map`,
`some`, `none`, `ok`, `err`, `variant`, `unit`, `c_global_read`,
`c_global_write`, `borrow`, `move`, `local_init`, `assign`, `binary`, `unary`,
`cast`, `index`, `new`, `field`, `pattern_bind`, `iterate_init`,
`iterate_next`, `iterate_value`, `phi`, `call`, `function`, `closure`,
`closure_call`, `super_init`, `static_call`, `method_call`, `builtin_call`,
`builtin_method`, `selector`, `unwrap`, `propagate`, `retain`, `drop_local`,
`defer_register`, and `run_defers`.

Terminators are `return`, `match`, `try_branch`, `jump`, and `branch`. `open`
is only the construction sentinel and the verifier rejects it in a finished
block.

Every result has a checked `HirType`. That type carries the canonical name,
generic arguments, function parameter/result types and passing modes. It
covers unit/never, booleans, all signed and unsigned integer widths, `int`,
`f32`, `f64`, `decimal`, strings and bytes, functions and closures, classes,
interfaces and enums, `Option`/`Result`, lists/maps/sets, raw pointers and
slices, fixed arrays, SIMD values, and checked C structs/unions/opaque types.
Target layout queries are folded before emission.

Locals and values are `trivial`, `borrowed`, or `owned`; a move consumes the
owned value instead of creating a fourth live state. Calls carry `borrow`,
`move`, or `inout` for every argument and a matching consumed bit. Each
instruction and terminator has a release list. Each CFG edge has its own
release list. Closures and deferred cleanups have explicit parents, IDs,
captures, and cloned generic families.

The verifier checks value definitions, operand bounds, type and ownership
tables, consumes, releases, owned local initialization, retain shape, phi
predecessors, branch conditions, return type/ownership, CFG targets, captures,
borrow aliases, and all finished terminators. The LLVM emitter ends in a hard
diagnostic naming any unknown MIR operation; it does not substitute another
operation.

## Coverage and differences

The models use different granularity. Stage 0 has broad `evaluate` and
`statement` records with side tables. The self-hosted model makes calls,
aggregates, C globals, raw-memory builtins, atomics, SIMD, variants, closures
and target selectors explicit instructions. Stage-0 `release`, `edge_drop`,
`allocate`, `branch`, `match`, `try_branch`, `jump`, and `return` map to
self-hosted release lists, `new`, or terminators. Stage-0 `run_defer` maps to
`run_defers` plus cleanup functions.

The main coverage is:

| Area | Executable coverage |
|---|---|
| CFG, phi, loops, match, `?` | `test/mir.sh`, `test/cases/mir_control.b`, `examples/tour.b` |
| borrow, move, retain, release, edge cleanup | `test/moves.sh`, `test/closure_captures.sh`, `examples/deep.b`, `examples/cycles.b` |
| closures, captures, generic families, defer | `test/self_host.sh`, `test/cases/self_host_llvm_generic_closure.b`, `test/cases/self_host_llvm_generic_defer.b` |
| defaults and aggregates | `test/default_eval_order.sh`, `test/packed_layout.sh`, `test/inline_options.sh`, `test/inline_results.sh` |
| C calls, records, unions, globals, callbacks | `test/c_abi_tier1.sh` |
| raw memory and atomics | `test/unsafe.sh`, `test/atomics.sh`, `test/stack_pointer.sh` |
| SIMD and target features | `test/simd.sh`, `test/intrinsics.sh`, `test/cpu_features.sh` |
| targets, WASM, embedded | `test/targets.sh`, `test/wasm.sh`, `test/embedded.sh` |

The promotion scan compiles every C++-accepted tracked source through the
self-hosted LLVM emitter. A source is a failure if the emitter reports any
unsupported operation, even when stage 0 can build it.
