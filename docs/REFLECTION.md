# Beans reflection

Status: implemented contract and verification list.

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

`Field.get`, `Field.set`, `Method.call`, `Function.call`, `Initializer.call`,
and `Variant.make` return `Result` for unknown receivers, bad argument counts,
bad argument types, inaccessible members, unsupported signatures, and errors
reported by the called operation. A reflected call cannot expose `deinit`.

Open generic declarations have metadata but cannot be called. The first
runtime version also rejects reflected calls to async, `extern`, variadic, and
`inout` signatures. Those forms need a separate execution design; silently
calling them with the wrong ownership or ABI would be unsafe.

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
- [x] Support all operations in both tree interpreters and both LLVM emitters.
- [x] Cover ownership, inheritance, overrides, visibility, generics,
      annotations, containers, enums, bad arguments, and unsupported calls.
- [x] Add parser/checker fuzz seeds and a reflection differential action fuzzer.
- [x] Document the language form, stdlib API, runtime annotations, safety,
      examples, limits, and serializer integration in `./website`.
- [x] Pass focused tests, all tests, fuzz smoke tests, sanitizers, and the
      self-hosting fixed-point gate.
