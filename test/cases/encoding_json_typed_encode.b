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
}
