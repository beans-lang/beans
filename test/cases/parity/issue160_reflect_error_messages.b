// #160: the two backends must answer the same bytes for the same reflection
// failure. They cannot, structurally, share the answer: the tree interpreter
// stores a message literal at each failure site, while a native build asks
// `beans_reflect_error_message()`, which maps the error code to a fixed string
// in C. Two copies of one table, and one of them was wrong — case 3 was built
// as `str_make("receiver type does not match", 27)` for a 28-byte message, so
// the native runtime dropped the trailing `h` and the interpreter did not.
//
// A case that provoked one failure would have caught that one byte and
// nothing else, so this provokes every reflection error a program can reach
// and prints the kind, the message and the message's byte length for each.
// The length is printed on purpose: a truncated message and an intact one
// differ by one byte that no eye finds in a diff, and it is the length that
// says which side is wrong.
//
// Several shapes reach each code, and they are all here: a wrong receiver is
// reached through a field read, a field write, an instance method, a static
// method called on an instance and an instance method called statically; a
// bad argument through a field write and through two different signatures;
// a bad count both under and over, on a method and on an initializer.
//
// The receivers carry arc markers, so this also holds the failing paths to
// the lifetime rule: a reflective call that refuses still owns the receiver
// it was handed, and must release it exactly once. Thirteen objects are
// boxed into reflect values across the run.
package main

import std.io
import std.reflect

class Loud {
    tag: string = ""

    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }

    fn deinit() { io.println("arc-{self.tag}") }
}

pub class Alpha {
    pub label: int
    priv hidden: int
    pub witness: Option<Loud> = none

    pub fn init(label: int) {
        self.label = label
        self.hidden = 0
    }

    pub fn name() -> string { return "alpha" }
    pub fn widen(step: int) -> int { return step + self.label }
    pub fn between(low: int, high: int) -> int { return low + high }
    pub fn wrap<T>(item: T) -> T { return item }
    pub static fn origin() -> int { return 0 }
    priv fn secret() -> int { return self.hidden }
}

pub class Beta {
    pub label: int
    pub fn init() { self.label = 1 }
    pub fn name() -> string { return "beta" }
}

pub class Pair {
    pub left: int
    pub right: int
    pub fn init(left: int, right: int) {
        self.left = left
        self.right = right
    }
}

fn slug(kind: reflect.ErrorKind) -> string {
    return match kind {
        missing => "missing",
        inaccessible => "inaccessible",
        receiver_type => "receiver_type",
        value_type => "value_type",
        unsupported => "unsupported",
        argument_count => "argument_count",
        failed => "failed",
    }
}

fn say(name: string, kind: reflect.ErrorKind, message: string) {
    io.println("{name}: {slug(kind)} | {message} | {message.len()}")
}

fn value_result(name: string,
                outcome: Result<reflect.Value, reflect.ReflectError>) {
    match outcome {
        ok(v) => { io.println("{name}: ok") }
        err(e) => { say(name, e.kind(), e.message()) }
    }
}

fn bool_result(name: string,
               outcome: Result<bool, reflect.ReflectError>) {
    match outcome {
        ok(v) => { io.println("{name}: ok {v}") }
        err(e) => { say(name, e.kind(), e.message()) }
    }
}

fn alpha_value(tag: string) -> reflect.Value {
    var a: Alpha = new Alpha(7)
    a.witness = some(new Loud(tag))
    return reflect.value(move a)
}

fn beta_value() -> reflect.Value { return reflect.value(new Beta()) }

fn method(owner: reflect.Type, name: string) -> reflect.Method {
    return owner.method(name).expect(name)
}

fn main() {
    let alpha: reflect.Type = type_of(Alpha)
    let beta: reflect.Type = type_of(Beta)
    let pair: reflect.Type = type_of(Pair)

    // The one path that works, so a wholesale breakage of reflection reads as
    // a failure here rather than as seven identical error lines.
    value_result("ok field read",
        alpha.field("label").expect("label").get(alpha_value("ok")))
    value_result("ok method call",
        method(alpha, "name").call(alpha_value("ok-call"), []))

    // missing: `init` and `deinit` are registered names that reflection
    // refuses to treat as members, and `deinit` does not even yield a
    // descriptor. Both answers are compared.
    value_result("missing init",
        method(alpha, "init").call(alpha_value("missing"), [reflect.value(1)]))
    match alpha.method("deinit") {
        some(m) => { io.println("missing deinit: has a descriptor") }
        none => { io.println("missing deinit: no descriptor") }
    }

    // inaccessible: a private field, read and written, and a private method.
    value_result("private field get",
        alpha.field("hidden").expect("hidden").get(alpha_value("priv-get")))
    bool_result("private field set",
        alpha.field("hidden").expect("hidden")
            .set(alpha_value("priv-set"), reflect.value(3)))
    value_result("private method",
        method(alpha, "secret").call(alpha_value("priv-call"), []))

    // receiver_type: five ways to hand an operation the wrong receiver.
    value_result("field get wrong receiver",
        alpha.field("label").expect("label").get(beta_value()))
    bool_result("field set wrong receiver",
        alpha.field("label").expect("label").set(beta_value(), reflect.value(5)))
    value_result("method wrong receiver",
        method(alpha, "name").call(beta_value(), []))
    value_result("static called on an instance",
        method(alpha, "origin").call(alpha_value("static-inst"), []))
    value_result("instance called statically",
        method(alpha, "name").call_static([]))

    // value_type: a field written with the wrong type, and arguments of the
    // wrong type at one- and two-parameter signatures.
    bool_result("field set wrong value",
        alpha.field("label").expect("label")
            .set(alpha_value("bad-value"), reflect.value("seven")))
    value_result("one argument of the wrong type",
        method(alpha, "widen").call(alpha_value("bad-arg1"),
                                    [reflect.value("step")]))
    value_result("second argument of the wrong type",
        method(alpha, "between").call(alpha_value("bad-arg2"),
                                      [reflect.value(1), reflect.value(true)]))

    // unsupported: a method with its own type parameter has no single body to
    // call, so the operation is refused rather than guessed at.
    value_result("generic method",
        method(alpha, "wrap").call(alpha_value("generic"), [reflect.value(1)]))

    // argument_count: too few and too many, at a method and at an
    // initializer, so neither direction of the comparison is untested.
    value_result("too few arguments",
        method(alpha, "between").call(alpha_value("few"), [reflect.value(1)]))
    value_result("too many arguments",
        method(alpha, "widen").call(alpha_value("many"),
                                    [reflect.value(1), reflect.value(2)]))
    value_result("initializer, too few",
        pair.initializer().expect("init").call([reflect.value(1)]))
    value_result("initializer, too many",
        beta.initializer().expect("init").call([reflect.value(1)]))
}
