import std.io
import std.encoding.json

struct Address {
    pub city: string
    pub zip: u32
}

struct Numbers {
    pub s8: i8
    pub s16: i16
    pub s32: i32
    pub s64: int
    pub u8_value: u8
    pub u16_value: u16
    pub u32_value: u32
    pub u64_value: u64
    pub small: f32
    pub values: List<i16>
}

struct Tiny {
    pub code: i16
}

@json.naming(value: json.Naming.camel_case)
struct User {
    pub user_id: u64

    @json.name(value: "fullName")
    @json.alias(value: ["name"])
    pub display_name: string

    pub active: bool
    pub score: f64
    pub note: Option<string>
    pub alternate: Option<Address>
    pub links: Option<List<string>>
    pub address: Address
    pub tags: List<string>

    @json.ignore
    pub cache: string = "hidden"
}

fn filled(byte: int, n: int) -> string {
    let b: Bytes = new Bytes(0)
    b.reserve(n)
    for i: int in 0..n { b.push(byte) }
    return b.to_string()
}

fn escapes_string() -> string {
    let b: Bytes = new Bytes(0)
    b.push(34)   // "
    b.push(92)   // backslash
    b.push(10)   // \n
    b.push(9)    // \t
    b.push(13)   // \r
    b.push(1)    // control -> 
    b.push(31)   // control -> 
    b.push(97)   // a
    return b.to_string()
}

// A UTF-16 surrogate encoded as three UTF-8 bytes: never valid UTF-8. Both
// the native writers and the interpreter must refuse it.
fn surrogate_string() -> string {
    let b: Bytes = new Bytes(0)
    b.push(111)   // o
    b.push(237)
    b.push(160)
    b.push(128)
    b.push(107)   // k
    return b.to_string()
}

fn fold(data: Bytes) -> u64 {
    var h: u64 = 14695981039346656037
    for i: int in 0..data.len() {
        h = (h ^ (data.get(i) as u64)) * 1099511628211
    }
    return h
}

// encode_into must write the same bytes `encode` did, after whatever `target`
// held, and return that many. Small cases print the appended tail so the
// golden pins the exact bytes on both backends; the head is checked to prove
// the prefix is left alone.
fn into_show(tag: string, expect: string, prefix: string, target: Bytes,
             appended: Result<int>) {
    let prefix_bytes: Bytes = Bytes.from(prefix)
    let expect_bytes: Bytes = Bytes.from(expect)
    match appended {
        ok(count) => {
            let head: Bytes = target.slice(0, prefix_bytes.len())
            let tail: Bytes = target.slice(prefix_bytes.len(), target.len())
            io.println("{tag}: n={count} prefix_ok={head == prefix_bytes} eq={tail == expect_bytes && count == expect_bytes.len()} :: {tail.to_string()}")
        }
        err(problem) => {
            io.println("{tag}: err {problem.kind}: {problem.msg} :: {target.to_string()}")
        }
    }
}

// A large or many-record case: prove byte-for-byte equality with `encode` and
// summarise the tail with a checksum instead of dumping it into the golden.
fn into_big(tag: string, expect: string, prefix: string, target: Bytes,
            appended: Result<int>) {
    let prefix_bytes: Bytes = Bytes.from(prefix)
    let expect_bytes: Bytes = Bytes.from(expect)
    match appended {
        ok(count) => {
            let head: Bytes = target.slice(0, prefix_bytes.len())
            let tail: Bytes = target.slice(prefix_bytes.len(), target.len())
            io.println("{tag}: n={count} prefix_ok={head == prefix_bytes} eq={tail == expect_bytes && count == expect_bytes.len()} len={tail.len()} sum={fold(tail)}")
        }
        err(problem) => {
            io.println("{tag}: err {problem.kind}: {problem.msg}")
        }
    }
}

