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

// A raw literal nested in an interpolation is bytes to the walker too: a
// hashed body that holds a quote before a brace must not split the slot at
// that brace, and a colon in a raw body is not a format separator. The
// naive scanner splits these at the wrong place; only the raw-aware walkers
// in the checker and both backends agree.
fn nested_in_interpolation() {
    io.println("[{r#"a"}b"#}]")
    io.println("[{r"x:y"}]")
    io.println("[{r#"p"}:q"#}]")
    io.println("len {r#"a"}b"#.len()}")
    io.println("fmt {r"z"}|{42:4}")
}

// Where a slot's expression ends and its format spec begins is one walk,
// asked by the checker, the tree interpreter and the LLVM emitter. When the
// emitter counted only braces it stopped at the first `:` at brace depth 1
// — a closure parameter's type, a map key, a named argument — and dropped
// the real spec, so the two compilers printed different widths for one
// literal. Every line here holds a `:` that is not a separator.
fn twice(v: int) -> int { return v * 2 }
fn call(f: fn(int) -> int, v: int) -> int { return f(v) }

fn format_specs() {
    io.println("[{call(fn(x: int) -> int { return x - 1 }, 9):6}]")
    io.println("[{call(fn(x: int) -> int { return x + 1 }, 9):-6}]")
    io.println("[{call(fn(x: int) -> int { return x }, 4)}]")
    let table: Map<string, int> = {"a:b": 3}
    io.println("[{table["a:b"]:4}]")
    io.println("[{twice(3):04}]")
    io.println("[{r"a:b":8}]")
    io.println("[{r#"p"}:q"#:8}]")
    let ratio: f64 = 1.5
    io.println("[{ratio:8.3}] [{ratio:-8.1}]")
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
    nested_in_interpolation()
    format_specs()
    annotations()
}
