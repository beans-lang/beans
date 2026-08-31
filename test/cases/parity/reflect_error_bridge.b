// #46, the acceptance case: `std.reflect` answers `Result<T, ReflectError>`,
// so before the fix no `?` in an ordinary `Result<T>` function could call
// reflection at all — std failed its own users. `ReflectError` now offers
// `fn to_error() -> Error`, so a reflection failure crosses into a plain
// `Result<T>` carrying the reflect kind as the error slug.
//
// This lives in the parity gate because the whole claim is that both backends
// take the same conversion: the interpreter used to propagate the wrong error
// type here while the native backend refused it in the emitter. No markers —
// the reflect internals are not ours to tag — but the compared answers cover
// both the ok path (no conversion) and the err path (conversion runs).
package main

import std.io
import std.reflect

class Point {
    pub x: int
    priv secret: int
    fn init(x: int, secret: int) {
        self.x = x
        self.secret = secret
    }
}

// `field.get(...)?` is `Result<Value, ReflectError>` reached through a plain
// `Result<int>` function. On a readable field the `?` succeeds and no
// conversion runs; on a private field reflect answers err and the `?` turns
// the ReflectError into an Error and propagates it.
fn read_field(name: string) -> Result<int> {
    let p: Point = new Point(7, 9)
    let t: reflect.Type = type_of(Point)
    let field: reflect.Field = t.field(name).expect("field")
    let boxed: reflect.Value = reflect.value(move p)
    let value: reflect.Value = field.get(boxed)?
    return ok((value as? int).expect("int"))
}

fn show(name: string) {
    match read_field(name) {
        ok(n) => { io.println("{name} = {n}") }
        err(e) => { io.println("{name} err kind={e.kind}") }
    }
}

fn main() {
    show("x")
    show("secret")
}
