import std.io

fn main() {
    var signed: List<i16> = [5, -3, 9]
    io.println("i16 min={signed.min().or(0)} max={signed.max().or(0)}")
    var narrow: List<u8> = [200, 3, 90]
    io.println("u8 min={narrow.min().or(0)} max={narrow.max().or(0)}")
    var wide_unsigned: List<u64> = [18446744073709551615, 7, 9223372036854775808]
    io.println("u64 min={wide_unsigned.min().or(0)} max={wide_unsigned.max().or(0)}")
    var floats: List<float> = [1.5, -2.5, 0.25]
    io.println("float min={floats.min().or(0.0)} max={floats.max().or(0.0)}")
    var words: List<string> = ["pear", "apple", "plum"]
    io.println("string min={words.min().or("")} max={words.max().or("")}")
    var indexes: List<i32> = [4, -9, 12]
    io.println("i32 contains={indexes.contains(-9)} index={indexes.index_of(12)}")
}
