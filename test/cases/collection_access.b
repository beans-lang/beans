// Required reads keep their element type; optional reads never create an entry.
import std.io

struct Record {
    text: string
    count: int
}

class Counter {
    pub calls: int = 0
}

fn index(counter: Counter) -> int {
    counter.calls += 1
    return 0
}

fn bytes(counter: Counter) -> Bytes {
    counter.calls += 10
    return Bytes.from("B")
}

fn array(counter: Counter) -> [int; 2] {
    counter.calls += 10
    return [41, 42]
}

fn text(counter: Counter) -> string {
    counter.calls += 10
    return "C"
}

// The Option must retain the struct's owned field after the array is dropped.
fn owned_array() -> Option<Record> {
    let values: [Record; 1] = [Record { text: "array".to_upper(), count: 7 }]
    return values.get(0)
}

fn owned_list() -> Option<Record> {
    var values: List<Record> = [Record { text: "list".to_upper(), count: 8 }]
    let answer: Option<Record> = values.get(0)
    values.clear()
    return answer
}

fn owned_text() -> Option<string> {
    let values: List<string> = ["text".to_upper()]
    return values.get(0)
}

fn main() {
    let huge: int = 9223372036854775807
    let fixed: [i32; 2] = [11, 22]
    io.println("array {fixed[1]} {fixed.get(0)} {fixed.get(1)} {fixed.get(-1)} {fixed.get(2)} {fixed.get(huge)} {fixed.len()}")
    let nested: [[i32; 2]; 2] = [[1, 2], [3, 4]]
    let pair: [i32; 2] = nested.get(1).expect("pair")
    io.println("nested {pair[0]} {pair[1]} {nested.get(2).is_none()}")
    let held: Record = owned_array().expect("array record")
    let listed: Record = owned_list().expect("list record")
    io.println("owned {held.text} {held.count} {listed.text} {listed.count} {owned_text().expect("text")}")

    let buffer: Bytes = new Bytes(2)
    buffer[0] = 0
    buffer[1] = 255
    io.println("bytes {buffer[0]} {buffer[1]} {buffer.get(0)} {buffer.get(1)} {buffer.get(-1)} {buffer.get(2)} {buffer.get(huge)} {buffer.len()}")
    let empty: Bytes = new Bytes(0)
    io.println("empty bytes {empty.get(0)} {empty.get(-1)} {empty.len()}")
    // Byte offsets, including continuation bytes, not character indexes.
    let utf8: string = "é"
    io.println("string {utf8.byte_at(0)} {utf8.get_byte(0)} {utf8.get_byte(1)} {utf8.get_byte(-1)} {utf8.get_byte(2)} {utf8.get_byte(huge)} {utf8.len()}")
    io.println("empty string {"".get_byte(0)}")
    io.println("nul string {buffer.to_string().get_byte(0)}")

    var list: List<int> = [31]
    io.println("list {list[0]} {list.get(0)} {list.get(-1)} {list.get(1)} {list.get(huge)} {list.len()}")
    list.clear()
    io.println("empty list {list.get(0)} {list.len()}")
    let optional: List<Option<int>> = [none, some(23)]
    io.println("nested option {optional.get(0)} {optional.get(1)} {optional.get(2)}")
    var map: Map<string, Option<int>> = {}
    map["none"] = none
    map["some"] = some(9)
    io.println("map {map["none"]} {map.get("none")} {map.get("some")} {map.get("missing")} {map.len()}")
    var ordered: OrderedMap<string, int> = {}
    ordered["a"] = 10
    io.println("ordered {ordered["a"]} {ordered.get("a")} {ordered.get("missing")} {ordered.len()}")

    let counter: Counter = new Counter()
    io.println("once {bytes(counter).get(index(counter))} {array(counter).get(index(counter))} {text(counter).get_byte(index(counter))} {counter.calls}")
    io.println("required once {bytes(counter)[index(counter)]} {counter.calls}")
    bytes(counter)[index(counter)] = index(counter)
    io.println("write once {counter.calls}")

    unsafe {
        let pointer: RawPtr<i32> = RawPtr.alloc(2)
        let view: Slice<i32> = Slice.from_raw(pointer, 2)
        view.set(0, 51)
        view[1] = 52
        io.println("slice {view[1]} {view.get(0)} {view.get(1)} {view.get(-1)} {view.get(2)} {view.get(huge)} {view.len()}")
        let empty_view: Slice<i32> = Slice.from_raw(RawPtr.null(), 0)
        io.println("empty slice {empty_view.get(0)} {empty_view.get(-1)}")
        pointer.free()

        let pointers: RawPtr<RawPtr<i32>> = RawPtr.alloc(1)
        pointers.write(RawPtr.null())
        let raw_view: Slice<RawPtr<i32>> = Slice.from_raw(pointers, 1)
        let found: Option<RawPtr<i32>> = raw_view.get(0)
        io.println("null pointer {found.is_some()} {found.expect("pointer").is_null()} {raw_view.get(1).is_none()}")
        pointers.free()

        let pairs: RawPtr<[i32; 2]> = RawPtr.alloc(1)
        pairs.write([61, 62])
        let pair_view: Slice<[i32; 2]> = Slice.from_raw(pairs, 1)
        let found_pair: [i32; 2] = pair_view.get(0).expect("slice pair")
        io.println("wide slice {found_pair[0]} {found_pair[1]} {pair_view.get(1).is_none()}")
        pairs.free()
    }
}
