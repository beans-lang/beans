package main

fn tree_float_bits(value: float, bits: int) -> u64 {
    unsafe {
        if bits == 32 {
            let number: RawPtr<f32> =
                RawPtr.alloc(1)
            number.write(value as f32)
            let raw: RawPtr<u32> =
                RawPtr.from_address(number.address())
            let result: u64 = raw.read() as u64
            number.free()
            return result
        }
        let number: RawPtr<f64> =
            RawPtr.alloc(1)
        number.write(value)
        let raw: RawPtr<u64> =
            RawPtr.from_address(number.address())
        let result: u64 = raw.read()
        number.free()
        return result
    }
}

fn tree_float_from_bits(value: u64,
                        bits: int) -> float {
    unsafe {
        if bits == 32 {
            let raw: RawPtr<u32> =
                RawPtr.alloc(1)
            raw.write(value as u32)
            let number: RawPtr<f32> =
                RawPtr.from_address(raw.address())
            let result: float =
                number.read() as float
            raw.free()
            return result
        }
        let raw: RawPtr<u64> =
            RawPtr.alloc(1)
        raw.write(value)
        let number: RawPtr<f64> =
            RawPtr.from_address(raw.address())
        let result: float = number.read()
        raw.free()
        return result
    }
}

fn tree_integer_bits(name: string) -> int {
    let clean: string = canonical_hir_name(name)
    if clean == "i8" || clean == "u8" {
        return 8
    }
    if clean == "i16" || clean == "u16" {
        return 16
    }
    if clean == "i32" || clean == "u32" {
        return 32
    }
    return 64
}

fn tree_integer_unsigned(name: string) -> bool {
    let clean: string = canonical_hir_name(name)
    return clean == "u8" || clean == "u16" ||
           clean == "u32" || clean == "u64"
}

// A float with no value in the integer type it is cast to saturates at that
// type's own bounds, and NaN is zero (spec/SYNTAX.md, "Number rules"). The
// bounds are tested before the host conversion, so the conversion that does
// run is always in range — the native backend spells the same rule with
// llvm.fptosi.sat / llvm.fptoui.sat, and both answer the same number.
//
// Each guard is exact in a double. The narrow limits are integers a double
// holds exactly; int.max and u64.max are not, so the guards there are 2^63 and
// 2^64, the first doubles above them.
fn tree_float_to_signed(value: float,
                        bits: int) -> int {
    if value != value { return 0 }
    if bits == 8 {
        if value >= 127.0 { return 127 }
        if value <= -128.0 { return -128 }
    } else if bits == 16 {
        if value >= 32767.0 { return 32767 }
        if value <= -32768.0 { return -32768 }
    } else if bits == 32 {
        if value >= 2147483647.0 {
            return 2147483647
        }
        if value <= -2147483648.0 {
            return -2147483648
        }
    } else {
        if value >= 9223372036854775808.0 {
            return 9223372036854775807
        }
        if value <= -9223372036854775808.0 {
            return -9223372036854775808
        }
    }
    return value as int
}

fn tree_float_to_unsigned(value: float,
                          bits: int) -> u64 {
    if value != value { return 0 }
    if value <= 0.0 { return 0 }
    if bits == 8 {
        if value >= 255.0 { return 255 }
    } else if bits == 16 {
        if value >= 65535.0 { return 65535 }
    } else if bits == 32 {
        if value >= 4294967295.0 {
            return 4294967295
        }
    } else {
        if value >= 18446744073709551616.0 {
            return 18446744073709551615
        }
    }
    return value as u64
}

fn tree_mask_unsigned(value: u64,
                      bits: int) -> u64 {
    if bits >= 64 { return value }
    return value & (((1 as u64) << (bits as u64)) - 1)
}

fn tree_signed_from_bits(value: u64,
                         bits: int) -> int {
    let narrowed: u64 =
        tree_mask_unsigned(value, bits)
    if bits >= 64 {
        if narrowed <=
           (9223372036854775807 as u64) {
            return narrowed as int
        }
        return -1 - ((~narrowed) as int)
    }
    let sign: u64 =
        (1 as u64) << ((bits - 1) as u64)
    if (narrowed & sign) != 0 {
        let mask: u64 =
            ((1 as u64) << (bits as u64)) - 1
        let extended: u64 =
            narrowed | ~mask
        return -1 - ((~extended) as int)
    }
    return narrowed as int
}

fn tree_parse_unsigned(source: string) -> u64 {
    let clean: string = source.replace("_", "")
    var base: u64 = 10
    var index: int = 0
    if clean.starts_with("0x") ||
       clean.starts_with("0X") {
        base = 16
        index = 2
    } else if clean.starts_with("0b") ||
              clean.starts_with("0B") {
        base = 2
        index = 2
    }
    var value: u64 = 0
    for index < clean.len() {
        let byte: int = clean.byte_at(index)
        var digit: u64 = 0
        if byte >= 48 && byte <= 57 {
            digit = (byte - 48) as u64
        } else if byte >= 97 && byte <= 102 {
            digit = (byte - 87) as u64
        } else if byte >= 65 && byte <= 70 {
            digit = (byte - 55) as u64
        }
        value = value * base + digit
        index += 1
    }
    return value
}

fn tree_parse_int(source: string) -> int {
    let clean: string = source.replace("_", "")
    if clean.starts_with("0x") ||
       clean.starts_with("0X") ||
       clean.starts_with("0b") ||
       clean.starts_with("0B") {
        return tree_signed_from_bits(
            tree_parse_unsigned(clean), 64)
    }
    if clean.starts_with("-0x") ||
       clean.starts_with("-0X") ||
       clean.starts_with("-0b") ||
       clean.starts_with("-0B") {
        return tree_signed_from_bits(
            (0 as u64) -
                tree_parse_unsigned(
                    clean.slice(1, clean.len())),
            64)
    }
    match clean.to_int() {
        ok(value) => { return value }
        err(error) => {
            // The magnitude of int.min is one larger than int.max.
            // The checker only permits it below unary minus; parsing its
            // bits here lets that negation wrap to the one valid value.
            return tree_signed_from_bits(
                tree_parse_unsigned(clean), 64)
        }
    }
}

fn tree_crc32c_step(initial: int, input: int) -> int {
    var crc: u32 = initial as u32
    let value: u64 = input as u64
    let polynomial: u32 = 0x82f63b78
    for byte: int in 0..8 {
        crc = crc ^ (((value >> ((byte * 8) as u64)) &
                      (0xff as u64)) as u32)
        for bit: int in 0..8 {
            crc =
                (crc >> (1 as u32)) ^
                (polynomial &
                 ((0 as u32) - (crc & (1 as u32))))
        }
    }
    return crc as int
}

fn tree_simd_lanes(name: string) -> int {
    if !name.starts_with("Simd") {
        return 0
    }
    var index: int = 4
    var lanes: int = 0
    for index < name.len() {
        let byte: int = name.byte_at(index)
        if byte < 48 || byte > 57 { break }
        lanes = lanes * 10 + byte - 48
        index += 1
    }
    return lanes
}

fn tree_simd_element(name: string) -> string {
    var index: int = 4
    for index < name.len() {
        let byte: int = name.byte_at(index)
        if byte < 48 || byte > 57 { break }
        index += 1
    }
    return name.slice(index, name.len())
}
