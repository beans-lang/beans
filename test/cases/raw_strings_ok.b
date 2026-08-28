// Raw literals: bytes, not syntax. Every shape that used to need escaping —
// a route template, a regex, a Windows path, a printf format, embedded JSON —
// written the way its own reader spells it, and proved equal to the escaped
// spelling so the two forms cannot drift.
import std.io
import std.reflect

@target(value: ["method", "type"])
@retention(value: "runtime")
pub annotation route {
    path: string
}

const TEMPLATE: string = r"/users/{id}/posts/{slug}"

class Api {
    @route(path: r"/users/{id}")
    pub fn show(id: int) -> int { return id }

    @route(path: TEMPLATE)
    pub fn nested() -> int { return 0 }
}

fn shapes() {
    io.println(r"/users/{id}")
    io.println(r"\d+")
    io.println(r"\{2,3\}")
    io.println(r"C:\Users\bin\beansc.exe")
    io.println(r"%-10s|%05.2f\n")
    io.println(r#"{"name": "beans", "ok": true}"#)
    io.println(r##"a "#" inside"##)
    io.println(r###"and a "## here"###)
    io.println(r"")
    io.println(r#""#)
}

// A raw literal may span lines: the terminator is explicit.
fn multiline() {
    let block: string = r"first
  second\t{not a slot}
third"
    io.println(block)
    io.println("{block.len()} {block.lines().len()}")
}

// The two spellings are one string.
fn equality() {
    io.println("{r"/users/{id}" == "/users/\{id\}"}")
    io.println("{r"\d+" == "\\d+"}")
    io.println("{r#"say "hi""# == "say \"hi\""}")
    io.println("{r"" == ""} {r"a".len()} {r"\n".len()} {"\n".len()}")
    var seen: Map<string, int> = {}
    seen[r"\{"] = 1
    io.println("{seen.contains_key("\\\{")}")
}

fn kind(value: string) -> string {
    return match value {
        r"\d+" => "digits",
        r"/users/{id}" | r"/users/{name}" => "user route",
        r#"a,b"# => "comma",
        r#"quoted"value"# => "quoted",
        _ => "other",
    }
}

fn patterns() {
    io.println(kind("\\d+"))
    io.println(kind("/users/\{id\}"))
    io.println(kind("/users/\{name\}"))
    io.println(kind("a,b"))
    io.println(kind("quoted\"value"))
    io.println(kind("nope"))
}

fn annotations() {
    let shape: reflect.Type = type_of(Api)
    for method: reflect.Method in shape.methods() {
        for annotation: reflect.Annotation in method.annotations() {
            match annotation.argument("path") {
                some(argument) => {
                    io.println("{method.name()} = {argument.value().text()}")
                }
                none => {}
            }
        }
    }
}

fn main() {
    shapes()
    multiline()
    equality()
    patterns()
    annotations()
}
