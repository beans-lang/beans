package main

import std.encoding.json
import std.io

@json.naming(value: json.Naming.camel_case)
struct JsonDirectEdges {
    pub s8_min: i8
    pub s16_min: i16
    pub s32_min: i32
    pub s64_min: int
    pub u8_max: u8
    pub u16_max: u16
    pub u32_max: u32
    pub u64_max: u64
    pub flags: List<bool>
    pub signed8: List<i8>
    pub signed16: List<i16>
    pub signed32: List<i32>
    pub unsigned8: List<u8>
    pub unsigned16: List<u16>
    pub unsigned32: List<u32>
    pub unsigned64: List<u64>
    pub words: List<string>
    pub maybe_values: Option<List<i16>>
    pub no_values: Option<List<u32>>
    pub nul_text: string

    @json.name(value: "naïve")
    pub renamed: string
}

struct JsonFloatListEdges {
    pub float32: List<f32>
    pub float64: List<float>
}

fn text_with_nul() -> string {
    let bytes: Bytes = new Bytes(0)
    bytes.push(65)
    bytes.push(0)
    bytes.push(66)
    return bytes.to_string()
}

fn main() {
    let nul: string = text_with_nul()
    let value: JsonDirectEdges = JsonDirectEdges {
        s8_min: -128,
        s16_min: -32768,
        s32_min: -2147483648,
        s64_min: -9223372036854775807 - 1,
        u8_max: 255,
        u16_max: 65535,
        u32_max: 4294967295,
        u64_max: 18446744073709551615,
        flags: [true, false, true],
        signed8: [-128, -1, 0, 127],
        signed16: [-32768, -2, 0, 300, 32767],
        signed32: [-2147483648, -3, 0, 2147483647],
        unsigned8: [0, 1, 255],
        unsigned16: [0, 300, 65535],
        unsigned32: [0, 70000, 4294967295],
        unsigned64: [0, 9223372036854775808, 18446744073709551615],
        words: ["", "café", nul],
        maybe_values: some([-2, 300]),
        no_values: none,
        nul_text: nul,
        renamed: "kept",
    }
    io.println(json.encode(value).expect("encode JSON edge values"))
    let floats: JsonFloatListEdges = JsonFloatListEdges {
        float32: [1.5, -2.25, 0.125],
        float64: [1.5, -2.25, 0.125],
    }
    io.println(json.encode(floats).expect("encode JSON float lists"))
}
