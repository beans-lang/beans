import std.io

class Probe {
    name: string
    hits: int

    fn init(move name: string) {
        self.name = move name
        self.hits = 0
    }

    fn touch() {
        self.hits += 1
    }

    fn deinit() {
        io.println("probe {self.name} died after {self.hits} hits")
    }
}

unique class Handle {
    id: int

    fn init(id: int) {
        self.id = id
    }

    fn deinit() {
        io.println("handle {self.id} closed")
    }
}

fn scoped() {
    var first: Probe = new Probe("first")
    var second: Probe = new Probe("second")
    first.touch()
    second.touch()
    second.touch()
    io.println("leaving scoped")
}

fn reassigned() {
    var p: Probe = new Probe("old")
    p = new Probe("new")
    io.println("replaced")
}

fn aliased() {
    var keep: List<Probe> = []
    var p: Probe = new Probe("shared")
    keep.push(p)
    p.touch()
    io.println("alias dropped, list still holds it")
}

fn unique_handle() {
    var h: Handle = new Handle(7)
    io.println("handle open")
}

fn main() {
    scoped()
    reassigned()
    aliased()
    unique_handle()
    io.println("done")
}
