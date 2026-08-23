import std.io

async fn twice(value: int) -> int {
    return value * 2
}

async fn invoke(work: async fn(int) -> int,
                value: int) -> int {
    return await work(value)
}

unique class Counter {
    pub value: int = 5

    pub async fn add_later(delta: int) -> int {
        let doubled: int = await twice(delta)
        return self.value + doubled
    }

    pub async fn through_self(delta: int) -> int {
        return await self.add_later(delta)
    }
}

async fn main() {
    let local: async fn(int) -> int = twice
    let answer: int = await invoke(local, 21)
    io.println("{answer}")

    let captured: int = 9
    let literal: async fn(int) -> int =
        async fn(value: int) -> int {
            let doubled: int = await twice(value)
            return doubled + captured
        }
    let from_literal: int = await literal(2)
    io.println("{from_literal}")

    let sendable: send async fn(int) -> int =
        send async fn(value: int) -> int {
            return value + 1
        }
    let from_sendable: int = await sendable(8)
    io.println("{from_sendable}")

    let counter: Counter = new Counter()
    let from_method: int = await counter.through_self(3)
    io.println("{from_method}")
}
