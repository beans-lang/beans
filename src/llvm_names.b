package main

// The LLVM named type for a record. A canonical name carries the package's
// whole import path, so it goes through symbol_text: '/' and ':' are not
// legal in an LLVM identifier, and two same-named records in different
// packages must not collapse onto one type.
fn llvm_record_name(qualified: string) -> string {
    return "%bs.{symbol_text(qualified)}"
}

fn llvm_record_instance_name(type: HirType) -> string {
    if type.args.len() == 0 {
        return llvm_record_name(type.name)
    }
    return llvm_record_name(render_hir_type(type))
}

fn llvm_unquote(source: string) -> string {
    var start: int = 0
    var end: int = source.len()
    if source.len() >= 2 &&
       source.starts_with("\"") &&
       source.ends_with("\"") {
        start = 1
        end -= 1
    }
    var result: string = ""
    var index: int = start
    for index < end {
        let byte: int = source.byte_at(index)
        if byte != 92 || index + 1 >= end {
            result =
                "{result}{source.slice(index, index + 1)}"
            index += 1
            continue
        }
        let escaped: int = source.byte_at(index + 1)
        if escaped == 110 {
            result = "{result}\n"
        } else if escaped == 114 {
            result = "{result}\r"
        } else if escaped == 116 {
            result = "{result}\t"
        } else if escaped == 48 {
            result = "{result}\0"
        } else {
            result =
                "{result}{source.slice(index + 1, index + 2)}"
        }
        index += 2
    }
    return result
}

fn llvm_hex_digit(value: int) -> string {
    let digits: string = "0123456789ABCDEF"
    return digits.slice(value, value + 1)
}

fn llvm_escape_bytes(value: string) -> string {
    var result: string = ""
    for index: int in 0..value.len() {
        let byte: int = value.byte_at(index)
        if byte >= 32 && byte <= 126 &&
           byte != 34 && byte != 92 {
            result =
                "{result}{value.slice(index, index + 1)}"
        } else {
            result =
                "{result}\\{llvm_hex_digit(byte / 16)}{llvm_hex_digit(byte % 16)}"
        }
    }
    return result
}
