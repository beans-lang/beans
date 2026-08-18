import std.io

class Stats {
    static total: int = 2
    static next: int = Stats.total + 1
    static label: string = "first"
    priv static secret: int = 40

    static fn reveal() -> int {
        Stats.secret += 2
        return Stats.secret
    }
}

singleton class Snapshot {
    value: int = Stats.next
}

fn main() {
    Stats.total += 5
    Stats.label = "second"
    io.println("{Stats.total}")
    io.println("{Stats.next}")
    io.println(Stats.label)
    io.println("{Stats.reveal()}")
    io.println("{Snapshot.instance.value}")
}
