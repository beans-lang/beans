/*
Does ThreadSanitizer reach the code the compiler emitted? (issue #168)

`sanitize_thread` is a separate attribute from `sanitize_address` and was
missing for the same reason, so the answer could have differed and did not:
two OS threads writing one word four hundred thousand times with no
synchronisation at all was reported by nothing.

`race` is that program. `clean` is the same program with the one change that
makes it correct — an atomic read-modify-write instead of a plain one — and it
must stay silent, because a race detector that reports everything says as
little as one that reports nothing.
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
