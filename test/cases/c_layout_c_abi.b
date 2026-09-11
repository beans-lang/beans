import std.io

extern "C" struct Packet {
    tag: u8
    count: u32
    ratio: f32
    live: bool
}

extern "C" union Word {
    bits: u32
    number: f32
}

extern "C" struct Link {
    code: u32
    next: RawPtr<u8>
}

extern "C" struct Pair {
    small: u16
    bytes: [u8; 3]
}

extern "C" union AlignedBlock {
    bytes: [u8; 16]
    word: u64
}

extern "C" struct Frame {
    pair: Pair
    values: [u32; 2]
    block: AlignedBlock
}


// ---- homogeneous float aggregates ----
//
// One to four identical float or double members is an HFA, and on arm64 that
// is its own calling convention: each member travels in a vector register
// rather than in the general ones every other struct here uses. Five members
// is one too many and goes through memory instead.
//
// Beans does not implement those rules and should not: the generated bridge
// declares a real C struct and calls the function with it by value, so the C
// compiler applies the ABI. What that makes worth testing is the bridge's
// struct — it has to be layout-compatible with the C one, member for member
// and type for type, or clang lowers a different shape than the callee
// expects and the arguments arrive as garbage in exactly the cases that are
// hardest to notice.
//
// Until these existed every extern "C" struct in the corpus was a *mixed*
// one, so a float-only aggregate had never crossed the boundary anywhere in
// the tree. raylib's Vector4, Rectangle and Color are all this shape.
extern "C" struct V2d {
    x: f64
    y: f64
}

extern "C" struct V4f {
    x: f32
    y: f32
    z: f32
    w: f32
}

extern "C" struct V4d {
    a: f64
    b: f64
    c: f64
    d: f64
}

extern "C" struct V5d {
    a: f64
    b: f64
    c: f64
    d: f64
    e: f64
}

extern "C" struct MixedPair {
    x: f64
    n: i64
}

extern "C" fn beans_test_v2d_sum(v: V2d) -> f64
extern "C" fn beans_test_v2d_scale(v: V2d, by: f64) -> V2d
extern "C" fn beans_test_v4f_sum(v: V4f) -> f64
extern "C" fn beans_test_v4f_scale(v: V4f, by: f32) -> V4f
extern "C" fn beans_test_v4d_sum(v: V4d) -> f64
extern "C" fn beans_test_v4d_scale(v: V4d, by: f64) -> V4d
extern "C" fn beans_test_v5d_sum(v: V5d) -> f64
extern "C" fn beans_test_v5d_scale(v: V5d, by: f64) -> V5d
extern "C" fn beans_test_mixed_pair(m: MixedPair) -> f64
extern "C" fn beans_test_v2d_after_eight(a: f64, b: f64, c: f64, d: f64,
                                         e: f64, f: f64, g: f64, h: f64,
                                         v: V2d) -> f64

extern "C" fn beans_test_packet_size() -> u64
extern "C" fn beans_test_packet_align() -> u64
extern "C" fn beans_test_packet_offset(index: u64) -> u64
extern "C" fn beans_test_packet_fill(value: RawPtr<Packet>)
extern "C" fn beans_test_packet_roundtrip(value: Packet, extra: u32) -> Packet
extern "C" fn beans_test_word_size() -> u64
extern "C" fn beans_test_word_align() -> u64
extern "C" fn beans_test_word_offset(index: u64) -> u64
extern "C" fn beans_test_word_fill(value: RawPtr<Word>)
extern "C" fn beans_test_word_roundtrip(value: Word) -> Word
extern "C" fn beans_test_link_size() -> u64
extern "C" fn beans_test_link_align() -> u64
extern "C" fn beans_test_link_offset(index: u64) -> u64
extern "C" fn beans_test_link_fill(value: RawPtr<Link>)
extern "C" fn beans_test_pair_size() -> u64
extern "C" fn beans_test_pair_align() -> u64
extern "C" fn beans_test_pair_offset(index: u64) -> u64
extern "C" fn beans_test_block_size() -> u64
extern "C" fn beans_test_block_align() -> u64
extern "C" fn beans_test_block_offset(index: u64) -> u64
extern "C" fn beans_test_frame_size() -> u64
extern "C" fn beans_test_frame_align() -> u64
extern "C" fn beans_test_frame_offset(index: u64) -> u64
extern "C" fn beans_test_frame_fill(value: RawPtr<Frame>)
extern "C" fn beans_test_frame_roundtrip(value: Frame) -> Frame
extern "C" fn beans_test_mixed_float(first: f32, second: f64, third: f32, whole: u64) -> f64

