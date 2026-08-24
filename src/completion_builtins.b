package main

// Every method name the checker's own built-in table answers for. The list is
// only a set of names to probe: each one is confirmed against
// `builtin_method`, so a member that no longer type-checks can never be
// offered, and test/lsp_semantic.sh proves no name in the checker is missing
// here.
fn semantic_builtin_member_names() -> List<string> {
    return ["abs", "add", "add_and_get", "address", "all_true",
            "any_true", "append", "append_i64", "append_int_text",
            "append_range",
            "append_string", "append_uvarint", "as_ptr", "at",
            "atomic_compare_exchange", "atomic_fetch_add",
            "atomic_load", "atomic_store", "bit_and", "bit_not",
            "bit_or", "bit_xor", "byte_at", "call", "ceil",
            "chars",
            "clear",
            "clone", "close", "compare_exchange", "contains",
            "contains_key", "context", "copy_from", "count_chars",
            "crc32", "div", "downgrade", "element_align",
            "element_size", "ends_with", "eq", "exchange", "expect",
            "fetch_add", "fetch_and", "fetch_or", "fetch_sub",
            "fetch_xor", "fill", "fill_zero", "find", "find_byte",
            "floor",
            "first", "flush", "flush_range", "free", "function",
            "function_pointer",
            "ge", "get", "get_i64", "get_u16", "get_u32", "get_u64",
            "get_u8", "get_uvarint", "gt", "index_of", "insert",
            "is_empty", "is_expired", "is_nan", "is_none", "is_null",
            "is_ok",
            "is_some", "join", "join_async", "keys", "lane", "lane_count", "last",
            "le", "len", "lines", "load", "lock", "lt", "max",
            "min", "mul", "ne", "notify_all", "notify_one",
            "offset", "or", "parse_int_range_or", "pop", "product",
            "push", "put_i64", "put_u16", "put_u32", "put_u64",
            "put_u8", "range_equals", "read", "read_at", "read_text",
            "read_text_at",
            "read_volatile", "receive", "receive_async", "remove", "repeat",
            "replace", "reserve", "resize", "reverse", "rfind",
            "round", "seek", "seek_from_end", "select", "send", "send_async",
            "set", "shl", "shr", "size", "slice", "sort", "sort_by",
            "sort_by_key", "split", "starts_with", "store",
            "store_unaligned", "sub", "subslice", "sum", "sync",
            "tell", "to_decimal", "to_float", "to_int", "to_lower",
            "to_string", "to_string_until_nul", "to_upper", "trim",
            "trim_end", "trim_start", "truncate", "try_lock",
            "try_receive", "try_send",
            "unlock", "upgrade", "values", "wait", "wait_timeout",
            "with_lane", "with_lock", "write", "write_at", "write_text",
            "write_text_at",
            "write_volatile"]
}

fn semantic_render_builtin(receiver: HirType, name: string,
                           signature: BuiltinSignature) -> string {
    var parts: List<string> = []
    for parameter: HirType in signature.parameters {
        parts.push(sem_type_text(parameter, ""))
    }
    let effect: string =
        if name == "send_async" ||
           name == "receive_async" ||
           name == "join_async" {
            "async "
        } else { "" }
    var rendered: string =
        "{effect}fn {sem_type_text(receiver, "")}.{name}({parts.join(", ")})"
    if signature.result.name != "unit" {
        rendered =
            "{rendered} -> {sem_type_text(signature.result, "")}"
    }
    return rendered
}

// The closed built-in names owned by the language. SIMD names are shaped
// dynamically, so they are not useful as general suggestions.
fn semantic_builtin_type_names() -> List<string> {
    return ["unit", "bool", "string", "decimal", "int", "i8",
            "i16", "i32", "i64", "uint", "byte", "u8", "u16",
            "u32", "u64", "f32", "f64", "float", "Clone", "Eq",
            "Hash", "Order", "Send", "Sync", "RawPtr", "Slice",
            "List", "Map", "OrderedMap", "Option", "Result", "Box",
            "Arena", "Shared", "Weak", "Mutex", "Atomic", "Channel",
            "Thread", "Bytes", "File", "Dir", "MMap", "Error",
            "RawSlice", "AtomicInt", "MemoryOrder", "RoundingMode",
            "CpuFeature", "StoredCallback", "LocalStoredCallback",
            "CFunctionPtr", "Self"]
}

fn semantic_builtin_type_completions() -> List<SemanticCompletion> {
    var items: List<SemanticCompletion> = []
    for name: string in semantic_builtin_type_names() {
        let item: SemanticCompletion =
            new SemanticCompletion(
                name, "class", sem_builtin_type_id(name))
        item.detail = "builtin type {name}"
        items.push(item)
    }
    return move items
}

// The members of a built-in receiver, asked of the expression checker itself
// so the answer is exactly what would type-check.
fn semantic_builtin_members(
    snapshot: SemanticSnapshot,
    receiver: HirType) -> List<SemanticCompletion> {
    var items: List<SemanticCompletion> = []
    match snapshot.expressions {
        some(checker) => {
            for name: string in semantic_builtin_member_names() {
                match checker.builtin_method(receiver, name) {
                    some(signature) => {
                        let item: SemanticCompletion =
                            new SemanticCompletion(
                                name, "method",
                                sem_builtin_member_id(
                                    receiver.name, name))
                        item.detail =
                            semantic_render_builtin(
                                receiver, name, signature)
                        items.push(item)
                    }
                    none => {}
                }
            }
        }
        none => {}
    }
    return move items
}

