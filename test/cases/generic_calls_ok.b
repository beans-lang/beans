// Explicit type arguments on every call form, plus the inference the
// parser change unlocks. Each section prints stable lines the golden
// output locks for the interpreter, a debug build and a release build.
import std.io
import std.reflect

pub interface Greets {
    fn greeting() -> string
}

pub class Greeter {
    pub fn init() {}
    pub fn greeting() -> string { return "hello" }
}

pub class Crate<T> {
    pub item: T
    pub fn init(move item: T) { self.item = move item }
    pub fn get() -> T { return self.item }
    pub fn replace<U>(move other: U) -> U { return move other }
}

pub class Bind<S, I> {
    pub fn init() {}
    pub fn describe() -> string {
        return "{type_of(S).qualified_name()}={type_of(I).qualified_name()}"
    }
}

pub class Wires {
    pub rows: List<string>
    pub fn init() { self.rows = [] }
    // the DI shape: neither generic appears in the signature
    pub fn add<S, I>() {
        self.rows.push("{type_of(S).qualified_name()}<-{type_of(I).qualified_name()}")
    }
    // a generic method inferring from a generic argument
    pub fn adopt<S, I>(move binding: Bind<S, I>) -> string {
        return binding.describe()
    }
    pub static fn label<T>() -> string {
        return type_of(T).qualified_name()
    }
}

pub fn tell<T>() -> string { return type_of(T).qualified_name() }
pub fn ident<T>(move value: T) -> T { return move value }
pub fn pick<A, B>(move left: A, move right: B) -> A { return move left }
pub fn fallback<T>(move value: T, count: int = 2) -> string {
    return "{type_of(T).qualified_name()}x{count}"
}

fn check(a: bool, b: bool) -> string { return "{a}|{b}" }

fn main() {
    // 1. free functions
    io.println(tell<int>())
    io.println(tell<Map<string, List<int>>>())
    io.println(ident<string>("kept"))
    // partial: A written, B inferred from the argument
    io.println(pick<string>("first", 9))
    // defaults still fill behind an explicit argument
    io.println(fallback<bool>(true))

    // 2. static methods
    io.println(Wires.label<Greeter>())

    // 3. instance methods, non-generic owner, generics absent from the
    // signature entirely
    let wires: Wires = new Wires()
    wires.add<Greets, Greeter>()
    wires.add<Crate<int>, Wires>()
    io.println(wires.rows[0])
    io.println(wires.rows[1])

    // 4. instance methods on a generic owner
    let crate: Crate<int> = new Crate<int>(7)
    io.println(crate.replace<string>("swapped"))
    io.println(crate.get())

    // 5. a generic method infers from a generic argument — no explicit
    // type arguments anywhere
    io.println(wires.adopt(new Bind<Greets, Greeter>()))

    // 6. the disambiguation rule: parenthesized comparisons stay
    // comparisons, and the bare form reads as a generic call
    let a: int = 1
    let b: int = 2
    let c: int = 3
    let d: int = 2
    io.println(check((a < b), (c > d)))

    // 7. nested generic arguments through every form at once
    let deep: Crate<List<string>> = new Crate<List<string>>(["x"])
    let swapped: Map<string, int> =
        deep.replace<Map<string, int>>({"k": 5})
    io.println(swapped["k"])

    // 8. an Order bound promises the comparison operators inside the body,
    // not just sort/max/min on the outside
    io.println("{smaller(1, 2)}|{smaller("b", "a")}|{smaller(1.5, 2.5)}")
    io.println("{largest([3, 9, 4], 0)}|{largest(["a", "z", "m"], "")}")
    let ranked: Ranked<int, string> =
        new Ranked<int, string>(5, "five")
    io.println("{ranked.before(9)}|{ranked.before(1)}")
    io.println("done")
}

fn smaller<T implements Order>(a: T, b: T) -> bool {
    return a < b
}

fn largest<T implements Order>(xs: List<T>, seed: T) -> T {
    var best: T = seed
    for item: T in xs {
        if item > best {
            best = item
        }
    }
    return best
}

class Ranked<K implements Order, V> {
    key: K
    value: V
    fn init(key: K, value: V) {
        self.key = key
        self.value = value
    }
    fn before(other: K) -> bool {
        return self.key <= other
    }
}