fn main() {
    unsafe {
        let packet: RawPtr<Packet> = RawPtr.alloc(1)
        beans_test_packet_fill(packet)
        let loaded: Packet = packet.read()
        io.println("C struct {beans_test_packet_size()} {beans_test_packet_align()} {beans_test_packet_offset(0)} {beans_test_packet_offset(1)} {beans_test_packet_offset(2)} {beans_test_packet_offset(3)} {loaded.tag} {loaded.count} {loaded.ratio} {loaded.live}")
        let returned: Packet = beans_test_packet_roundtrip(loaded, 7)
        io.println("C struct value {returned.tag} {returned.count} {returned.ratio} {returned.live}")

        let word: RawPtr<Word> = RawPtr.alloc(1)
        beans_test_word_fill(word)
        let loaded_word: Word = word.read()
        io.println("C union {beans_test_word_size()} {beans_test_word_align()} {beans_test_word_offset(0)} {beans_test_word_offset(1)} {loaded_word.bits} {loaded_word.number}")
        let returned_word: Word = beans_test_word_roundtrip(loaded_word)
        io.println("C union value {returned_word.bits} {returned_word.number}")

        let link: RawPtr<Link> = RawPtr.alloc(1)
        beans_test_link_fill(link)
        let loaded_link: Link = link.read()
        io.println("C pointer {beans_test_link_size()} {beans_test_link_align()} {beans_test_link_offset(0)} {beans_test_link_offset(1)} {loaded_link.code} {loaded_link.next.read()}")

        let frame: RawPtr<Frame> = RawPtr.alloc(1)
        beans_test_frame_fill(frame)
        let loaded_frame: Frame = frame.read()
        io.println("C pair {beans_test_pair_size()} {beans_test_pair_align()} {beans_test_pair_offset(0)} {beans_test_pair_offset(1)}")
        io.println("C aligned union {beans_test_block_size()} {beans_test_block_align()} {beans_test_block_offset(0)} {beans_test_block_offset(1)}")
        io.println("C nested {beans_test_frame_size()} {beans_test_frame_align()} {beans_test_frame_offset(0)} {beans_test_frame_offset(1)} {beans_test_frame_offset(2)} Beans {frame.element_size()} {frame.element_align()} {loaded_frame.pair.small} {loaded_frame.pair.bytes[1]} {loaded_frame.values[1]} {loaded_frame.block.word}")
        let returned_frame: Frame = beans_test_frame_roundtrip(loaded_frame)
        io.println("C nested value {returned_frame.pair.small} {returned_frame.values[1]} {returned_frame.block.word}")
        io.println("C mixed float {beans_test_mixed_float(1.25, 2.5, 3.75, 4)}")
        // Each shape is both passed and returned, because arm64 uses the
        // vector registers in both directions and a wrapper can get one right
        // and the other wrong.
        let two: V2d = V2d { x: 1.5, y: 2.25 }
        io.println("C hfa f64x2 {beans_test_v2d_sum(two)} {beans_test_v2d_scale(two, 2.0).x} {beans_test_v2d_scale(two, 2.0).y}")

        let four_small: V4f = V4f { x: 1.5, y: 2.5, z: 3.5, w: 4.5 }
        let scaled_small: V4f = beans_test_v4f_scale(four_small, 2.0)
        io.println("C hfa f32x4 {beans_test_v4f_sum(four_small)} {scaled_small.x} {scaled_small.w}")

        let four: V4d = V4d { a: 1.0, b: 2.0, c: 3.0, d: 4.0 }
        let scaled: V4d = beans_test_v4d_scale(four, 0.5)
        io.println("C hfa f64x4 {beans_test_v4d_sum(four)} {scaled.a} {scaled.d}")

        // One member past the limit, so this one is not an HFA at all and
        // travels through memory. Same arithmetic, different convention.
        let five: V5d = V5d { a: 1.0, b: 2.0, c: 3.0, d: 4.0, e: 5.0 }
        let five_scaled: V5d = beans_test_v5d_scale(five, 2.0)
        io.println("C indirect f64x5 {beans_test_v5d_sum(five)} {five_scaled.a} {five_scaled.e}")

        // Not homogeneous, so the general registers — the control.
        io.println("C mixed pair {beans_test_mixed_pair(MixedPair { x: 1.5, n: 3 })}")

        // Eight doubles fill v0 to v7, so the struct after them has to go on
        // the stack.
        io.println("C hfa spilled {beans_test_v2d_after_eight(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, two)}")

        frame.free()
        link.free()
        word.free()
        packet.free()
    }
}
