struct Pair {
    left: int
    right: int
}

class Counter {
    value: int

    fn init(start: int) {
        self.value = start
    }

    fn add(amount: int) -> int {
        self.value += amount
        return self.value
    }
}

fn add(left: int, right: int) -> int {
    let total: int = left + right
    return total
}

fn choose(value: int) -> int {
    var result: int = 0
    if value < 0 {
        result = -1
    } else {
        result = 1
    }
    return result
}

fn compute(value: int) -> int {
    var result: int = add(value, 2)
    result += choose(value)
    let pair: Pair = Pair { left: result, right: 1 }
    let counter: Counter = new Counter(pair.left)
    result = counter.add(pair.right)
    if result >= 3 && value != 0 {
        result = result + 1
    }
    return result
}

fn containers() {
    var values: List<int> = [1, 2]
    values.reserve(8)
    values.insert(1, 3)
    let first: int = values.get(0).or(0)
    let last: int = values.last().or(0)
    let copy: List<int> = values.clone()

    let cell: Box<int> = new Box(first + last)
    cell.set(cell.get() + copy.len())

    let arena: Arena<int> = new Arena(4)
    let slot: int = arena.add(cell.get())
    let saved: int = arena.get(slot).or(0)

    let shared: Shared<int> = new Shared(saved)
    let weak: Weak<int> = shared.downgrade()
    let live: bool = !weak.is_expired()

    let channel: Channel<int> = new Channel(2)
    channel.send(shared.get())
    let received: int = channel.receive().or(0)
    channel.close()

    let atomic: AtomicInt = new AtomicInt(received)
    atomic.store(atomic.add_and_get(1))
    let current: int = atomic.load()
    let narrowed: i32 = current as i32
    let convert: fn(i32) -> int =
        fn(value: i32) -> int { return value as int }
    let converted: int = convert(narrowed)

    let mutex: Mutex<int> = new Mutex(current)
    let typed_atomic: Atomic<i32> = new Atomic<i32>(1)
}

fn main() {
    let answer: int = compute(4)
    let correct: bool = answer == 8
}
