import std.io

interface WildAnimal {
    fn can_attack();
}

interface HouseAnimal {
    fn can_tame();
}

class Animals implements WildAnimal, HouseAnimal {
    fn can_attack() { io.println("attack") }
    fn can_tame() { io.println("tame") }
}

struct Holder {
    value: Option<List<int>>
}

enum Choice<T> {
    value(item: T)
    empty
}

fn empty() -> Option<List<int>> {
    return none
}

fn accept_owned(move value: Option<List<int>>) {
    io.println("take {value.is_none()}")
}

fn main() {
    var direct: Option<List<int>> = none
    direct = none
    let values: List<Option<List<int>>> = [none]
    values.push(none)
    let holder: Holder = Holder { value: none }
    let choice: Choice<Option<List<int>>> = Choice.value(none)
    let missing: Choice<Option<List<int>>> = Choice.empty
    let nested: Map<string, Option<List<int>>> = {"empty": none}
    nested.set("other", none)
    let box: Box<Option<List<int>>> = new Box(none)
    box.set(none)
    let arena: Arena<Option<List<int>>> = new Arena(1)
    arena.add(none)
    let channel: Channel<Option<List<int>>> = new Channel(1)
    channel.send(none)
    channel.close()
    accept_owned(none)
    let animals: Animals = new Animals()
    animals.can_attack()
    animals.can_tame()
    io.println("none {direct.is_none()} {values.len()} {holder.value.is_none()} {choice == missing} {nested.len()} {empty().is_none()}")
}
