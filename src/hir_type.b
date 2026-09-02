package main

fn no_hir_type() -> HirType {
    return new HirType("")
}

fn poison_hir_type() -> HirType {
    return new HirType("poison")
}

fn canonical_hir_name(name: string) -> string {
    if name == "i64" { return "int" }
    if name == "byte" { return "u8" }
    if name == "f64" { return "float" }
    return name
}

fn hir_type_key(type: HirType) -> string {
    if type.name == "array" {
        return "[{hir_type_key(type.args[0])};{type.array_length}]"
    }
    if type.name == "fn" {
        var parameters: List<string> = []
        for index: int in 0..type.fn_parameter_count {
            parameters.push(hir_type_key(type.args[index]))
        }
        var result: string = "unit"
        if type.fn_parameter_count < type.args.len() {
            result =
                hir_type_key(type.args[type.fn_parameter_count])
        }
        let prefix: string =
            if type.fn_sendable { "send " } else { "" }
        return "{prefix}fn({parameters.join(",")})->{result}"
    }
    let name: string = canonical_hir_name(type.name)
    if name == "Result" && type.args.len() == 1 {
        return "Result<{hir_type_key(type.args[0])},Error>"
    }
    if type.args.len() == 0 { return name }
    var arguments: List<string> = []
    for argument: HirType in type.args {
        arguments.push(hir_type_key(argument))
    }
    return "{name}<{arguments.join(",")}>"
}

fn hir_types_equal(left: HirType, right: HirType) -> bool {
    if left.name == "poison" || right.name == "poison" {
        return true
    }
    return hir_type_key(left) == hir_type_key(right)
}

fn hir_is_integer(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    return name == "int" || name == "i8" || name == "i16" ||
           name == "i32" || name == "u8" || name == "u16" ||
           name == "u32" || name == "u64"
}

fn hir_is_float(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    return name == "float" || name == "f32"
}

fn hir_is_numeric(type: HirType) -> bool {
    return hir_is_integer(type) || hir_is_float(type) ||
           type.name == "decimal"
}

fn hir_named(name: string, arguments: List<HirType>) -> HirType {
    let result: HirType = new HirType(name)
    for argument: HirType in arguments {
        result.args.push(argument)
    }
    return result
}

fn hir_list(element: HirType) -> HirType {
    return hir_named("List", [element])
}

fn hir_option(element: HirType) -> HirType {
    return hir_named("Option", [element])
}

fn hir_result(value: HirType) -> HirType {
    return hir_named(
        "Result", [value, new HirType("Error")])
}

// The error a Result carries. `Result<T>` leaves the slot unwritten and
// means the builtin `Error` (spec/SYNTAX.md, "Option and Result"), so every
// reader has to fill it in the same way.
fn hir_result_error(type: HirType) -> HirType {
    if type.args.len() >= 2 { return type.args[1] }
    return new HirType("Error")
}

fn hir_function(parameters: List<HirType>,
                result_type: HirType) -> HirType {
    let result: HirType = new HirType("fn")
    for parameter: HirType in parameters {
        result.args.push(parameter)
    }
    result.fn_parameter_count = parameters.len()
    result.args.push(result_type)
    return result
}

fn hir_send_function(parameters: List<HirType>,
                     result_type: HirType) -> HirType {
    let result: HirType = hir_function(parameters, result_type)
    result.fn_sendable = true
    return result
}

fn hir_type_from_ast(node: AstNode) -> HirType {
    if node.kind == "array_type" {
        let result: HirType = new HirType("array")
        result.array_length =
            node.value.to_int().expect("array length")
        match type_child(node) {
            some(element) => {
                result.args.push(hir_type_from_ast(element))
            }
            none => {}
        }
        return result
    }
    if node.kind == "fn_type" {
        let result: HirType = new HirType("fn")
        result.fn_sendable = node.value == "send"
        for child: AstNode in node.children {
            result.args.push(hir_type_from_ast(child))
        }
        result.fn_parameter_count = result.args.len()
        if node.note == "has_result" {
            result.fn_parameter_count -= 1
        }
        return result
    }
    let name: string =
        if node.resolved != "" { node.resolved } else { node.value }
    let result: HirType =
        new HirType(canonical_hir_name(name))
    for child: AstNode in node.children {
        result.args.push(hir_type_from_ast(child))
    }
    return result
}

