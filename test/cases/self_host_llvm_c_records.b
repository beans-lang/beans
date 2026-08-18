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

extern "C" fn beans_test_packet_roundtrip(
    value: Packet, extra: u32) -> Packet
extern "C" fn beans_test_word_roundtrip(
    value: Word) -> Word
extern "C" fn beans_test_frame_roundtrip(
    value: Frame) -> Frame

fn main() {
    unsafe {
        let packet: Packet =
            Packet {
                tag: 9,
                count: 123,
                ratio: 2.5,
                live: true,
            }
        let returned: Packet =
            beans_test_packet_roundtrip(packet, 7)
        io.println("packet {returned.tag} {returned.count} {returned.ratio} {returned.live} eq {packet == returned}")

        let word: Word = Word { number: 3.0 }
        let returned_word: Word =
            beans_test_word_roundtrip(word)
        io.println("word {returned_word.bits} {returned_word.number}")

        let frame: Frame = Frame {
            pair: Pair {
                small: 513,
                bytes: [4, 5, 6],
            },
            values: [1000, 2000],
            block: AlignedBlock {
                bytes: [
                    1, 2, 3, 4, 5, 6, 7, 8,
                    9, 10, 11, 12, 13, 14, 15, 16,
                ],
            },
        }
        let returned_frame: Frame =
            beans_test_frame_roundtrip(frame)
        io.println("frame {returned_frame.pair.small} {returned_frame.values[1]} {returned_frame.block.word}")
    }
}
