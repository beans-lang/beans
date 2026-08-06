// Transcribed from compiler/bootstrap/builtins.cpp, which stays the source of truth:
// one row per registry builtin the native backend can call — parameter
// kinds, the return shape, the C runtime symbol, and whether the C side
// takes a trailing (line, col) pair because it may panic. If the registry
// changes, this table must change with it; the differential runs in
// test/self_host.sh are what catch the drift.

pub class RuntimeBuiltin {
    pub parameters: List<string>
    pub result: string
    pub symbol: string
    pub panics: bool

    pub fn init(parameters: List<string>, result: string,
                symbol: string, panics: bool) {
        self.parameters = []
        for parameter: string in parameters {
            self.parameters.push(parameter)
        }
        self.result = result
        self.symbol = symbol
        self.panics = panics
    }
}

pub fn runtime_builtin_method(key: string) -> Option<RuntimeBuiltin> {
    if key == "string.len" {
        return some(new RuntimeBuiltin(
            [],
            "i64", "beans_str_len", false))
    }
    if key == "string.is_empty" {
        return some(new RuntimeBuiltin(
            [],
            "bool", "beans_str_is_empty", false))
    }
    if key == "string.last" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "str", "beans_str_last", false))
    }
    if key == "string.first" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "str", "beans_str_first", false))
    }
    if key == "string.contains" {
        return some(new RuntimeBuiltin(
            ["str"],
            "bool", "beans_str_contains", false))
    }
    if key == "string.starts_with" {
        return some(new RuntimeBuiltin(
            ["str"],
            "bool", "beans_str_starts_with", false))
    }
    if key == "string.ends_with" {
        return some(new RuntimeBuiltin(
            ["str"],
            "bool", "beans_str_ends_with", false))
    }
    if key == "string.find" {
        return some(new RuntimeBuiltin(
            ["str"],
            "opt_i64", "beans_str_find", false))
    }
    if key == "string.rfind" {
        return some(new RuntimeBuiltin(
            ["str"],
            "opt_i64", "beans_str_rfind", false))
    }
    if key == "string.slice" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "str", "beans_str_slice", true))
    }
    if key == "string.byte_at" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_str_byte_at", true))
    }
    if key == "string.find_byte" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "i64", "beans_str_find_byte", true))
    }
    if key == "string.range_equals" {
        return some(new RuntimeBuiltin(
            ["i64", "i64", "str"],
            "bool", "beans_str_range_equals", true))
    }
    if key == "string.parse_int_range_or" {
        return some(new RuntimeBuiltin(
            ["i64", "i64", "i64"],
            "i64", "beans_str_parse_int_range_or", true))
    }
    if key == "string.trim" {
        return some(new RuntimeBuiltin(
            [],
            "str", "beans_str_trim", false))
    }
    if key == "string.trim_start" {
        return some(new RuntimeBuiltin(
            [],
            "str", "beans_str_trim_start", false))
    }
    if key == "string.trim_end" {
        return some(new RuntimeBuiltin(
            [],
            "str", "beans_str_trim_end", false))
    }
    if key == "string.to_upper" {
        return some(new RuntimeBuiltin(
            [],
            "str", "beans_str_to_upper", false))
    }
    if key == "string.to_lower" {
        return some(new RuntimeBuiltin(
            [],
            "str", "beans_str_to_lower", false))
    }
    if key == "string.replace" {
        return some(new RuntimeBuiltin(
            ["str", "str"],
            "str", "beans_str_replace", false))
    }
    if key == "string.repeat" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "str", "beans_str_repeat", true))
    }
    if key == "string.split" {
        return some(new RuntimeBuiltin(
            ["str"],
            "list_str", "beans_str_split", false))
    }
    if key == "string.lines" {
        return some(new RuntimeBuiltin(
            [],
            "list_str", "beans_str_lines", false))
    }
    if key == "string.to_int" {
        return some(new RuntimeBuiltin(
            [],
            "res_i64", "beans_str_to_int", false))
    }
    if key == "string.to_float" {
        return some(new RuntimeBuiltin(
            [],
            "res_f64", "beans_str_to_float", false))
    }
    if key == "string.to_decimal" {
        return some(new RuntimeBuiltin(
            [],
            "res_dec", "beans_str_to_decimal", false))
    }
    if key == "string.chars" {
        return some(new RuntimeBuiltin(
            [],
            "list_str", "beans_str_chars", false))
    }
    if key == "string.count_chars" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "i64", "beans_str_count_chars", true))
    }
    if key == "Bytes.len" {
        return some(new RuntimeBuiltin(
            [],
            "i64", "beans_bytes_len", false))
    }
    if key == "Bytes.reserve" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "self_recv", "beans_bytes_reserve", true))
    }
    if key == "Bytes.resize" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "self_recv", "beans_bytes_resize", true))
    }
    if key == "Bytes.fill" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "self_recv", "beans_bytes_fill", false))
    }
    if key == "Bytes.get" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_bytes_get", true))
    }
    if key == "Bytes.set" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "self_recv", "beans_bytes_set", true))
    }
    if key == "Bytes.push" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "self_recv", "beans_bytes_push", false))
    }
    if key == "Bytes.get_u8" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_bytes_get_u8", true))
    }
    if key == "Bytes.get_u16" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_bytes_get_u16", true))
    }
    if key == "Bytes.get_u32" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_bytes_get_u32", true))
    }
    if key == "Bytes.get_u64" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_bytes_get_u64", true))
    }
    if key == "Bytes.get_i64" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_bytes_get_i64", true))
    }
    if key == "Bytes.put_u8" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "self_recv", "beans_bytes_put_u8", true))
    }
    if key == "Bytes.put_u16" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "self_recv", "beans_bytes_put_u16", true))
    }
    if key == "Bytes.put_u32" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "self_recv", "beans_bytes_put_u32", true))
    }
    if key == "Bytes.put_u64" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "self_recv", "beans_bytes_put_u64", true))
    }
    if key == "Bytes.put_i64" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "self_recv", "beans_bytes_put_i64", true))
    }
    if key == "Bytes.slice" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "bytes", "beans_bytes_slice", true))
    }
    if key == "Bytes.copy_from" {
        return some(new RuntimeBuiltin(
            ["bytes", "i64"],
            "self_recv", "beans_bytes_copy_from", true))
    }
    if key == "Bytes.append" {
        return some(new RuntimeBuiltin(
            ["bytes"],
            "self_recv", "beans_bytes_append", false))
    }
    if key == "Bytes.append_str" {
        return some(new RuntimeBuiltin(
            ["str"],
            "self_recv", "beans_bytes_append_str", false))
    }
    if key == "Bytes.append_i64" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "self_recv", "beans_bytes_append_i64", false))
    }
    if key == "Bytes.append_range" {
        return some(new RuntimeBuiltin(
            ["bytes", "i64", "i64"],
            "self_recv", "beans_bytes_append_range", true))
    }
    if key == "Bytes.to_string" {
        return some(new RuntimeBuiltin(
            [],
            "str", "beans_bytes_to_string", false))
    }
    if key == "Bytes.to_string_full" {
        return some(new RuntimeBuiltin(
            [],
            "str", "beans_bytes_to_string_full", false))
    }
    if key == "Bytes.append_varint" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "self_recv", "beans_bytes_append_varint", false))
    }
    if key == "Bytes.get_varint" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_bytes_get_varint", true))
    }
    if key == "Bytes.crc32" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "i64", "beans_bytes_crc32", true))
    }
    if key == "File.read_at" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "res_bytes", "beans_file_read_at", false))
    }
    if key == "File.write_at" {
        return some(new RuntimeBuiltin(
            ["i64", "bytes"],
            "res_i64", "beans_file_write_at", false))
    }
    if key == "File.read" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "res_bytes", "beans_file_read", false))
    }
    if key == "File.write" {
        return some(new RuntimeBuiltin(
            ["bytes"],
            "res_i64", "beans_file_write", false))
    }
    if key == "File.seek" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_file_seek", true))
    }
    if key == "File.seek_end" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_file_seek_end", true))
    }
    if key == "File.tell" {
        return some(new RuntimeBuiltin(
            [],
            "i64", "beans_file_tell", true))
    }
    if key == "File.size" {
        return some(new RuntimeBuiltin(
            [],
            "res_i64", "beans_file_size", false))
    }
    if key == "File.truncate" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "res_bool", "beans_file_truncate", false))
    }
    if key == "File.sync" {
        return some(new RuntimeBuiltin(
            [],
            "res_bool", "beans_file_sync", false))
    }
    if key == "File.close" {
        return some(new RuntimeBuiltin(
            [],
            "res_bool", "beans_file_close", false))
    }
    if key == "File.lock" {
        return some(new RuntimeBuiltin(
            [],
            "res_bool", "beans_file_lock", false))
    }
    if key == "File.try_lock" {
        return some(new RuntimeBuiltin(
            [],
            "res_bool", "beans_file_try_lock", false))
    }
    if key == "File.unlock" {
        return some(new RuntimeBuiltin(
            [],
            "res_bool", "beans_file_unlock", false))
    }
    if key == "MMap.len" {
        return some(new RuntimeBuiltin(
            [],
            "i64", "beans_mmap_len", false))
    }
    if key == "MMap.get_u8" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_mmap_get_u8", true))
    }
    if key == "MMap.get_u16" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_mmap_get_u16", true))
    }
    if key == "MMap.get_u32" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_mmap_get_u32", true))
    }
    if key == "MMap.get_u64" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_mmap_get_u64", true))
    }
    if key == "MMap.get_i64" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_mmap_get_i64", true))
    }
    if key == "MMap.put_u8" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "self_recv", "beans_mmap_put_u8", true))
    }
    if key == "MMap.put_u16" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "self_recv", "beans_mmap_put_u16", true))
    }
    if key == "MMap.put_u32" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "self_recv", "beans_mmap_put_u32", true))
    }
    if key == "MMap.put_u64" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "self_recv", "beans_mmap_put_u64", true))
    }
    if key == "MMap.put_i64" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "self_recv", "beans_mmap_put_i64", true))
    }
    if key == "MMap.read" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "bytes", "beans_mmap_read", true))
    }
    if key == "MMap.write" {
        return some(new RuntimeBuiltin(
            ["i64", "bytes"],
            "self_recv", "beans_mmap_write", true))
    }
    if key == "MMap.flush" {
        return some(new RuntimeBuiltin(
            [],
            "res_bool", "beans_mmap_flush", false))
    }
    if key == "MMap.flush_range" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "res_bool", "beans_mmap_flush_range", false))
    }
    if key == "MMap.resize" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "res_bool", "beans_mmap_resize", false))
    }
    if key == "MMap.close" {
        return some(new RuntimeBuiltin(
            [],
            "res_bool", "beans_mmap_close", false))
    }
    return none
}

