// float and f32 order by IEEE 754 totalOrder wherever Order/Eq does the
// comparing, while the operators stay IEEE (spec/SYNTAX.md, "Number rules").
// Every line here has to read the same on both backends AND match the golden
// transcript: the ordered-container half of issue #84 was a case where both
// backends agreed and both were wrong, so an interpreter-vs-native diff alone
// would not have caught it.
//
// NaNs are built from their bit patterns rather than from `0.0 / 0.0`, whose
// sign is the platform's choice — x86 hands back a negative NaN there and
// arm64 a positive one. The transcript must not depend on that.

import std.io
import std.encoding.binary

struct Point {
    x: float
    y: int
}

// The f32 twin of Point: a narrow float inside an aggregate takes a different
// route through both backends (a 32-bit compare, and a 32-bit slot in a wide
// map key) than a bare f32 does.
struct Sample {
    a: f32
    b: int
}

enum Reading {
    missing
    level(value: float)
}

fn from_bits(pattern: u64) -> float {
    var raw: Bytes = new Bytes(0)
    binary.append_u64(raw, pattern, binary.ByteOrder.little)
    match binary.read_f64(raw, 0, binary.ByteOrder.little) {
        ok(value) => { return value }
        err(problem) => { return 0.0 }
    }
}

fn bits_of(value: float) -> u64 {
    var raw: Bytes = new Bytes(0)
    binary.append_f64(raw, value, binary.ByteOrder.little)
    match binary.read_u64(raw, 0, binary.ByteOrder.little) {
        ok(pattern) => { return pattern }
        err(problem) => { return 0 }
    }
}

fn f32_from_bits(pattern: u64) -> f32 {
    var raw: Bytes = new Bytes(0)
    binary.append_u32(raw, pattern as u32, binary.ByteOrder.little)
    match binary.read_f32(raw, 0, binary.ByteOrder.little) {
        ok(value) => { return value }
        err(problem) => { return 0.0 as f32 }
    }
}

// The sign of a NaN never reaches the rendered text, so a transcript naming
// one has to name its bits.
fn tag(value: float) -> string {
    let pattern: u64 = bits_of(value)
    if pattern == 9221120237041090560 { return "+nan" }
    if pattern == 18444492273895866368 { return "-nan" }
    if pattern == 9221120237041090561 { return "+nan(payload)" }
    if pattern == 9223372036854775808 { return "-0.0" }
    if pattern == 0 { return "+0.0" }
    return "{value}"
}

fn tags(values: List<float>) -> string {
    var pieces: List<string> = []
    for value: float in values {
        pieces.push(tag(value))
    }
    return "[{pieces.join(", ")}]"
}

// What `Order` and `Eq` mean when the thing being compared is a type
// parameter: the interface's comparison, not the operators of whatever the
// instantiation binds.
fn less<T implements Order>(a: T, b: T) -> bool { return a < b }
fn at_most<T implements Order>(a: T, b: T) -> bool { return a <= b }
fn greater<T implements Order>(a: T, b: T) -> bool { return a > b }
fn at_least<T implements Order>(a: T, b: T) -> bool { return a >= b }
fn alike<T implements Eq>(a: T, b: T) -> bool { return a == b }
fn differs<T implements Eq>(a: T, b: T) -> bool { return a != b }

// The shape an ordered container has: a binary descent over `K implements
// Order`, which under a partial order stops on "neither less nor greater"
// and calls an unrelated key a match. This is `SortedMap` in miniature.
class Sorted<K implements Order & Clone> {
    keys: List<K> = []

    fn init() {}

