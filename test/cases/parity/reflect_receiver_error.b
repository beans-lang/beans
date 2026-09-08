// #160: native reflection built the receiver mismatch message with an
// explicit length one byte shorter than the literal. Pin the kind, complete
// message and length while the parity gate compares all three backends.
package main

import std.io
import std.reflect

class Expected {
    fn init() {}
    pub fn value() -> int { return 1 }
}

class Other {
    fn init() {}
}

fn main() {
    let method: reflect.Method =
        type_of(Expected).method("value").expect("Expected.value")
    let other: Other = new Other()
    let receiver: reflect.Value = reflect.value(move other)
    match method.call(receiver, []) {
        ok(_) => { panic("receiver mismatch call succeeded") }
        err(problem) => {
            match problem.kind() {
                receiver_type => {}
                _ => { panic("wrong reflection error kind") }
            }
            let message: string = problem.message()
            if message != "receiver type does not match" {
                panic("wrong reflection error message")
            }
            if message.len() != 28 {
                panic("wrong reflection error message length")
            }
            io.println("receiver_type: receiver type does not match (28)")
        }
    }
}