pub fn runtime_builtin_static(key: string) -> Option<RuntimeBuiltin> {
    if key == "Bytes.from" {
        return some(new RuntimeBuiltin(
            ["str"],
            "bytes", "beans_bytes_from", false))
    }
    if key == "Bytes.varint_size" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_bytes_varint_size", false))
    }
    if key == "File.exists" {
        return some(new RuntimeBuiltin(
            ["str"],
            "bool", "beans_file_exists", false))
    }
    if key == "File.size" {
        return some(new RuntimeBuiltin(
            ["str"],
            "res_i64", "beans_file_size_p", false))
    }
    if key == "File.remove" {
        return some(new RuntimeBuiltin(
            ["str"],
            "res_bool", "beans_file_remove", false))
    }
    if key == "File.rename" {
        return some(new RuntimeBuiltin(
            ["str", "str"],
            "res_bool", "beans_file_rename", false))
    }
    if key == "File.open" {
        return some(new RuntimeBuiltin(
            ["str", "str"],
            "res_file", "beans_file_open", false))
    }
    if key == "Dir.make" {
        return some(new RuntimeBuiltin(
            ["str"],
            "res_bool", "beans_dir_make", false))
    }
    if key == "Dir.make_all" {
        return some(new RuntimeBuiltin(
            ["str"],
            "res_bool", "beans_dir_make_all", false))
    }
    if key == "Dir.list" {
        return some(new RuntimeBuiltin(
            ["str"],
            "res_list_str", "beans_dir_list", false))
    }
    if key == "Dir.remove" {
        return some(new RuntimeBuiltin(
            ["str"],
            "res_bool", "beans_dir_remove", false))
    }
    if key == "Dir.remove_all" {
        return some(new RuntimeBuiltin(
            ["str"],
            "res_bool", "beans_dir_remove_all", false))
    }
    if key == "Dir.exists" {
        return some(new RuntimeBuiltin(
            ["str"],
            "bool", "beans_dir_exists", false))
    }
    if key == "Dir.temp" {
        return some(new RuntimeBuiltin(
            [],
            "str", "beans_dir_temp", false))
    }
    if key == "Dir.sync" {
        return some(new RuntimeBuiltin(
            ["str"],
            "res_bool", "beans_dir_sync", false))
    }
    if key == "Dir.walk" {
        return some(new RuntimeBuiltin(
            ["str"],
            "res_list_str", "beans_dir_walk", false))
    }
    if key == "MMap.open" {
        return some(new RuntimeBuiltin(
            ["str", "bool"],
            "res_mmap", "beans_mmap_open", false))
    }
    if key == "MMap.open_shared" {
        return some(new RuntimeBuiltin(
            ["str", "i64", "bool"],
            "res_mmap", "beans_shm_open", false))
    }
    if key == "MMap.unlink_shared" {
        return some(new RuntimeBuiltin(
            ["str"],
            "res_bool", "beans_shm_unlink", false))
    }
    return none
}