fn main() {
    let absent: Option<string> = none
    let user: User = User {
        user_id: 7,
        display_name: "Ada \"A\"",
        active: true,
        score: 1.5,
        note: absent,
        alternate: some(Address { city: "Ipoh", zip: 30000 }),
        links: some(["web"]),
        address: Address { city: "KL", zip: 50000 },
        tags: ["one", "two"],
    }
    io.println(json.encode(user).expect("encode"))
    io.println(json.encode_pretty(user, "  ").expect("pretty"))
    io.println(json.encode([move user]).expect("list"))
    let empty: List<User> = []
    io.println(json.encode(empty).expect("empty list"))
    io.println(json.encode(Numbers {
        s8: -8,
        s16: -1600,
        s32: -320000,
        s64: -6400000000,
        u8_value: 8,
        u16_value: 1600,
        u32_value: 320000,
        u64_value: 6400000000,
        small: 0.25,
        values: [-2, 300],
    }).expect("numbers"))
    io.println(json.encode([
        Tiny { code: -3 },
        Tiny { code: 400 },
    ]).expect("tiny list"))
    match json.encode_pretty(
            User {
                user_id: 1,
                display_name: "x",
                active: false,
                score: 0.0,
                note: none,
                alternate: none,
                links: none,
                address: Address { city: "x", zip: 1 },
                tags: [],
            }, "\t") {
        ok(_) => io.println("indent: accepted"),
        err(error) => io.println("indent: {error.kind}"),
    }

    io.println("-- encode_into --")

    // A struct, appended into an empty buffer and into one already holding a
    // prefix. The prefix must survive; the tail must equal encode(value).
    let one: User = User {
        user_id: 7,
        display_name: "Ada \"A\"",
        active: true,
        score: 1.5,
        note: none,
        alternate: some(Address { city: "Ipoh", zip: 30000 }),
        links: some(["web"]),
        address: Address { city: "KL", zip: 50000 },
        tags: ["one", "two"],
    }
    let one_json: string = json.encode(one).expect("one")
    let e0: Bytes = new Bytes(0)
    into_show("struct_empty", one_json, "", e0, json.encode_into(one, e0))
    let ep: Bytes = Bytes.from("BODY=")
    into_show("struct_prefix", one_json, "BODY=", ep,
              json.encode_into(one, ep))

    // Appending twice in a row into the same target concatenates.
    let dbl: Bytes = Bytes.from(">>")
    let dn1: int = json.encode_into(one, dbl).expect("dn1")
    let dn2: int = json.encode_into(one, dbl).expect("dn2")
    let dtail: Bytes = dbl.slice(2, dbl.len())
    io.println("double: n1={dn1} n2={dn2} eq={dtail == Bytes.from("{one_json}{one_json}")} :: {dbl.to_string()}")

    // Root lists at n = 0, 1, 2.
    let l0: List<Tiny> = []
    let b0: Bytes = new Bytes(0)
    into_show("list0", json.encode(l0).expect("l0"), "", b0,
              json.encode_into(l0, b0))
    let l1: List<Tiny> = [Tiny { code: -3 }]
    let b1: Bytes = new Bytes(0)
    into_show("list1", json.encode(l1).expect("l1"), "", b1,
              json.encode_into(l1, b1))
    let l2: List<Tiny> = [Tiny { code: -3 }, Tiny { code: 400 }]
    let b2: Bytes = new Bytes(0)
    into_show("list2", json.encode(l2).expect("l2"), "", b2,
              json.encode_into(l2, b2))

    // A thousand records: byte-identical to encode, summarised.
    var l1000: List<Tiny> = []
    for i: int in 0..1000 { l1000.push(Tiny { code: (i - 500) as i16 }) }
    let b1000: Bytes = Bytes.from("P:")
    into_big("list1000", json.encode(l1000).expect("l1000"), "P:", b1000,
             json.encode_into(l1000, b1000))

    // Empty strings, and a field full of escapes and control bytes.
    let empt: Address = Address { city: "", zip: 0 }
    let be: Bytes = new Bytes(0)
    into_show("empty_str", json.encode(empt).expect("empt"), "", be,
              json.encode_into(empt, be))
    let esc: Address = Address { city: escapes_string(), zip: 2 }
    let bes: Bytes = new Bytes(0)
    into_show("escapes", json.encode(esc).expect("esc"), "", bes,
              json.encode_into(esc, bes))

    // A one-megabyte string field: the target's backing must grow past its
    // doubling boundaries and stay byte-identical to encode.
    let mib: Address = Address { city: filled(97, 1048576), zip: 9 }
    let bm: Bytes = Bytes.from("Z")
    into_big("mib_string", json.encode(mib).expect("mib"), "Z", bm,
             json.encode_into(mib, bm))

    // A NaN float refuses exactly like encode, on both backends, and leaves
    // the target's existing bytes untouched.
    let bad: User = User {
        user_id: 1,
        display_name: "x",
        active: false,
        score: 0.0 / 0.0,
        note: none,
        alternate: none,
        links: none,
        address: Address { city: "x", zip: 1 },
        tags: [],
    }
    let bn: Bytes = Bytes.from("KEEP")
    match json.encode_into(bad, bn) {
        ok(count) => io.println("nan_into: unexpected ok {count}"),
        err(error) =>
            io.println("nan_into: err {error.kind}: {error.msg} :: {bn.to_string()}"),
    }
    match json.encode(bad) {
        ok(_) => io.println("nan_encode: unexpected ok"),
        err(error) => io.println("nan_encode: err {error.kind}: {error.msg}"),
    }

    // Invalid UTF-8 refuses on both backends, identically to encode, and
    // leaves the target's existing bytes untouched.
    let sur: Address = Address { city: surrogate_string(), zip: 3 }
    let sb: Bytes = Bytes.from("HOLD")
    match json.encode_into(sur, sb) {
        ok(count) => io.println("bad_utf8_into: unexpected ok {count}"),
        err(error) =>
            io.println("bad_utf8_into: err {error.kind}: {error.msg} :: {sb.to_string()}"),
    }
    match json.encode(sur) {
        ok(_) => io.println("bad_utf8_encode: unexpected ok"),
        err(error) => io.println("bad_utf8_encode: err {error.kind}: {error.msg}"),
    }
}
