package main

class SimdDescription {
    lanes: int
    element: HirType
    element_bits: int
    is_float: bool

    fn init(lanes: int, element: HirType,
            element_bits: int, is_float: bool) {
        self.lanes = lanes
        self.element = element
        self.element_bits = element_bits
        self.is_float = is_float
    }
}

fn simd_description(name: string) -> Option<SimdDescription> {
    if !name.starts_with("Simd") { return none }
    let suffixes: List<string> =
        ["i8", "u8", "i16", "u16", "i32",
         "u32", "i64", "u64", "f32", "f64"]
    let widths: List<int> =
        [8, 8, 16, 16, 32, 32, 64, 64, 32, 64]
    for index: int in 0..suffixes.len() {
        let suffix: string = suffixes[index]
        if !name.ends_with(suffix) { continue }
        let lane_text: string =
            name.slice(4, name.len() - suffix.len())
        let lanes: int = lane_text.to_int().or(0)
        let bits: int = widths[index]
        if lanes <= 0 ||
           (lanes & (lanes - 1)) != 0 ||
           (lanes * bits != 128 &&
            lanes * bits != 256) {
            return none
        }
        return some(new SimdDescription(
            lanes,
            new HirType(
                canonical_hir_name(suffix)),
            bits, suffix.starts_with("f")))
    }
    return none
}