pub fn runtime_builtin_fn(key: string) -> Option<RuntimeBuiltin> {
    if key == "std.c.errno" {
        return some(new RuntimeBuiltin(
            [],
            "i32", "beans_c_errno", false))
    }
    if key == "std.c.set_errno" {
        return some(new RuntimeBuiltin(
            ["i32"],
            "unit", "beans_c_set_errno", false))
    }
    if key == "std.os.args" {
        return some(new RuntimeBuiltin(
            [],
            "list_str", "beans_os_args", false))
    }
    if key == "std.os.env" {
        return some(new RuntimeBuiltin(
            ["str"],
            "opt_str", "beans_os_env", false))
    }
    if key == "std.os.exit" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "unit", "beans_os_exit", false))
    }
    if key == "std.os.now_ms" {
        return some(new RuntimeBuiltin(
            [],
            "i64", "beans_os_now_ms", false))
    }
    if key == "std.os.ticks_ms" {
        return some(new RuntimeBuiltin(
            [],
            "i64", "beans_os_ticks_ms", false))
    }
    if key == "std.os.sleep_ms" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "unit", "beans_os_sleep_ms", false))
    }
    if key == "std.io.read_line" {
        return some(new RuntimeBuiltin(
            [],
            "opt_str", "beans_io_read_line", false))
    }
    if key == "std.io.read_all" {
        return some(new RuntimeBuiltin(
            [],
            "str", "beans_io_read_all", false))
    }
    if key == "std.proc.run" {
        return some(new RuntimeBuiltin(
            ["bytes", "bytes", "str", "bytes", "i64"],
            "res_bytes", "beans_proc_run", false))
    }
    if key == "std.proc.start" {
        return some(new RuntimeBuiltin(
            ["bytes", "bytes", "str"],
            "res_bytes", "beans_proc_start", false))
    }
    if key == "std.proc.status" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "res_bytes", "beans_proc_status", false))
    }
    if key == "std.proc.signal" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "res_bool", "beans_proc_signal", false))
    }
    if key == "std.proc.write" {
        return some(new RuntimeBuiltin(
            ["i64", "bytes", "i64"],
            "res_i64", "beans_proc_write", false))
    }
    if key == "std.proc.read" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "res_bytes", "beans_proc_read", false))
    }
    if key == "std.proc.close" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "res_bool", "beans_proc_close", false))
    }
    if key == "std.sock.listen" {
        return some(new RuntimeBuiltin(
            ["str", "i64", "i64"],
            "res_i64", "beans_net_listen", false))
    }
    if key == "std.sock.connect" {
        return some(new RuntimeBuiltin(
            ["str", "i64", "i64"],
            "res_i64", "beans_net_connect", false))
    }
    if key == "std.sock.udp_bind" {
        return some(new RuntimeBuiltin(
            ["str", "i64"],
            "res_i64", "beans_net_udp_bind", false))
    }
    if key == "std.sock.accept" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "res_i64", "beans_net_accept", false))
    }
    if key == "std.sock.send" {
        return some(new RuntimeBuiltin(
            ["i64", "bytes", "i64"],
            "res_i64", "beans_net_send", false))
    }
    if key == "std.sock.recv" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "res_bytes", "beans_net_recv", false))
    }
    if key == "std.sock.send_to" {
        return some(new RuntimeBuiltin(
            ["i64", "bytes", "str", "i64"],
            "res_i64", "beans_net_send_to", false))
    }
    if key == "std.sock.recv_from" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "res_bytes", "beans_net_recv_from", false))
    }
    if key == "std.sock.address" {
        return some(new RuntimeBuiltin(
            ["i64", "bool"],
            "res_bytes", "beans_net_address", false))
    }
    if key == "std.sock.shutdown" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "res_bool", "beans_net_shutdown", false))
    }
    if key == "std.sock.set_timeouts" {
        return some(new RuntimeBuiltin(
            ["i64", "i64", "i64"],
            "res_bool", "beans_net_set_timeouts", false))
    }
    if key == "std.sock.set_nonblocking" {
        return some(new RuntimeBuiltin(
            ["i64", "bool"],
            "res_bool", "beans_net_set_nonblocking", false))
    }
    if key == "std.sock.close" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "res_bool", "beans_net_close", false))
    }
    if key == "std.sock.resolve" {
        return some(new RuntimeBuiltin(
            ["str", "i64"],
            "res_list_str", "beans_net_resolve", false))
    }
    if key == "std.sig.watch" {
        return some(new RuntimeBuiltin(
            ["bytes"],
            "res_i64", "beans_signal_watch", false))
    }
    if key == "std.sig.pending" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "res_bytes", "beans_signal_take", false))
    }
    if key == "std.sig.close" {
        return some(new RuntimeBuiltin(
            ["i64", "bytes"],
            "res_bool", "beans_signal_close", false))
    }
    if key == "std.sig.raise" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "res_bool", "beans_signal_raise", false))
    }
    if key == "std.sig.number" {
        return some(new RuntimeBuiltin(
            ["str"],
            "res_i64", "beans_signal_number", false))
    }
    if key == "std.sig.name" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "res_str", "beans_signal_name", false))
    }
    if key == "std.dl.open" {
        return some(new RuntimeBuiltin(
            ["str"],
            "res_i64", "beans_dl_open", false))
    }
    if key == "std.dl.symbol" {
        return some(new RuntimeBuiltin(
            ["i64", "str"],
            "res_i64", "beans_dl_symbol", false))
    }
    if key == "std.dl.global_symbol" {
        return some(new RuntimeBuiltin(
            ["str"],
            "res_i64", "beans_dl_global_symbol", false))
    }
    if key == "std.dl.close" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "res_bool", "beans_dl_close", false))
    }
    if key == "std.dl.call0" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_dl_call0", false))
    }
    if key == "std.dl.call1" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "i64", "beans_dl_call1", false))
    }
    if key == "std.dl.call2" {
        return some(new RuntimeBuiltin(
            ["i64", "i64", "i64"],
            "i64", "beans_dl_call2", false))
    }
    if key == "std.dl.call3" {
        return some(new RuntimeBuiltin(
            ["i64", "i64", "i64", "i64"],
            "i64", "beans_dl_call3", false))
    }
    if key == "std.dl.call_void0" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "unit", "beans_dl_call_void0", false))
    }
    if key == "std.dl.call_void1" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "unit", "beans_dl_call_void1", false))
    }
    if key == "std.dl.call_void2" {
        return some(new RuntimeBuiltin(
            ["i64", "i64", "i64"],
            "unit", "beans_dl_call_void2", false))
    }
    if key == "std.dl.call_void3" {
        return some(new RuntimeBuiltin(
            ["i64", "i64", "i64", "i64"],
            "unit", "beans_dl_call_void3", false))
    }
    if key == "std.dl.call_f64_1" {
        return some(new RuntimeBuiltin(
            ["i64", "f64"],
            "f64", "beans_dl_call_f64_1", false))
    }
    if key == "std.dl.call_f64_i32" {
        return some(new RuntimeBuiltin(
            ["i64", "f64", "i64"],
            "f64", "beans_dl_call_f64_i32", false))
    }
    if key == "std.dl.call_f32_1" {
        return some(new RuntimeBuiltin(
            ["i64", "f64"],
            "f64", "beans_dl_call_f32_1", false))
    }
    if key == "std.dl.call_f32_i32" {
        return some(new RuntimeBuiltin(
            ["i64", "f64", "i64"],
            "f64", "beans_dl_call_f32_i32", false))
    }
    if key == "std.ready.open" {
        return some(new RuntimeBuiltin(
            [],
            "res_bytes", "beans_poll_open", false))
    }
    if key == "std.ready.add" {
        return some(new RuntimeBuiltin(
            ["i64", "i64", "i64", "bool", "bool", "bool"],
            "res_bool", "beans_poll_add", false))
    }
    if key == "std.ready.remove" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "res_bool", "beans_poll_remove", false))
    }
    if key == "std.ready.wait" {
        return some(new RuntimeBuiltin(
            ["i64", "i64", "i64", "i64"],
            "res_bytes", "beans_poll_wait", false))
    }
    if key == "std.ready.wake" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "res_bool", "beans_poll_wake", false))
    }
    if key == "std.ready.close" {
        return some(new RuntimeBuiltin(
            ["i64", "i64", "i64"],
            "res_bool", "beans_poll_close", false))
    }
    if key == "std.ready.task_slot" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_task_slot", false))
    }
    if key == "std.ready.set_task_slot" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "i64", "beans_set_task_slot", false))
    }
    if key == "std.ready.park_note" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_reactor_note_park", false))
    }
    if key == "std.ready.park_bind" {
        return some(new RuntimeBuiltin(
            ["i64", "i64"],
            "i64", "beans_reactor_bind_park", false))
    }
    if key == "std.ready.park_forget" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_reactor_forget_park", false))
    }
    if key == "std.ready.park_stale" {
        return some(new RuntimeBuiltin(
            [],
            "i64", "beans_reactor_stale_park", false))
    }
    if key == "std.ready.park_dead" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "i64", "beans_reactor_park_dead", false))
    }
    if key == "std.ready.park_shutdown" {
        return some(new RuntimeBuiltin(
            [],
            "i64", "beans_reactor_shutdown_parks", false))
    }
    if key == "std.time.monotonic_nanos" {
        return some(new RuntimeBuiltin(
            [],
            "i64", "beans_time_monotonic_nanos", false))
    }
    if key == "std.time.wall_nanos" {
        return some(new RuntimeBuiltin(
            [],
            "i64", "beans_time_wall_nanos", false))
    }
    if key == "std.time.sleep_nanos" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "unit", "beans_time_sleep_nanos", false))
    }
    if key == "std.random.bytes" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "res_bytes", "beans_random_bytes", false))
    }
    if key == "std.random.u64" {
        return some(new RuntimeBuiltin(
            [],
            "res_i64", "beans_random_u64", false))
    }
    if key == "std.random.below" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "res_i64", "beans_random_below", false))
    }
    if key == "std.fmt.pad_left" {
        return some(new RuntimeBuiltin(
            ["str", "i64"],
            "str", "beans_fmt_pad_left", true))
    }
    if key == "std.fmt.pad_right" {
        return some(new RuntimeBuiltin(
            ["str", "i64"],
            "str", "beans_fmt_pad_right", true))
    }
    if key == "std.fmt.float" {
        return some(new RuntimeBuiltin(
            ["f64", "i64"],
            "str", "beans_fmt_float", false))
    }
    if key == "std.fmt.dec" {
        return some(new RuntimeBuiltin(
            ["dec", "i64"],
            "str", "beans_decv_fmt", false))
    }
    return none
}

pub fn runtime_builtin_constructor(key: string) -> Option<RuntimeBuiltin> {
    if key == "Bytes.init" {
        return some(new RuntimeBuiltin(
            ["i64"],
            "bytes", "beans_bytes_new", true))
    }
    return none
}
