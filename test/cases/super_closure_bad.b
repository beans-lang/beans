// A closure is its own function and carries no receiver, so `super` has
// nothing to stand behind. All three halves used to disagree: the checker
// accepted this, the interpreter panicked at run time, and the native backend
// refused to build it. One refusal now, from the place that can name the fix.
package main

class Base {
    pub fn init() {}

    pub fn name(key: int) -> string {
        return "base{key}"
    }
}

class Sub extends Base {
    pub fn init() {
        super.init()
    }

    pub fn via_closure() -> string {
        let call: fn() -> string =
            fn() -> string { return super.name(9) }
        return call()
    }
}

fn main() {}
