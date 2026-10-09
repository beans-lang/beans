/*
ThreadSanitizer must report unsynchronized writes and ignore the atomic control.










*/

package main

import std.io
import std.os
import std.thread

fn main() {
    var mode: string = "race"
    let arguments: List<string> = os.args()
    if arguments.len() != 0 {
        mode = arguments[0]
    }
    let rounds: int = 200000
    unsafe {
        let cell: RawPtr<i64> = RawPtr.alloc(1)
        cell.write(0)
        if mode == "clean" {
            let first: Thread<int> = thread.spawn(fn() -> int {
                unsafe {
                    var index: int = 0
                    for index < rounds {
                        cell.atomic_fetch_add(1)
                        index += 1
                    }
                }
                return 0
            })
            let second: Thread<int> = thread.spawn(fn() -> int {
                unsafe {
                    var index: int = 0
                    for index < rounds {
                        cell.atomic_fetch_add(1)
                        index += 1
                    }
                }
                return 0
            })
            first.join()
            second.join()
            io.println("two threads shared one word atomically, joined {cell.atomic_load()}")
        } else {
            // A plain load and a plain store of the same eight bytes from two
            // threads with nothing ordering them. Both the load and the store
            // are instructions the emitter wrote, so TSan sees this pair only
            // when the definition around them says `sanitize_thread`.
            let first: Thread<int> = thread.spawn(fn() -> int {
                unsafe {
                    var index: int = 0
                    for index < rounds {
                        cell.write(cell.read() + 1)
                        index += 1
                    }
                }
                return 0
            })
            let second: Thread<int> = thread.spawn(fn() -> int {
                unsafe {
                    var index: int = 0
                    for index < rounds {
                        cell.write(cell.read() + 1)
                        index += 1
                    }
                }
                return 0
            })
            first.join()
            second.join()
            io.println("two threads raced on one word, joined {cell.read()}")
        }
        cell.free()
    }
}
