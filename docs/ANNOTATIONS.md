# Beans annotations

Status: implementation contract. `@test` is not part of this work.

Annotations are typed metadata by default. They do not change Beans ownership,
layout, visibility, ABI, or safety rules. A schema may opt into the compiler's
checked runtime-hook contract; that adds direct handler calls, not text macro
expansion.

## Syntax

Annotation names use `snake_case`, like functions and values.

```beans
@target(value: ["function", "method"])
@retention(value: "tool")
pub annotation audit {
    event: string
    level: string = "info"
}

@audit(event: "checkout")
fn charge(amount: decimal) {
    // ...
}
```

An annotation use is `@name` or `@name(key: value, ...)`. Imported
annotations use the normal package binding: `@telemetry.audit(...)`.
Arguments are always named. Their values must be compile-time constants.
Supported values are booleans, numbers, strings, enum variants, and lists of
supported values. Calls, closures, interpolation, object
construction, and reads of runtime values are not constants.

An annotation declaration is a schema. Every field has an explicit type. A
field with no default is required. A field with a default is optional. Schema
types are `bool`, integer and float types, `decimal`, `string`, an enum, or
`List<T>` of a supported schema type. Annotation declarations are not
runtime classes and live in their own annotation namespace.

## Meta-annotations

The compiler owns four schema meta-annotations. They may only annotate an
`annotation` declaration.

- `@target(value: [...])` limits where the annotation may be used. Valid names
  are `annotation`, `type`, `function`, `method`, `field`, `variant`,
  `parameter`, `local`, and `c_global`. With no `@target`, every target is
  allowed.
- `@retention(value: "source" | "tool" | "runtime")` selects whether checked
  metadata is dropped after checking, kept for semantic tools, or also emitted
  for `std.reflect`. The default is `tool`. Runtime annotations may target
  annotations, types, functions, methods, fields, variants, and parameters.
  Runtime retention on locals and C globals is rejected because reflection has
  no descriptor for either target.
- `@repeatable` allows the same annotation more than once on one target.
- `@runtime_hook(before: "fn", after_return: "fn")` makes an annotation active
  on functions and methods. At least one phase is required. See
  [Runtime hooks](RUNTIME_HOOKS.md) for handler signatures and ordering.

Other annotation errors are compile errors: an unknown or private annotation,
a duplicate non-repeatable annotation, a wrong target, an unknown or repeated
argument, a missing required argument, a wrong value type, or a non-constant
value.

## Placement

Annotations come after a doc comment and before modifiers. They may annotate
types, functions, methods, fields, enum variants, parameters, locals, C
globals, and other annotation declarations.

```beans
/// Public operation.
@audit(event: "checkout")
pub fn checkout(@redact value: string) {
    @debug var attempts: int = 0
}
```

They do not annotate call arguments, general expressions, statements, type
uses, or generic parameters. A local annotation such as `@debug var value`
remains metadata; version one runtime hooks only target functions and methods.

## Runtime hooks and application lifecycle

`@runtime_hook` binds an annotation schema to checked `before` and
`after_return` handler functions. The compiler emits direct synchronous calls.
It does not scan reflection data and does not start a new thread per call.
Handlers cannot change the receiver, arguments, or return value.

`@runtime_start` and `@runtime_stop` mark no-argument functions in the root
application package. Starts run in declaration order before the body of
`main`. Stops run in reverse order after normal return from `main`. Imported
libraries cannot register process lifecycle work.

Nested hook dispatch is skipped while a handler runs on the same thread. The
nested function body still runs. Full rules and examples are in
[Runtime hooks](RUNTIME_HOOKS.md).

## Implementation checklist

- [x] Parse declarations, uses, qualified names, and named arguments in both
      compilers.
- [x] Store annotations on every allowed AST target without changing normal
      child positions.
- [x] Register annotation schemas in their own package-aware namespace.
- [x] Resolve imports and enforce annotation visibility.
- [x] Check meta-annotations, schema types, defaults, arguments, constants,
      targets, and duplicates.
- [x] Keep `tool` annotations as checked HIR metadata and omit `source`
      annotations from HIR.
- [x] Keep `runtime` annotations and checked constant values through HIR, MIR,
      both interpreters, and native metadata tables.
- [x] Expose annotation declarations, schemas, defaults, targets, repeated
      uses, and argument values through `std.reflect`.
- [x] Show annotation declarations and uses in AST, HIR, and semantic tooling.
- [x] Add parser, checker, package, target, retention, and compiler-parity
      tests. Do not add `@test` behavior yet.
- [x] Remove the old special parser handling for `@c_layout` and `@move_only`;
      they now follow the normal unknown-annotation path. Keep the general `@`
      token.
- [x] Add checked runtime hooks for functions and methods plus root application
      start and stop callbacks. Keep local annotations as metadata.
- [x] Cover runtime-hook order, lifecycle, recursion suppression, diagnostics,
      package use, interpreters, native builds, fuzzing, and sanitizers.
- [x] Run the focused suites and the self-hosting fixed-point check.
