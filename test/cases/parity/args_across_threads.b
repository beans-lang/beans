// os.args() is a fact about the process, and the process does not stop
// having a command line because a worker asked. The tree interpreter built
// a spawned thread's interpreter with an empty argument list, so the same
// checked program answered the real arguments natively and nothing under
// `beansc run` — silently, in the direction that survives the edit loop
// (#186).
//
// The case must be run WITH arguments: with none both backends answer 0 and
// it passes while proving nothing. It prints the arguments themselves and
// not only how many there are, because a count agrees for the wrong reason
// as soon as the worker gets *some* list.
package main

import std.io
import std.os
import std.thread

fn joined(label: string, seen: Thread<string>) {
    io.println("{label}: {seen.join()}")
}

fn rendered() -> string {
    var out: string = ""
    var index: int = 0
    for value: string in os.args() {
        out = "{out}[{index}={value}]"
        index += 1
    }
    return "{os.args().len()} {out}"
}

fn main() {
    io.println("main: {rendered()}")

    // One worker.
    joined("worker", thread.spawn(fn() -> string {
        return rendered()
    }))

    // Several at once: a fix that hands the list to the first spawn only
    // would still pass with one.
    var handles: List<Thread<string>> = []
    var spawned: int = 0
    for spawned < 3 {
        handles.push(thread.spawn(fn() -> string {
            return rendered()
        }))
        spawned += 1
    }
    var index: int = 0
    for index < handles.len() {
        io.println("fanout {index}: {handles[index].join()}")
        index += 1
    }

    // A thread spawned from a thread: the worker's own interpreter has to
    // carry the arguments on, not merely have been handed them once.
    joined("nested", thread.spawn(fn() -> string {
        let inner: Thread<string> = thread.spawn(fn() -> string {
            return rendered()
        })
        return "outer {rendered()} inner {inner.join()}"
    }))

    // A fiber runs on the interpreter that brewed it; kept here so the two
    // concurrency shapes are read from one place.
    let child: Brew<string> = brew rendered()
    io.println("brewed: {child.join()}")
}
