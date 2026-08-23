# Beans reflection

Status: sync calls and async callable metadata are implemented. Async reflected
calls are part of the async v2 contract and are not implemented yet.

Reflection is typed runtime metadata. It lets a program inspect Beans types,
annotations, fields, enum variants, functions, methods, and initializers. It
also provides checked construction, field access, and calls by name.

The API follows normal Beans rules. Reflection does not bypass visibility,
ownership, moves, `Send`, target support, or ABI checks. There is no Java-style
`setAccessible`, class loader, proxy generator, stack inspection, or raw memory
access.

## Public API

Import `std.reflect`, then use the contextual `type_of(T)` form for a static
type. A boxed dynamic value reports its stored type through `Value.type()`.

```beans
import std.reflect

let user_type: reflect.Type = type_of(User)
let boxed: reflect.Value = reflect.value(move user)
let actual_type: reflect.Type = boxed.type()
```

The package exposes these descriptor value types:

- `Type`, `Field`, `Method`, `Initializer`, `Function`, `Parameter`, and
  `Variant`.
- `Annotation`, `AnnotationType`, `AnnotationField`, `AnnotationArgument`, and
  `AnnotationValue`.
- `Value`, the safe owned box used at a dynamic boundary.
- `Kind`, `Passing`, `AnnotationValueKind`, and `ErrorKind` enums.

Descriptors expose names, qualified names, kinds, generic arguments,
inheritance, parameter and result types, visibility, static/instance state,
defaults, and runtime annotations.
Types expose both declared and inherited fields and methods. Singular lookup
returns `Option<T>`; list queries preserve declaration order.

```beans
for field: reflect.Field in user_type.fields() {
    io.println("{field.name()}: {field.type().qualified_name()}")
}

let name: reflect.Field = user_type.field("name").expect("name field")
let receiver: reflect.Value = reflect.value(move user)
let old: reflect.Value = name.get(receiver).expect("get name")
name.set(receiver, reflect.value("new name")).expect("set name")
```

`reflect.value(value)` owns its payload. Boxing a shared class retains it.
Boxing a copyable value copies it. A move-only value is passed with `move`; the
box then owns it. Checked `as?` unboxes a matching copyable value. Move the box
into `as?` to take a move-only payload.

```beans
let boxed: reflect.Value = reflect.value(42)
let number: int = (boxed as? int).expect("int")

let values: List<int> = [1, 2]
let owned: reflect.Value = reflect.value(move values)
let restored: List<int> =
    (move owned as? List<int>).expect("List<int>")
```

`Field.get`, `Field.set`, `Method.call`, `Method.call_static`, `Function.call`,
`Initializer.call`, and `Variant.make` return `Result` for unknown receivers,
bad argument counts, bad argument types, inaccessible members, unsupported
signatures, and errors reported by the called operation. A reflected call
cannot expose `deinit`.

Open generic declarations have metadata but cannot be called. The sync call
methods reject async, `extern`, variadic, and `inout` signatures. They never
start hidden async work.

## Async callable metadata and calls

Reflection preserves the source type. `Type.qualified_name()` renders
`async fn(A) -> T` and `send async fn(A) -> T`, and their kind is
`function_type`. Field, parameter, and result descriptors keep those types.
`Function.is_async()` and `Method.is_async()` report the call effect. No
descriptor exposes the compiler's hidden task ABI.

Async v2 keeps execution explicit with separate APIs:

```beans
let value: Result<reflect.Value, reflect.ReflectError> =
    await function.call_async(move function_arguments)

let result: Result<reflect.Value, reflect.ReflectError> =
    await method.call_async(receiver, move method_arguments)

let static_result: Result<reflect.Value, reflect.ReflectError> =
    await method.call_static_async(move static_arguments)
```

`Function.call_async`, `Method.call_async`, and `Method.call_static_async` are
themselves async and return the target's final boxed result. They accept only
async targets. The existing sync call methods accept only sync targets. Using
the wrong half returns the stable `unsupported` reflection error; it never
converts an async call into a sync one. Initializers cannot be async, so
`Initializer` has no async call method.

The split APIs are the contract, but are not implemented yet. Until they are,
async declarations can be inspected but every reflected attempt to execute one
is rejected.

## Runtime annotations

`@retention(value: "runtime")` keeps an annotation in the emitted program.
Runtime retention is allowed on annotation declarations, types, functions,
methods, fields, enum variants, and parameters. Locals and C globals can still
use source/tool annotations, but runtime retention on them is a compile error
because this API has no local-variable or foreign-global descriptor.

Annotation values keep their checked scalar, enum, and list shape. Querying an
annotation never evaluates source code. Repeated annotations stay in source
order.

`AnnotationType` exposes retention, repeatability, allowed targets, schema
fields, defaults, and runtime annotations placed on the annotation declaration.

## Discovery and size

`reflect.types()`, `reflect.functions()`, and `reflect.annotation_types()`
return the executable's registry in deterministic declaration order.
`reflect.find_type(qualified_name)` returns a type by its full package name.
The matching `find_function` and `find_annotation_type` helpers use qualified
names too.

Metadata is per executable. Descriptor IDs are not a file format and are not
stable across builds or shared-library boundaries.

## Serialization boundary

Reflection provides all parts needed by a serializer: field order, field and
variant names, runtime annotations, construction, checked get/set, and safe
boxed values. JSON and XML naming, unknown-field, default, versioning, and
numeric-conversion rules belong to `std.encoding.json` and `std.encoding.xml`.
Reflection itself does not guess those policies.

Struct construction is positional and uses every field in declaration order,
including fields with source defaults. The struct and all fields must be
public. Union construction and overlapping field access stay unsupported.

## Implementation and verification list

- [x] Accept `runtime` retention and reject unsupported runtime targets.
- [x] Keep runtime annotations and their checked values through both HIRs.
- [x] Parse and check `type_of(T)` in the self-hosted compiler.
- [x] Add the `std.reflect` source package and its public descriptor API.
- [x] Give every linked concrete type and member deterministic registry order.
- [x] Emit type, relation, member, parameter, variant, and annotation
      tables without changing the existing class vtable ABI.
- [x] Add registry queries, static type lookup, and boxed dynamic type lookup.
- [x] Implement safe owned `Value` boxing, checked copy/take unboxing, clone,
      and drop.
- [x] Inspect primitives, strings, lists, maps, fixed arrays, `Option`, `Result`,
      user enums, structs, classes, and interfaces.
- [x] Implement declared/inherited member iteration and lookup by name.
- [x] Implement checked field read/write with visibility and ownership rules.
- [x] Implement checked class/struct construction and enum variant creation.
- [x] Implement checked public sync calls for functions, static methods,
      instance methods, virtual methods, and initializers.
- [x] Reject `deinit`, open generic, async, extern, variadic, and `inout` calls
      with stable reflection error kinds.
- [x] Preserve `async fn` and `send async fn` names, kinds, parameters and
      results in runtime metadata.
- [ ] Add `Function.call_async`, `Method.call_async`, and
      `Method.call_static_async` without exposing the hidden task ABI.
- [x] Support all operations in both tree interpreters and both LLVM emitters.
- [x] Cover ownership, inheritance, overrides, visibility, generics,
      annotations, containers, enums, bad arguments, and unsupported calls.
- [x] Add parser/checker fuzz seeds and a reflection differential action fuzzer.
- [x] Document the language form, stdlib API, runtime annotations, safety,
      examples, limits, and serializer integration in `./website`.
- [x] Pass focused tests, all tests, fuzz smoke tests, sanitizers, and the
      self-hosting fixed-point gate.
