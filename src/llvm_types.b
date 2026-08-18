package main

fn llvm_type(type: HirType) -> string {
    let name: string = canonical_hir_name(type.name)
    if name == "unit" { return "void" }
    match simd_description(name) {
        some(simd) => {
            let element: string =
                llvm_type(simd.element)
            if element == "" || element == "void" {
                return ""
            }
            return "<{simd.lanes} x {element}>"
        }
        none => {}
    }
    // a fixed array is an inline [N x T] value; reference elements
    // stay refused until the ARC walker learns array strides
    if name == "array" && type.args.len() == 1 &&
       type.array_length >= 0 {
        if llvm_type_is_reference(type.args[0]) {
            return ""
        }
        let element: string = llvm_type(type.args[0])
        if element == "" || element == "void" {
            return ""
        }
        return "[{type.array_length} x {element}]"
    }
    if name == "Error" || name == "Bytes" ||
       name == "AtomicInt" ||
       name == "File" || name == "MMap" {
        return "ptr"
    }
    // unmanaged: an address the ARC discipline never touches
    if (name == "RawPtr" || name == "CFunctionPtr" ||
        name == "StoredCallback") &&
       type.args.len() == 1 {
        return "ptr"
    }
    if name == "Slice" && type.args.len() == 1 &&
       llvm_type(type.args[0]) != "" &&
       llvm_type(type.args[0]) != "void" {
        return "\{ptr, i64\}"
    }
    // refcounted runtime handles; their operations arrive separately
    if (name == "Mutex" || name == "Channel" ||
        name == "Thread" || name == "Shared" ||
        name == "Weak" || name == "Atomic" ||
        name == "Arena" || name == "Box") &&
       type.args.len() == 1 {
        return "ptr"
    }
    // a closure box: {fnptr, capture cells...}, refcounted
    if name == "fn" { return "ptr" }
    if name == "bool" { return "i1" }
    if name == "i8" || name == "u8" { return "i8" }
    if name == "i16" || name == "u16" { return "i16" }
    if name == "i32" || name == "u32" { return "i32" }
    if name == "int" || name == "u64" { return "i64" }
    if name == "f32" { return "float" }
    if name == "float" { return "double" }
    // The explicit tail matches runtime BDec's fixed 32-byte C layout even on
    // targets where LLVM naturally gives {i128,i64} only 24 bytes.
    if name == "decimal" { return "\{ i128, i64, i64 \}" }
    if name == "string" { return "ptr" }
    if name == "List" && type.args.len() == 1 &&
       llvm_type(type.args[0]) != "" &&
       llvm_type(type.args[0]) != "void" {
        return "ptr"
    }
    if (name == "Map" || name == "OrderedMap") &&
       type.args.len() == 2 &&
       llvm_map_key_kind(type.args[0]) >= 0 &&
       llvm_type(type.args[1]) != "" &&
       llvm_type(type.args[1]) != "void" {
        return "ptr"
    }
    if name == "Option" && type.args.len() == 1 {
        let element: string = llvm_type(type.args[0])
        if element == "" || element == "void" {
            return ""
        }
        if llvm_type_is_reference(type.args[0]) {
            return "ptr"
        }
        return "\{ i1, {element} \}"
    }
    return ""
}

fn llvm_type_supported(type: HirType) -> bool {
    return llvm_type(type) != ""
}

fn llvm_type_is_integer(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    return name == "bool" || name == "i8" ||
           name == "u8" || name == "i16" ||
           name == "u16" || name == "i32" ||
           name == "u32" || name == "int" ||
           name == "u64"
}

fn llvm_type_is_unsigned(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    return name == "u8" || name == "u16" ||
           name == "u32" || name == "u64"
}

fn llvm_type_is_float(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    return name == "f32" || name == "float"
}

fn llvm_type_is_map(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    return (name == "Map" ||
            name == "OrderedMap") &&
           type.args.len() == 2
}

fn llvm_map_key_kind(type: HirType) -> int {
    if llvm_type_is_integer(type) { return 0 }
    if canonical_hir_name(type.name) == "string" {
        return 2
    }
    return -1
}

fn llvm_type_is_reference(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    if name == "string" || name == "List" ||
       name == "Map" || name == "OrderedMap" ||
       name == "Error" || name == "AtomicInt" ||
       name == "Bytes" || name == "File" ||
       name == "MMap" || name == "fn" {
        return true
    }
    if (name == "Mutex" || name == "Channel" ||
        name == "Thread" || name == "Shared" ||
        name == "Weak" || name == "Atomic" ||
        name == "Arena" || name == "Box") &&
       type.args.len() == 1 {
        return true
    }
    if name == "Result" &&
       type.args.len() >= 1 &&
       type.args.len() <= 2 {
        return true
    }
    return name == "Option" &&
           type.args.len() == 1 &&
           llvm_type_is_reference(type.args[0])
}

fn llvm_integer_bits(type: HirType) -> int {
    let name: string = canonical_hir_name(type.name)
    if name == "bool" { return 1 }
    if name == "i8" || name == "u8" { return 8 }
    if name == "i16" || name == "u16" { return 16 }
    if name == "i32" || name == "u32" { return 32 }
    if name == "int" || name == "u64" { return 64 }
    return 0
}

fn llvm_signed_min(type: HirType) -> string {
    let bits: int = llvm_integer_bits(type)
    if bits == 8 { return "-128" }
    if bits == 16 { return "-32768" }
    if bits == 32 { return "-2147483648" }
    if bits == 64 { return "-9223372036854775808" }
    return "0"
}
