import std.io
import std.encoding.json

@json.naming(value: json.Naming.camel_case)
struct TypedUser {
    pub user_id: u64

    @json.alias(value: ["name", "legacyName"])
    pub display_name: string

    pub active: bool
    pub delta: i8
    pub ratio: f32
    pub note: Option<string>
    pub age: Option<u16>

    @json.ignore
    pub cached_name: string = "cache"
}

struct FastRow {
    pub id: u64
    pub name: string
    pub note: Option<string>
}

fn from_text(text: string) -> Result<TypedUser> {
    return json.decode(text)
}

fn from_bytes(data: Bytes) -> Result<TypedUser> {
    return json.decode_bytes(data)
}

fn from_owned_bytes(move data: Bytes) -> Result<TypedUser> {
    return json.decode_bytes_in_place(move data)
}

fn from_owned_text(text: string) -> Result<TypedUser> {
    let data: Bytes = Bytes.from(text)
    return from_owned_bytes(move data)
}

fn list_from_text(text: string) -> Result<List<TypedUser>> {
    return json.decode(text)
}

fn show_fast(label: string, text: string) {
    let result: Result<FastRow> = json.decode(text)
    match result {
        ok(row) => {
            var note: string = "none"
            match row.note {
                some(value) => { note = value }
                none => {}
            }
            io.println("{label}: {row.id} {row.name} {note}")
        }
        err(error) => io.println("{label}: {error.kind}"),
    }
}

fn show_fast_owned(label: string, text: string) {
    let data: Bytes = Bytes.from(text)
    let result: Result<FastRow> =
        json.decode_bytes_in_place(move data)
    match result {
        ok(row) => io.println("{label}: {row.id} {row.name}"),
        err(error) => io.println("{label}: {error.kind}"),
    }
}

fn show(label: string, result: Result<TypedUser>) {
    match result {
        ok(user) => {
            var note: string = "none"
            match user.note {
                some(value) => { note = value }
                none => {}
            }
            var age: int = -1
            match user.age {
                some(value) => { age = value as int }
                none => {}
            }
            io.println("{label}: {user.user_id} {user.display_name} {user.active} {user.delta} {user.ratio} {note} {age} {user.cached_name}")
        }
        err(error) => io.println("{label}: {error.kind}"),
    }
}

fn main() {
    show("text", from_text("\{\"userId\":7,\"name\":\"Ada\",\"active\":true,\"delta\":-8,\"ratio\":1.5,\"note\":\"ok\",\"age\":42\}"))
    show("nulls", from_text("\{\"userId\":8,\"displayName\":\"Lin\",\"active\":false,\"delta\":0,\"ratio\":2,\"note\":null\}"))
    show("bytes", from_bytes(Bytes.from("\{\"userId\":9,\"legacyName\":\"Jo\",\"active\":true,\"delta\":127,\"ratio\":0.25\}")))
    show("in place", from_owned_text("\{\"userId\":11,\"name\":\"Mia\",\"active\":true,\"delta\":3,\"ratio\":0.5\}"))
    show("unknown", from_text("\{\"userId\":1,\"displayName\":\"x\",\"active\":true,\"delta\":0,\"ratio\":1,\"extra\":1\}"))
    show("duplicate", from_text("\{\"userId\":1,\"displayName\":\"x\",\"name\":\"y\",\"active\":true,\"delta\":0,\"ratio\":1\}"))
    show("missing", from_text("\{\"userId\":1,\"displayName\":\"x\",\"active\":true,\"delta\":0\}"))
    show("range", from_text("\{\"userId\":1,\"displayName\":\"x\",\"active\":true,\"delta\":128,\"ratio\":1\}"))
    show("null", from_text("\{\"userId\":null,\"displayName\":\"x\",\"active\":true,\"delta\":0,\"ratio\":1\}"))
    show("root", from_text("[]"))
    match list_from_text("[\{\"userId\":10,\"displayName\":\"A\",\"active\":true,\"delta\":1,\"ratio\":1\},\{\"userId\":20,\"name\":\"B\",\"active\":false,\"delta\":2,\"ratio\":2,\"age\":5\}]") {
        ok(users) => {
            var total: u64 = 0
            for user: TypedUser in users { total += user.user_id }
            io.println("list: {users.len()} {total}")
        }
        err(error) => io.println("list: {error.kind}"),
    }
    match list_from_text("[]") {
        ok(users) => io.println("empty list: {users.len()}"),
        err(error) => io.println("empty list: {error.kind}"),
    }
    match list_from_text("[1]") {
        ok(_) => io.println("bad list: accepted"),
        err(error) => io.println("bad list: {error.kind}"),
    }
    show_fast("fast", "\{\"id\":1,\"name\":\"A\",\"note\":null\}")
    show_fast("fast shuffled", "\{\"name\":\"B\",\"id\":2\}")
    show_fast("fast duplicate", "\{\"id\":3,\"name\":\"C\",\"name\":\"D\"\}")
    show_fast("fast partial", "\{\"id\":4,\"name\":\"E\",\"extra\":1\}")
    show_fast_owned("fast in place", "\{\"id\":7,\"name\":\"H\"\}")
    let fast_list: Result<List<FastRow>> = json.decode("[\{\"id\":5,\"name\":\"F\"\},\{\"id\":6,\"name\":\"G\",\"extra\":1\}]")
    match fast_list {
        ok(_) => io.println("fast bad list: accepted"),
        err(error) => io.println("fast bad list: {error.kind}"),
    }
}
