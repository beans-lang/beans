package main

fn mir_type_is_trivial(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    return name == "unit" || name == "bool" ||
           name == "int" || name == "i8" ||
           name == "i16" || name == "i32" ||
           name == "u8" || name == "u16" ||
           name == "u32" || name == "u64" ||
           name == "float" || name == "f32" ||
           name == "decimal" || name == "RawPtr" ||
           name == "CFunctionPtr" ||
           (name == "StoredCallback" ||
            name == "LocalStoredCallback") ||
           name == "Slice" || name == "CpuFeature" ||
           name == "MemoryOrder" || name == "RoundingMode"
}

fn mir_capture_by_value_type(type: HirType) -> bool {
    return type.name == "bool" ||
           hir_is_integer(type) ||
           hir_is_float(type) ||
           canonical_hir_name(type.name) == "RawPtr" ||
           canonical_hir_name(type.name) == "CFunctionPtr"
}

fn mir_type_ownership(type: HirType) -> string {
    if mir_type_is_trivial(type) { return "trivial" }
    return "owned"
}

fn mir_effects_for(kind: string, resolved: string) -> string {
    if kind == "new" || kind == "singleton" ||
       kind == "list" ||
       kind == "map" || kind == "closure" {
        return "allocate,panic"
    }
    if kind == "call" || kind == "runtime_hook_call" ||
       kind == "method_call" ||
       kind == "static_call" || kind == "builtin_call" ||
       kind == "builtin_method" || kind == "closure_call" ||
       kind == "super_init" || kind == "super_call" ||
       kind == "brew" || kind == "group_brew" {
        if resolved.starts_with("std.atomic.") {
            return "mutate"
        }
        return "allocate,panic,mutate"
    }
    if kind == "index" || kind == "try" ||
       kind == "cast" {
        return "panic"
    }
    if kind == "weak_field" {
        // produces a retained reference, and two reads can differ when
        // the referent dies between them: never merged, never moved
        return "allocate,mutate"
    }
    return "none"
}