fn semantic_builtin_static_names() -> List<string> {
    return ["from", "filled", "exists", "size", "open", "remove",
            "rename", "copy",
            "list", "walk", "create", "create_all", "remove_all",
            "sync", "temp_path", "uvarint_size", "open_shared_memory",
            "unlink_shared_memory", "fence", "infinity"]
}

fn semantic_builtin_selector_names(
    snapshot: SemanticSnapshot, owner: string) -> List<string> {
    if owner == "MemoryOrder" {
        return ["relaxed", "acquire", "release", "acq_rel", "seq_cst"]
    }
    if owner == "RoundingMode" {
        return ["half_even", "half_away", "toward_zero", "floor", "ceil"]
    }
    if owner == "CpuFeature" {
        match snapshot.expressions {
            some(checker) => {
                var names: List<string> = []
                for name: string in checker.program.target.known_features() {
                    names.push(name.replace(".", "_"))
                }
                return move names
            }
            none => {}
        }
    }
    return []
}

// Names are only candidates. The expression checker's own table confirms each
// one before completion offers it, so this cannot invent a callable function.
fn semantic_builtin_module_names(package_path: string) -> List<string> {
    if package_path == "std.io" {
        return ["println", "eprintln", "print", "eprint",
                "read_line", "read_all"]
    }
    if package_path == "std.c" { return ["errno", "set_errno"] }
    if package_path == "std.os" { return ["args", "env", "exit"] }
    if package_path == "std.target" {
        return ["triple", "arch", "os", "env", "object_format",
                "endian", "pointer_bits", "pointer_size", "stack_align",
                "max_simd_bits"]
    }
    if package_path == "std.random" { return ["bytes", "u64", "below"] }
    if package_path == "std.time" {
        return ["monotonic_nanos", "wall_nanos", "monotonic_millis",
                "wall_millis", "sleep_nanos", "sleep_millis"]
    }
    if package_path == "std.fmt" {
        return ["pad_left", "pad_right", "float", "decimal"]
    }
    if package_path == "std.asm" { return ["value", "run"] }
    if package_path == "std.intrinsic" {
        return ["popcount", "leading_zeros", "trailing_zeros", "bswap16",
                "bswap32", "bswap64", "rotate_left", "rotate_right",
                "crc32c", "sqrt", "sqrt32", "fma", "fma32", "prefetch",
                "spin_hint"]
    }
    if package_path == "std.cpu" { return ["has", "has_name"] }
    if package_path == "std.proc" {
        return ["run", "start", "status", "signal", "close", "write",
                "write_text", "read", "read_to_end"]
    }
    if package_path == "std.sock" {
        return ["listen", "connect", "udp_bind", "accept", "send", "recv",
                "send_text", "recv_exact", "recv_to_end", "recv_from",
                "send_to", "address", "shutdown",
                "set_timeouts", "set_nonblocking", "close", "resolve"]
    }
    if package_path == "std.sig" {
        return ["watch", "pending", "close", "raise", "number", "name"]
    }
    if package_path == "std.dl" {
        return ["open", "symbol", "global_symbol", "close", "call0", "call1",
                "call2", "call3", "call_void0", "call_void1", "call_void2",
                "call_void3", "call_f64_1", "call_f64_i32", "call_f32_1",
                "call_f32_i32"]
    }
    if package_path == "std.ready" {
        return ["open", "add", "remove", "wait", "wait_into", "wake", "close",
                "task_slot", "set_task_slot", "park_note", "park_arm",
                "park_state", "park_finish", "park_release", "park_mark_ready", "park_stale",
                "park_shutdown"]
    }
    return []
}

fn semantic_builtin_module_completions(
    snapshot: SemanticSnapshot,
    package_path: string) -> List<SemanticCompletion> {
    var items: List<SemanticCompletion> = []
    match snapshot.expressions {
        some(checker) => {
            for name: string in
                semantic_builtin_module_names(package_path) {
                match checker.builtin_module(package_path, name) {
                    some(signature) => {
                        let item: SemanticCompletion =
                            new SemanticCompletion(
                                name, "function",
                                "builtin_module:{package_path}.{name}")
                        item.detail =
                            semantic_render_builtin(
                                new HirType(package_path), name, signature)
                        items.push(item)
                    }
                    none => {}
                }
            }
        }
        none => {}
    }
    // The thread entry points are generic over the closure result and have
    // their own checker path, so they cannot be represented by
    // BuiltinSignature.
    if package_path == "std.thread" {
        let spawn: SemanticCompletion =
            new SemanticCompletion(
                "spawn", "function", "builtin_module:std.thread.spawn")
        spawn.detail = "fn std.thread.spawn(send fn() -> T) -> Thread<T>"
        items.push(spawn)
        let spawn_async: SemanticCompletion =
            new SemanticCompletion(
                "spawn_async", "function",
                "builtin_module:std.thread.spawn_async")
        spawn_async.detail =
            "fn std.thread.spawn_async(send async fn() -> T) -> Thread<T>"
        items.push(spawn_async)
    }
    return move items
}