    fn seek(key: K) -> int {
        var low: int = 0
        var high: int = self.keys.len()
        for low < high {
            let mid: int = (low + high) / 2
            if self.keys[mid] < key {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    fn has(key: K) -> bool {
        let at: int = self.seek(key)
        return at < self.keys.len() &&
               !(key < self.keys[at])
    }

    fn insert(key: K) {
        let at: int = self.seek(key)
        if at < self.keys.len() &&
           !(key < self.keys[at]) {
            return
        }
        self.keys.insert(at, key)
    }

    fn len() -> int { return self.keys.len() }
}

fn show(label: string, value: bool) {
    io.println("{label}: {value}")
}

fn sorted_keys(keys: List<float>) -> string {
    var copy: List<float> = []
    for key: float in keys { copy.push(key) }
    copy.sort()
    return tags(copy)
}

fn main() {
    let pos_nan: float = from_bits(9221120237041090560)
    let neg_nan: float = from_bits(18444492273895866368)
    let payload_nan: float = from_bits(9221120237041090561)
    let neg_zero: float = from_bits(9223372036854775808)
    let pos_zero: float = 0.0
    let inf: float = 1.0 / 0.0
    let neg_inf: float = 0.0 - inf
    let computed_nan: float = 0.0 / 0.0

    io.println("== operators stay IEEE ==")
    show("nan == nan", pos_nan == pos_nan)
    show("nan != nan", pos_nan != pos_nan)
    show("nan < 1.0", pos_nan < 1.0)
    show("nan > 1.0", pos_nan > 1.0)
    show("nan <= 1.0", pos_nan <= 1.0)
    show("nan >= 1.0", pos_nan >= 1.0)
    show("1.0 < nan", 1.0 < pos_nan)
    show("-0.0 == 0.0", neg_zero == pos_zero)
    show("-0.0 < 0.0", neg_zero < pos_zero)
    show("0.0 <= -0.0", pos_zero <= neg_zero)
    show("-nan == nan", neg_nan == pos_nan)
    show("1.0 < 2.0", 1.0 < 2.0)
    show("inf > 1.0", inf > 1.0)
    show("-inf < -1.0", neg_inf < -1.0)

    io.println("== issue #84 repro: Map<float, int> keyed on a NaN ==")
    var reported: Map<float, int> = {}
    reported[1.0] = 1
    reported[computed_nan] = 99
    io.println("len={reported.len()} get={reported.get(computed_nan)} contains={reported.contains_key(computed_nan)}")
    reported[computed_nan] = 100
    io.println("after 2nd NaN insert: len={reported.len()} get={reported.get(computed_nan)}")
    var seen: int = 0
    for key: float in reported.keys() { seen += 1 }
    io.println("iterated keys={seen}")

    io.println("== a NaN key stays one key however often it is written ==")
    var repeated: Map<float, int> = {}
    for round: int in 0..1000 {
        repeated[computed_nan] = round
    }
    io.println("1000 inserts -> len={repeated.len()} get={repeated.get(computed_nan)}")

    io.println("== +NaN, -NaN and a NaN payload are separate keys ==")
    var nans: Map<float, int> = {}
    nans[pos_nan] = 1
    nans[neg_nan] = 2
    nans[payload_nan] = 3
    io.println("len={nans.len()}")
    io.println("get(+nan)={nans.get(pos_nan)} get(-nan)={nans.get(neg_nan)} get(payload)={nans.get(payload_nan)}")
    nans[neg_nan] = 20
    io.println("replace -nan -> len={nans.len()} get={nans.get(neg_nan)}")
    io.println("keys={sorted_keys(nans.keys())}")
    io.println("remove(-nan)={nans.remove(neg_nan)} len={nans.len()} get(-nan)={nans.get(neg_nan)} get(+nan)={nans.get(pos_nan)}")
    io.println("remove(-nan) again={nans.remove(neg_nan)} len={nans.len()}")

    io.println("== the two zeros are two keys ==")
    var zeros: Map<float, int> = {}
    zeros[pos_zero] = 1
    zeros[neg_zero] = 2
    io.println("len={zeros.len()} get(+0.0)={zeros.get(pos_zero)} get(-0.0)={zeros.get(neg_zero)}")
    io.println("keys={sorted_keys(zeros.keys())}")
    io.println("remove(+0.0)={zeros.remove(pos_zero)} len={zeros.len()} get(-0.0)={zeros.get(neg_zero)}")

    io.println("== OrderedMap agrees ==")
    var ordered: OrderedMap<float, int> = {}
    ordered[pos_nan] = 1
    ordered[neg_zero] = 2
    ordered[pos_zero] = 3
    ordered[pos_nan] = 4
    io.println("len={ordered.len()} get(nan)={ordered.get(pos_nan)} get(-0.0)={ordered.get(neg_zero)}")
    var order: List<string> = []
    for key: float, value: int in ordered {
        order.push("{tag(key)}={value}")
    }
    io.println("insertion order={order.join(", ")}")

    io.println("== sort: n = 1, 2, many ==")
    var one: List<float> = [pos_nan]
    one.sort()
    io.println("n=1 {tags(one)}")
    var two: List<float> = [pos_nan, 1.0]
    two.sort()
    io.println("n=2 nan first {tags(two)}")
    var two_back: List<float> = [1.0, pos_nan]
    two_back.sort()
    io.println("n=2 nan last {tags(two_back)}")
    var reported_sort: List<float> = [3.0, 1.0, pos_nan, 2.0]
    reported_sort.sort()
    io.println("issue case {tags(reported_sort)}")
    var several: List<float> = [pos_nan, 2.0, neg_nan, 1.0, pos_nan, 3.0]
    several.sort()
    io.println("several nans {tags(several)}")
    var all_nan: List<float> = [pos_nan, neg_nan, payload_nan, pos_nan]
    all_nan.sort()
    io.println("all nans {tags(all_nan)} len={all_nan.len()}")
    var whole_line: List<float> = [
        pos_zero, inf, neg_nan, 1.0, neg_inf, neg_zero,
        pos_nan, -1.0]
    whole_line.sort()
    io.println("whole line {tags(whole_line)}")
    io.println("max={tag(whole_line.max().or(0.0))} min={tag(whole_line.min().or(0.0))}")
    var empty: List<float> = []
    io.println("empty max={empty.max()} min={empty.min()}")

    io.println("== a big sort keeps every NaN and orders the rest ==")
    var many: List<float> = []
    for index: int in 0..5000 {
        if index % 7 == 0 {
            many.push(pos_nan)
        } else if index % 11 == 0 {
            many.push(neg_nan)
        } else {
            many.push((5000 - index) as float)
        }
    }
    many.sort()
    var leading_neg: int = 0
    var trailing_pos: int = 0
    var ascending: bool = true
    var previous: float = neg_inf
    var numbers: int = 0
    for index: int in 0..many.len() {
        let value: float = many[index]
        if value != value {
            if numbers == 0 { leading_neg += 1 } else { trailing_pos += 1 }
            continue
        }
        numbers += 1
        if value < previous { ascending = false }
        previous = value
    }
    io.println("len={many.len()} -nan first={leading_neg} +nan last={trailing_pos} numbers={numbers} ascending={ascending}")

    io.println("== contains, index_of and list equality use Eq ==")
    var search: List<float> = [1.0, pos_nan, neg_zero, neg_nan]
    show("contains(+nan)", search.contains(pos_nan))
    show("contains(-nan)", search.contains(neg_nan))
    show("contains(payload nan)", search.contains(payload_nan))
    io.println("index_of(+nan)={search.index_of(pos_nan)} index_of(-nan)={search.index_of(neg_nan)}")
    show("contains(-0.0)", search.contains(neg_zero))
    show("contains(+0.0)", search.contains(pos_zero))
    let left: List<float> = [1.0, pos_nan, neg_zero]
    let right: List<float> = [1.0, pos_nan, neg_zero]
    let zero_split: List<float> = [1.0, pos_nan, pos_zero]
    let nan_split: List<float> = [1.0, neg_nan, neg_zero]
    show("[1, +nan, -0.0] == itself", left == right)
    show("[1, +nan, -0.0] == [1, +nan, +0.0]", left == zero_split)
    show("[1, +nan, -0.0] == [1, -nan, -0.0]", left == nan_split)

    io.println("== a float inside an aggregate compares by Eq too ==")
    let near: Point = Point { x: pos_nan, y: 1 }
    let same: Point = Point { x: pos_nan, y: 1 }
    let other_nan: Point = Point { x: neg_nan, y: 1 }
    let minus_zero: Point = Point { x: neg_zero, y: 1 }
    let plus_zero: Point = Point { x: pos_zero, y: 1 }
    show("Point(+nan) == Point(+nan)", near == same)
    show("Point(+nan) == Point(-nan)", near == other_nan)
    show("Point(-0.0) == Point(+0.0)", minus_zero == plus_zero)
    var points: Map<Point, int> = {}
    points[near] = 1
    points[other_nan] = 2
    points[minus_zero] = 3
    points[plus_zero] = 4
    points[near] = 10
    io.println("point keys len={points.len()} get(+nan)={points.get(same)} get(-nan)={points.get(other_nan)} get(-0.0)={points.get(minus_zero)}")

    let pair: [float; 2] = [pos_nan, neg_zero]
    let pair_same: [float; 2] = [pos_nan, neg_zero]
    let pair_zero: [float; 2] = [pos_nan, pos_zero]
    show("[nan, -0.0] array == itself", pair == pair_same)
    show("[nan, -0.0] array == [nan, +0.0]", pair == pair_zero)

    let some_nan: Option<float> = some(pos_nan)
    let some_same: Option<float> = some(pos_nan)
    let some_other: Option<float> = some(neg_nan)
    show("some(+nan) == some(+nan)", some_nan == some_same)
    show("some(+nan) == some(-nan)", some_nan == some_other)
    var options: Map<Option<float>, int> = {}
    options[some_nan] = 1
    options[some_other] = 2
    options[some_nan] = 3
    io.println("option keys len={options.len()} get={options.get(some_same)}")

    show("level(+nan) == level(+nan)",
         Reading.level(pos_nan) == Reading.level(pos_nan))
    show("level(+nan) == level(-nan)",
         Reading.level(pos_nan) == Reading.level(neg_nan))
    var readings: Map<Reading, int> = {}
    readings[Reading.level(pos_nan)] = 1
    readings[Reading.level(neg_nan)] = 2
    readings[Reading.level(pos_nan)] = 3
    io.println("enum keys len={readings.len()} get={readings.get(Reading.level(pos_nan))}")

    io.println("== f32 follows the same rule ==")
    let f32_pos_nan: f32 = f32_from_bits(2143289344)
    let f32_neg_nan: f32 = f32_from_bits(4290772992)
    let f32_neg_zero: f32 = f32_from_bits(2147483648)
    let f32_pos_zero: f32 = 0.0 as f32
    var narrow: Map<f32, int> = {}
    narrow[f32_pos_nan] = 1
    narrow[f32_neg_nan] = 2
    narrow[f32_pos_zero] = 3
    narrow[f32_neg_zero] = 4
    narrow[f32_pos_nan] = 10
    io.println("f32 keys len={narrow.len()} get(+nan)={narrow.get(f32_pos_nan)} get(-nan)={narrow.get(f32_neg_nan)} get(-0.0)={narrow.get(f32_neg_zero)}")
    var narrow_sort: List<f32> = [
        f32_pos_nan, 1.0 as f32, f32_neg_zero, f32_neg_nan,
        f32_pos_zero, -1.0 as f32]
    narrow_sort.sort()
    var narrow_tags: List<float> = []
    for value: f32 in narrow_sort {
        narrow_tags.push(value as float)
    }
    io.println("f32 sort {tags(narrow_tags)}")
    show("f32 contains(-nan)", narrow_sort.contains(f32_neg_nan))
    show("f32 -0.0 == 0.0 operator", f32_neg_zero == f32_pos_zero)
    show("f32 nan == nan operator", f32_pos_nan == f32_pos_nan)
    let sample_nan: Sample = Sample { a: f32_pos_nan, b: 1 }
    let sample_same: Sample = Sample { a: f32_pos_nan, b: 1 }
    let sample_other: Sample = Sample { a: f32_neg_nan, b: 1 }
    let sample_minus: Sample = Sample { a: f32_neg_zero, b: 1 }
    let sample_plus: Sample = Sample { a: f32_pos_zero, b: 1 }
    show("Sample(+nan) == Sample(+nan)", sample_nan == sample_same)
    show("Sample(+nan) == Sample(-nan)", sample_nan == sample_other)
    show("Sample(-0.0) == Sample(+0.0)", sample_minus == sample_plus)
    var samples: Map<Sample, int> = {}
    samples[sample_nan] = 1
    samples[sample_other] = 2
    samples[sample_minus] = 3
    samples[sample_plus] = 4
    samples[sample_nan] = 10
    io.println("f32 struct keys len={samples.len()} get(+nan)={samples.get(sample_same)} get(-nan)={samples.get(sample_other)} get(-0.0)={samples.get(sample_minus)}")
    let narrow_pair: [f32; 2] = [f32_pos_nan, f32_neg_zero]
    let narrow_pair_same: [f32; 2] = [f32_pos_nan, f32_neg_zero]
    let narrow_pair_zero: [f32; 2] = [f32_pos_nan, f32_pos_zero]
    show("[f32 nan, -0.0] array == itself", narrow_pair == narrow_pair_same)
    show("[f32 nan, -0.0] array == [nan, +0.0]", narrow_pair == narrow_pair_zero)
    let narrow_option: Option<f32> = some(f32_pos_nan)
    let narrow_option_same: Option<f32> = some(f32_pos_nan)
    let narrow_option_other: Option<f32> = some(f32_neg_nan)
    show("some(f32 +nan) == some(f32 +nan)",
         narrow_option == narrow_option_same)
    show("some(f32 +nan) == some(f32 -nan)",
         narrow_option == narrow_option_other)

    io.println("== Order and Eq over a type parameter are the interface ==")
    show("less(+nan, 1.0)", less(pos_nan, 1.0))
    show("less(1.0, +nan)", less(1.0, pos_nan))
    show("less(-nan, -inf)", less(neg_nan, neg_inf))
    show("less(-inf, -nan)", less(neg_inf, neg_nan))
    show("less(-0.0, +0.0)", less(neg_zero, pos_zero))
    show("less(+0.0, -0.0)", less(pos_zero, neg_zero))
    show("at_most(+nan, +nan)", at_most(pos_nan, pos_nan))
    show("greater(+nan, 1.0)", greater(pos_nan, 1.0))
    show("at_least(1.0, +nan)", at_least(1.0, pos_nan))
    show("alike(+nan, +nan)", alike(pos_nan, pos_nan))
    show("alike(+nan, -nan)", alike(pos_nan, neg_nan))
    show("differs(-0.0, +0.0)", differs(neg_zero, pos_zero))
    show("f32 less(+nan, 1.0)",
         less(f32_pos_nan, 1.0 as f32))
    show("f32 alike(+nan, +nan)",
         alike(f32_pos_nan, f32_pos_nan))
    show("f32 alike(-0.0, +0.0)",
         alike(f32_neg_zero, f32_pos_zero))
    show("int less(1, 2)", less(1, 2))
    show("int alike(3, 3)", alike(3, 3))
    show("string less(a, b)", less("a", "b"))
    show("decimal less(1.0, 2.0)",
         less(1.0 as decimal, 2.0 as decimal))

    io.println("== an ordered container written in Beans keeps a NaN key ==")
    var tree: Sorted<float> = new Sorted<float>()
    tree.insert(2.0)
    tree.insert(1.0)
    tree.insert(3.0)
    io.println("numbers only: len={tree.len()} keys={tags(tree.keys)}")
    tree.insert(pos_nan)
    io.println("with +nan: len={tree.len()} keys={tags(tree.keys)}")
    show("has(+nan)", tree.has(pos_nan))
    show("has(2.0) still", tree.has(2.0))
    tree.insert(pos_nan)
    io.println("+nan twice: len={tree.len()} keys={tags(tree.keys)}")
    tree.insert(neg_nan)
    tree.insert(neg_zero)
    tree.insert(pos_zero)
    io.println("with -nan and both zeros: len={tree.len()} keys={tags(tree.keys)}")
    show("has(-nan)", tree.has(neg_nan))
    show("has(-0.0)", tree.has(neg_zero))
    show("has(+0.0)", tree.has(pos_zero))
    show("has(1.0) still", tree.has(1.0))
    show("has(3.0) still", tree.has(3.0))
    var integers: Sorted<int> = new Sorted<int>()
    integers.insert(5)
    integers.insert(1)
    integers.insert(5)
    io.println("int container: len={integers.len()} keys={integers.keys}")

    io.println("== decimal has neither NaN nor a negative zero, so it is untouched ==")
    let d_zero: decimal = 0.0
    let d_neg_zero: decimal = -0.0
    var money: Map<decimal, int> = {}
    money[d_zero] = 1
    money[d_neg_zero] = 2
    io.println("decimal keys len={money.len()} get={money.get(d_zero)}")
    show("decimal -0.0 == 0.0", d_neg_zero == d_zero)
    show("decimal -0.0 < 0.0", d_neg_zero < d_zero)
    var d_sort: List<decimal> = [3.0, 1.0, 2.0]
    d_sort.sort()
    io.println("decimal sort={d_sort}")
}
