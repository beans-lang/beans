package main

// What the C types are actually worth on the target being bound. Every one of
// these is asked of Clang rather than guessed, because the rules do not follow
// from the pointer width: `long` is 8 bytes on 64-bit Linux and macOS and 4 on
// 64-bit Windows, and plain `char` is unsigned on AArch64 Linux and signed on
// Apple's AArch64.
class BindgenTargetFacts {
    char_bytes: int
    short_bytes: int
    int_bytes: int
    long_bytes: int
    long_long_bytes: int
    pointer_bytes: int
    size_bytes: int
    ptrdiff_bytes: int
    float_bytes: int
    double_bytes: int
    char_unsigned: bool

    fn init() {
        self.char_bytes = 0
        self.short_bytes = 0
        self.int_bytes = 0
        self.long_bytes = 0
        self.long_long_bytes = 0
        self.pointer_bytes = 0
        self.size_bytes = 0
        self.ptrdiff_bytes = 0
        self.float_bytes = 0
        self.double_bytes = 0
        self.char_unsigned = false
    }
}

// Read one `#define NAME value` line out of Clang's `-dM -E` dump.
fn bindgen_defined_number(macros: string,
                          name: string) -> int {
    let needle: string = "#define {name} "
    var offset: int = 0
    for offset < macros.len() {
        let found: int =
            bindgen_find(
                macros.slice(offset, macros.len()),
                needle)
        if found < 0 { break }
        let start: int = offset + found
        if start == 0 ||
           macros.byte_at(start - 1) == 10 {
            var end: int = start + needle.len()
            for end < macros.len() {
                let byte: int = macros.byte_at(end)
                if byte == 10 || byte == 13 { break }
                end += 1
            }
            let digits: string =
                macros.slice(
                    start + needle.len(), end).trim()
            match digits.to_int() {
                ok(value) => { return value }
                err(error) => { return 0 }
            }
        }
        offset = start + needle.len()
    }
    return 0
}

fn bindgen_defined_flag(macros: string,
                        name: string) -> bool {
    let needle: string = "#define {name} "
    if macros.starts_with(needle) { return true }
    return bindgen_find(macros, "\n{needle}") >= 0
}

fn bindgen_read_target_facts(macros: string) ->
    BindgenTargetFacts {
    let facts: BindgenTargetFacts =
        new BindgenTargetFacts()
    facts.char_bytes =
        bindgen_defined_number(
            macros, "__CHAR_BIT__") / 8
    facts.short_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_SHORT__")
    facts.int_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_INT__")
    facts.long_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_LONG__")
    facts.long_long_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_LONG_LONG__")
    facts.pointer_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_POINTER__")
    facts.size_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_SIZE_T__")
    facts.ptrdiff_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_PTRDIFF_T__")
    facts.float_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_FLOAT__")
    facts.double_bytes =
        bindgen_defined_number(
            macros, "__SIZEOF_DOUBLE__")
    facts.char_unsigned =
        bindgen_defined_flag(
            macros, "__CHAR_UNSIGNED__")
    return facts
}
