# MIR inventory

Every checked program goes through MIR on its way to LLVM; nothing skips it.
This file is the reference for what the model contains and where each part is
covered by a test.

This once inventoried two MIR models side by side, because a C++ stage-0
compiler had one of its own. That compiler is gone, so what follows is the
model.

## The model

`src/mir.b` defines these value-producing or effect operations, with the
supporting types in `src/mir_types.b` and `src/mir_effects.b`:

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

## Coverage

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

The LLVM emitter ends in a hard diagnostic naming any unknown MIR operation
rather than substituting another one, so an operation that reaches emission
without support is a build failure and not silently different code.
