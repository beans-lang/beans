// Selection mistakes the resolver and checker refuse. Every case here
// must fail to check.
import {parse} from std.encoding.json
import {nope} from std.encoding.json
import {println} from std.io

// the selection collides with a declaration of this package
fn parse(text: string) -> int { return 1 }

fn main() {
    // a native namespace's builtin is not a storable value
    let f: fn(string) = println
}