// Arity of the builtin generic containers, -1 for everything else. The HIR
// lowering validates signature and field types; statement annotations reach
// validate_target_type instead, and both have to refuse a builtin generic
// spelled without its type arguments.
fn builtin_generic_arity(name: string) -> int {
    if name == "Map" || name == "OrderedMap" { return 2 }
    if name == "List" || name == "Thread" || name == "Mutex" ||
       name == "Channel" || name == "Box" || name == "Arena" ||
       name == "Shared" || name == "Weak" || name == "RawPtr" ||
       name == "Slice" || name == "Atomic" ||
       name == "Brew" || name == "TaskGroup" ||
       name == "StoredCallback" ||
       name == "LocalStoredCallback" ||
       name == "CFunctionPtr" {
        return 1
    }
    return -1
}

// Whether a type is or carries a Brew handle anywhere. Brew is scope-bound:
// it may appear only as the outermost type of the let that brewed it, so
// every stored position — fields, parameters, results, type arguments —
// asks this and refuses.
fn hir_type_contains_brew(type: HirType) -> bool {
    if canonical_hir_name(type.name) == "Brew" { return true }
    for argument: HirType in type.args {
        if hir_type_contains_brew(argument) { return true }
    }
    return false
}

// The same scope-bound story for a whole fleet: a TaskGroup may appear
// only as the outermost type of the let that made it.
fn hir_type_contains_task_group(type: HirType) -> bool {
    if canonical_hir_name(type.name) == "TaskGroup" { return true }
    for argument: HirType in type.args {
        if hir_type_contains_task_group(argument) { return true }
    }
    return false
}

fn builtin_class_name(name: string) -> bool {
    return name == "Bytes" || name == "File" ||
           name == "Dir" || name == "MMap" ||
           name == "RawPtr" || name == "Slice" ||
           name == "List" || name == "Map" ||
           name == "OrderedMap" || name == "Box" ||
           name == "Arena" || name == "Shared" ||
           name == "Weak" || name == "Mutex" ||
           name == "Atomic" || name == "Channel" ||
           name == "Thread" || name == "AtomicInt" ||
           name == "Gate" ||
           name == "Brew" || name == "TaskGroup" ||
           name == "StoredCallback" ||
           name == "LocalStoredCallback" ||
           name == "CFunctionPtr" ||
           simd_description(name).is_some()
}

// One policy table for compiler-owned types. An empty result means the type
// is declared in Beans and must be checked from its declaration. Unknown or
// newly reserved builtin names fall back to local-only below, so adding a
// builtin can never silently make it safe to cross a thread.
fn builtin_thread_policy(type: HirType) -> string {
    let name: string = canonical_hir_name(type.name)
    if hir_is_numeric(type) || name == "bool" || name == "string" ||
       name == "unit" || name == "RawPtr" ||
       name == "CFunctionPtr" || name == "Slice" ||
       name == "Error" || name == "Atomic" ||
       name == "AtomicInt" || name == "Gate" ||
       simd_description(name).is_some() {
        return "always"
    }
    if name == "array" || name == "Option" || name == "Result" {
        return "same_arguments"
    }
    if name == "List" || name == "Map" ||
       name == "OrderedMap" || name == "Box" || name == "Arena" {
        return "send_arguments"
    }
    if name == "Bytes" || name == "File" || name == "MMap" {
        return "send_only"
    }
    if name == "Shared" || name == "Weak" {
        return "shared_arguments"
    }
    if name == "Channel" { return "channel_argument" }
    if name == "Mutex" { return "mutex_argument" }
    if name == "Thread" { return "thread_result" }
    // A Brew belongs to the scope and the worker that brewed it; sending it
    // would let another thread join or cancel a fiber only its own worker
    // may touch. Cross-thread hand-off is what thread.spawn is for. A
    // TaskGroup is a whole fleet of them and is bound the same way.
    if name == "Brew" || name == "TaskGroup" { return "local" }
    if name == "fn" {
        return if type.fn_sendable { "send_only" } else { "local" }
    }
    // C may invoke an any-thread callback from any thread, but its registration
    // owner stays local until it is unregistered and explicitly closed.
    if name == "StoredCallback" { return "local" }
    if name == "LocalStoredCallback" { return "local" }
    if builtin_type(name) { return "local"
    }
    return ""
}

// Move-only and thread-safe are separate facts. A unique value can still be
// thread-affine, and an immutable shared value can be Send without being
// unique. Keep the ownership list here rather than beside capture checking.
fn builtin_move_policy(type: HirType) -> string {
    let name: string = canonical_hir_name(type.name)
    if name == "Box" || name == "Arena" || name == "List" ||
       name == "Map" || name == "OrderedMap" ||
       name == "StoredCallback" || name == "LocalStoredCallback" ||
       name == "Bytes" ||
       name == "Brew" || name == "TaskGroup" ||
       name == "File" || name == "MMap" {
        return "unique"
    }
    if name == "fn" {
        return if type.fn_sendable { "unique" } else { "copy_or_alias" }
    }
    if builtin_type(name) { return "copy_or_alias"
    }
    return "declared"
}
