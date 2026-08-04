/*
Box<T> — one heap slot with exactly one owner.

What it is:
  `new Box(v)` allocates one slot and owns it. `get()` reads the value out,
  `set(v)` replaces it. The handle is move-only: binding or assigning an
  existing Box needs `move`, so two names can never own the same slot. After
  `move value`, `value` is dead until you give it a new Box. Function
  parameters borrow instead of moving, which is why `read(value)` below leaves
  `value` usable afterwards.

Use it when:
  - You want a heap value with a single clear owner and no reference counting.
  - You need to break an infinitely-sized recursive type (a struct that would
    otherwise contain itself); Box gives that edge a fixed pointer size.
  - A value is big and you want to pass a handle around instead of copying it.

Don't use it when:
  - Two or more owners must keep the value alive -> use Shared<T>.
  - You just want a local value -> plain `let`/`var` is cheaper, no heap.
  - You want many values in one region with stable handles -> use Arena<T>.

Note `get()` returns an owned copy, so `copy` below keeps saying "bean" after
the box is set to "beans".
*/

import std.io

fn read(value: Box<int>) -> int {
    return value.get()
}

fn main() {
    var value: Box<int> = new Box(7)
    io.println("box {read(value)}")
    value.set(11)

    let moved: Box<int> = move value
    value = new Box(13)
    io.println("moved {moved.get()} new {value.get()}")

    let text: Box<string> = new Box("bean")
    let copy: string = text.get()
    text.set("beans")
    io.println("text {copy} {text.get()}")
}
