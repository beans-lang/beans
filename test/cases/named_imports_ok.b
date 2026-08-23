// Named imports: `import {name, other as alias} from path` binds exactly
// the selection — functions, types, enums, sub-packages — and resolves at
// compile time like the module-qualified form. Every shape here must run
// identically interpreted and native.
import {println} from std.io
import {Value, Kind, parse, stringify, encode as to_json} from std.encoding.json
import {json} from std.encoding
import {json as j} from std.encoding

pub struct Point {
    pub x: int
    pub y: int
}

fn main() {
    println("hello named imports")
    let v: Value = parse("[1,2,3]").expect("parse")
    println(stringify(v).expect("render"))
    let p: Point = Point { x: 3, y: 4 }
    println(to_json(p).expect("alias encode"))
    println(json.encode(p).expect("sub-package"))
    println(j.encode(p).expect("sub-package alias"))
    let f: fn(string) -> Result<Value> = parse
    let again: Value = f("[true]").expect("value call")
    println(stringify(again).expect("render again"))
    if again.kind() == Kind.array { println("static works") }
    match again.kind() {
        array => { println("pattern works") }
        _ => { println("wrong") }
    }
}
