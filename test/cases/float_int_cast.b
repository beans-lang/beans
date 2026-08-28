// A float with no value in the integer type it is cast to saturates at that
// type's own bounds, and NaN is 0 — every width, from f32 and f64, on both
// backends. The native backend used to emit a bare fptosi/fptoui, which LLVM
// defines as poison for exactly these inputs: the same expression printed a
// different number on every build, and sometimes an address. The interpreter
// saturated at int's range and then truncated, so `1e300 as i32` was -1 there
// and something else again in a native binary.
//
// Every value appears twice: once as a constant the optimizer can fold, and
// once parsed at run time, where it cannot. The poison only bit when the value
// became visible to the optimizer, so a test built from opaque values alone
// proves nothing.
import std.io

fn parsed(text: string) -> float {
    return text.to_float().or(0.0)
}

fn signed(label: string, v: float) {
    io.println("{label} s {v as i8} {v as i16} {v as i32} {v as int}")
}

fn unsigned(label: string, v: float) {
    io.println("{label} u {v as u8} {v as u16} {v as u32} {v as u64}")
}

fn narrow(label: string, v: f32) {
    io.println("{label} f32 {v as i8} {v as i16} {v as i32} {v as int} {v as u8} {v as u32} {v as u64}")
}

fn main() {
    let nan: float = 0.0 / 0.0
    let inf: float = 1.0 / 0.0

    signed("huge  const", 1e300)
    signed("huge  live ", parsed("1e300"))
    unsigned("huge  const", 1e300)
    unsigned("huge  live ", parsed("1e300"))

    signed("neg   const", -1e300)
    signed("neg   live ", parsed("-1e300"))
    unsigned("neg   const", -1e300)
    unsigned("neg   live ", parsed("-1e300"))

    signed("inf   const", inf)
    signed("inf   live ", parsed("inf"))
    unsigned("inf   const", inf)
    unsigned("inf   live ", parsed("inf"))

    signed("-inf  const", -inf)
    signed("-inf  live ", parsed("-inf"))
    unsigned("-inf  const", -inf)
    unsigned("-inf  live ", parsed("-inf"))

    signed("nan   const", nan)
    signed("nan   live ", parsed("nan"))
    unsigned("nan   const", nan)
    unsigned("nan   live ", parsed("nan"))

    // just outside each width, where "saturate at the target" and "saturate at
    // int and truncate" give different answers
    signed("edge  const", 300.0)
    signed("edge  live ", parsed("300"))
    unsigned("edge  const", 300.0)
    unsigned("edge  live ", parsed("300"))
    signed("wide  const", 5000000000.0)
    signed("wide  live ", parsed("5000000000"))
    unsigned("wide  const", 5000000000.0)
    unsigned("wide  live ", parsed("5000000000"))

    // in range on every width, so nothing saturates and truncation is toward
    // zero as always
    signed("ok    const", 42.9)
    signed("ok    live ", parsed("42.9"))
    signed("okneg const", -42.9)
    signed("okneg live ", parsed("-42.9"))
    unsigned("ok    const", 42.9)
    unsigned("ok    live ", parsed("42.9"))

    // exactly on the bound, and the largest double strictly inside it
    signed("bound const", 9223372036854775808.0)
    signed("bound live ", parsed("9223372036854775808"))
    signed("under const", 9223372036854774784.0)
    signed("under live ", parsed("9223372036854774784"))
    unsigned("ubound live", parsed("18446744073709551616"))
    unsigned("uunder live", parsed("18446744073709549568"))

    let f32big: f32 = 1e30
    let f32nan: f32 = 0.0 / 0.0
    narrow("f32big const", 1e30)
    narrow("f32big live ", parsed("1e30") as f32)
    narrow("f32neg const", -1e30)
    narrow("f32nan const", f32nan)
    narrow("f32ok  const", 42.5)

    // round() answers the same way: it is a float-to-int conversion too
    io.println("round {f32big.round()} {(0.0 - 1e300).round()} {nan.round()} {inf.round()} {(2.5).round()} {(-2.5).round()}")
    io.println("f32   {f32big.round()} {f32nan.round()}")
}
