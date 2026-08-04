/*
Shared<T> and Weak<T> — many owners, and an observer that owns nothing.

Shared<T>:
  A thread-safe shared-ownership handle around one control block. Copying the
  handle (`let alias = shared`) adds a strong owner; the value lives until the
  last strong handle dies. `get()` returns a copy of the value. Shared<T> and
  Weak<T> are Send and Sync only when T is — which is what lets `number` below
  cross into a spawned thread.

Weak<T>:
  Observes the same control block without keeping the value alive.
  `shared.downgrade()` makes one. `upgrade()` returns Option<Shared<T>>: Some
  while a strong owner still exists, None once they are all gone. The upgrade
  uses an atomic compare/exchange, so it can never revive a dead value.
  `expired()` asks the same question without taking a handle.

Use Shared when:
  - A value has no single obvious owner — a cache, a config, a connection
    pool read by several places.
  - You need to hand a value to another thread and both sides keep using it.
  - You need the value dropped exactly once, whenever the last user is done.

Use Weak when:
  - You want to break a reference cycle. Two Shared values pointing at each
    other never reach zero and never drop; make one side Weak, same as C++
    shared_ptr/weak_ptr. The local-class cycle collector does not trace through
    explicit Shared control blocks, so this one is on you.
  - You want a back-pointer (child -> parent, observer -> subject) that must
    not keep the target alive.
  - You are caching something and would rather see it disappear than pin it.

Don't use Shared when a single owner is obvious — Box<T> is cheaper, no atomic
refcount. And for mutation across threads, reach for Mutex<T>; Shared gives you
shared ownership, not a lock.

The two builders below show the whole point: `build_weak` returns a Weak whose
value is already gone by the time main looks at it, so `upgrade()` gives None
and Token's `deinit` has already run.
*/

import std.io
import std.thread

class Token {
    value: int

    fn init(value: int) { self.value = value }

    fn deinit() { io.println("drop {self.value}") }
}

fn build_weak() -> Weak<string> {
    let shared: Shared<string> = new Shared("beans")
    let alias: Shared<string> = shared
    let weak: Weak<string> = shared.downgrade()
    io.println("{shared.get()} {alias.get()} {weak.expired()}")
    io.println(weak.upgrade().expect("live").get())
    return weak
}

fn build_dead_token() -> Weak<Token> {
    let shared: Shared<Token> = new Shared(new Token(7))
    return shared.downgrade()
}

fn main() {
    let weak: Weak<string> = build_weak()
    io.println("{weak.expired()} {weak.upgrade().is_none()}")

    let dead: Weak<Token> = build_dead_token()
    io.println("{dead.expired()} {dead.upgrade().is_none()}")

    let amount: Shared<decimal> = new Shared(19.99)
    let amount_weak: Weak<decimal> = amount.downgrade()
    io.println("{amount.get() + 0.01} {amount_weak.upgrade().expect("amount").get()}")

    let number: Shared<int> = new Shared(41)
    let worker: Thread<int> = thread.spawn(fn() -> int { return number.get() + 1 })
    io.println(worker.join())
}
