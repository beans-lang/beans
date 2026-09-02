// A module constant is the value its initializer folds to, written where it
// is used. The test that proves this is not a handful of examples: it folds
// an expression into a `const` and computes the same expression at run time,
// on the same type, and asserts they are equal. If the fold ever narrows,
// wraps or rounds differently than a backend does, one of these lines prints
// false — and it must hold on both backends, byte for byte.
import std.io

// Integers: every operator, and the narrowing that makes a const of type T
// behave like a `let: T`, not like a 64-bit literal.
const C_ADD: i8 = 100 + 100          // 200 wraps into i8
const C_SUB: u8 = 3 - 10             // underflows into u8
const C_MUL: i16 = 300 * 300         // 90000 wraps into i16
const C_DIV: i32 = -2147483647 / 2
const C_MOD: i32 = -100 % 7
const C_NEG: int = -(BASE * 3) + QUAD // unary minus over folded operands
const C_NOT: u8 = ~0                 // 255
const C_SHL: i32 = 1 << 31           // i32 minimum
const C_SHR: u32 = 3735928559 >> 12
const C_AND: int = 0xF0F0 & 0x3C3C
const C_OR: int = 0x0F0F | 0x3030
const C_XOR: int = 0xFFFF ^ 0x0F0F
const C_U16: u16 = 0xFFFF + 2        // wraps to 1
const C_I64: i64 = (1 << 62) + (1 << 62) - 1
// An intermediate result that overflows and is then divided: the fold must
// narrow after each operator, not only at the end. `100 + 100` is -56 in i8,
// and -56 / 2 is -28; without per-operator narrowing the fold would divide
// 200 and answer 100, which no backend computes.
const C_CHAIN: i8 = (100 + 100) / 2

// A u64 at or above 2^63 is the one value the fold cannot compute with, so
// it must still be declarable and usable — the spelling a use site
// materializes is the source's own, not the fold's accumulator. Both
// spellings of the same number, because a decimal magnitude past i64 comes
// back from `to_int()` as i64's maximum rather than as a failure, and the
// two used to answer differently.
const U64_MAX_DEC: u64 = 18446744073709551615
const U64_MAX_HEX: u64 = 0xFFFFFFFFFFFFFFFF
const U64_HALF: u64 = 9223372036854775808

// A constant may name another, declared above or below, in any order.
const BASE: int = 10
const DOUBLE: int = BASE * 2
const QUAD: int = DOUBLE + DOUBLE
const FROM_BELOW: int = TAIL - QUAD
const TAIL: int = 100

// bool folds its own operators and integer/string comparison.
const B_AND: bool = true && false
const B_OR: bool = (BASE > 0) || false
const B_NOT: bool = !B_AND
const B_CMP: bool = BASE < DOUBLE && QUAD >= DOUBLE
const B_STR_EQ: bool = "beans" == "beans"
const B_STR_NE: bool = "a" != "b"
const B_STR_LT: bool = "abc" < "abd"

// strings, including escapes and a raw literal folded to one spelling.
const S_PLAIN: string = "hello"
const S_ESC: string = "tab\tesc\x1b end"
const S_RAW: string = r"/users/{id}"
const S_UNICODE: string = "\u{1f600}"

pub const PUBLIC_MAX: int = 1 << 20

// A constant stands where a literal stands, in a match arm.
fn classify(n: int) -> string {
    return match n {
        BASE => "base",
        QUAD => "quad",
        TAIL => "tail",
        _ => "other",
    }
}

fn eq_int(label: string, folded: int, runtime: int) {
    io.println("{label} {folded} {runtime} {folded == runtime}")
}

fn main() {
    // The fold must equal the same expression evaluated at run time.
    let r_add: i8 = 100 + 100
    let r_sub: u8 = 3 - 10
    let r_mul: i16 = 300 * 300
    let r_div: i32 = -2147483647 / 2
    let r_mod: i32 = -100 % 7
    let r_neg: int = -(10 * 3) + 40
    let r_not: u8 = ~0
    let r_shl: i32 = 1 << 31
    let r_shr: u32 = 3735928559 >> 12
    let r_and: int = 0xF0F0 & 0x3C3C
    let r_or: int = 0x0F0F | 0x3030
    let r_xor: int = 0xFFFF ^ 0x0F0F
    let r_u16: u16 = 0xFFFF + 2
    let r_i64: i64 = (1 << 62) + (1 << 62) - 1
    let r_chain: i8 = (100 + 100) / 2
    eq_int("add", C_ADD as int, r_add as int)
    eq_int("sub", C_SUB as int, r_sub as int)
    eq_int("mul", C_MUL as int, r_mul as int)
    eq_int("div", C_DIV as int, r_div as int)
    eq_int("mod", C_MOD as int, r_mod as int)
    eq_int("neg", C_NEG, r_neg)
    eq_int("not", C_NOT as int, r_not as int)
    eq_int("shl", C_SHL as int, r_shl as int)
    eq_int("shr", C_SHR as int, r_shr as int)
    eq_int("and", C_AND, r_and)
    eq_int("or", C_OR, r_or)
    eq_int("xor", C_XOR, r_xor)
    eq_int("u16", C_U16 as int, r_u16 as int)
    eq_int("i64", C_I64, r_i64)
    eq_int("chain", C_CHAIN as int, r_chain as int)

    // Cross-references resolve regardless of declaration order.
    io.println("base {BASE} double {DOUBLE} quad {QUAD} fromBelow {FROM_BELOW} tail {TAIL}")

    // bool
    io.println("bool {B_AND} {B_OR} {B_NOT} {B_CMP} {B_STR_EQ} {B_STR_NE} {B_STR_LT}")

    // strings: a const equals the literal it folded from, raw and escaped alike
    io.println("str [{S_PLAIN}] [{S_RAW}] esc={S_ESC.len()} uni={S_UNICODE.len()}")
    io.println("raw-eq {S_RAW == "/users/\{id\}"} esc-eq {S_ESC == "tab\tesc\x1b end"}")

    // pub const is a value like any other
    io.println("public {PUBLIC_MAX}")

    // A u64 past 2^63 materializes the number, not the accumulator's edge.
    let r_max: u64 = 18446744073709551615
    let r_hex: u64 = 0xFFFFFFFFFFFFFFFF
    let r_half: u64 = 9223372036854775808
    io.println("u64 {U64_MAX_DEC} {U64_MAX_HEX} {U64_HALF}")
    io.println("u64-eq {U64_MAX_DEC == r_max} {U64_MAX_HEX == r_hex} {U64_HALF == r_half} {U64_MAX_DEC > U64_HALF} {U64_HALF > 9223372036854775807}")

    // match arms
    io.println("classify {classify(10)} {classify(40)} {classify(100)} {classify(7)}")
}
