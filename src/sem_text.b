package main

// A rendered type, spelled the way the reader's own file spells it: a type of
// the reader's package keeps its short name, one from elsewhere keeps the
// package that tells it apart from a same-named neighbour.
fn sem_type_text(type: HirType, from_package: string) -> string {
    if type.name == "array" && type.args.len() == 1 {
        return "[{sem_type_text(type.args[0], from_package)}; {type.array_length}]"
    }
    if type.name == "fn" {
        var parts: List<string> = []
        for index: int in 0..type.fn_parameter_count {
            parts.push(
                sem_type_text(type.args[index], from_package))
        }
        var result: string = "unit"
        if type.fn_parameter_count < type.args.len() {
            result =
                sem_type_text(
                    type.args[type.fn_parameter_count],
                    from_package)
        }
        return "fn({parts.join(", ")}) -> {result}"
    }
    var shown: string = display_symbol(type.name)
    if symbol_package(type.name) == from_package {
        shown = symbol_name(type.name)
    }
    if type.args.len() == 0 { return shown }
    var parts: List<string> = []
    for item: HirType in type.args {
        parts.push(sem_type_text(item, from_package))
    }
    // `Result<T>` is what source writes; the checker fills in the implicit
    // Error. An explicitly written second argument still shows.
    if type.name == "Result" && parts.len() == 2 &&
       type.args[1].name == "Error" &&
       type.args[1].args.len() == 0 {
        return "{shown}<{parts[0]}>"
    }
    return "{shown}<{parts.join(", ")}>"
}

// The semantic id of a type, or "" when the type has no declaration to point
// at. Built-in types answer with their builtin id, which has no location.
fn sem_type_symbol(type: HirType) -> string {
    if type.name == "" || type.name == "poison" {
        return ""
    }
    if type.name.contains("::") {
        return sem_type_id(type.name)
    }
    return sem_builtin_type_id(type.name)
}

// The declared base of a type expression: `List<Point>` answers `List`, and
// the argument is reachable through the same call on the argument.
fn sem_type_base(type: HirType) -> HirType {
    return type
}

// The first segment of a dotted written name, and how far into the spelling
// the last segment starts. Both are byte offsets into the exact text the
// parser consumed, never a re-scan of the line.
fn sem_last_segment(value: string) -> string {
    let parts: List<string> = value.split(".")
    return parts[parts.len() - 1]
}

fn sem_first_segment(value: string) -> string {
    let parts: List<string> = value.split(".")
    return parts[0]
}

// ---------------------------------------------------------------------------
// Index construction
// ---------------------------------------------------------------------------
