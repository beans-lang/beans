import std.io
import std.reflect

pub class Built {
    pub number: int
    pub label: string = "ready"

    pub fn init(number: int) {
        self.number = number
    }
}

pub class Base {
    pub number: int

    pub fn init(number: int) {
        self.number = number
    }
}

pub class Derived extends Base {
    pub extra: int = 9
}

pub class DefaultOnly {
    pub answer: int = 42
}

pub class Closed {
    fn init() {}
}

pub class Held {
    pub label: string = "still alive"

    pub fn init() {}
}

pub class Holder {
    pub item: Held

    pub fn init(item: Held) {
        self.item = item
    }
}

pub struct Packet {
    pub label: string
    pub count: int
}

pub enum Signal {
    idle
    pair(label: string, count: int)
}

fn hold_once(held_value: reflect.Value) {
    let holder_value: reflect.Value =
        type_of(Holder).initializer().expect("Holder init").call([
            held_value]).expect("construct Holder")
    let holder: Holder =
        (holder_value as? Holder).expect("Holder")
    io.println(holder.item.label)
}

fn main() {
    let built_value: reflect.Value =
        type_of(Built).initializer().expect("Built init").call([
            reflect.value(7)]).expect("construct Built")
    let built: Built = (built_value as? Built).expect("Built")
    io.println("{built.number}:{built.label}")

    let derived_value: reflect.Value =
        type_of(Derived).initializer().expect("Derived init").call([
            reflect.value(8)]).expect("construct Derived")
    let derived: Derived =
        (derived_value as? Derived).expect("Derived")
    io.println("{derived.number}:{derived.extra}")

    let default_value: reflect.Value =
        type_of(DefaultOnly).initializer().expect("default init").call([]).expect(
            "construct default")
    let defaulted: DefaultOnly =
        (default_value as? DefaultOnly).expect("DefaultOnly")
    io.println(defaulted.answer)

    let held_value: reflect.Value =
        type_of(Held).initializer().expect("Held init").call([]).expect(
            "construct Held")
    hold_once(held_value)
    let held: Held = (held_value as? Held).expect("Held")
    io.println(held.label)

    let pair_value: reflect.Value =
        type_of(Signal).variant("pair").expect("pair").make([
            reflect.value("ok"), reflect.value(3)]).expect("make pair")
    let pair: Signal = (pair_value as? Signal).expect("Signal")
    match pair {
        pair(label, count) => io.println("{label}:{count}"),
        idle => io.println("bad"),
    }

    let idle_value: reflect.Value =
        type_of(Signal).variant("idle").expect("idle").make([]).expect(
            "make idle")
    let idle: Signal = (idle_value as? Signal).expect("Signal")
    match idle {
        idle => io.println("idle"),
        pair(other_label, other_count) => io.println(
            "bad:{other_label}:{other_count}"),
    }

    let packet_initializer: reflect.Initializer =
        type_of(Packet).initializer().expect("Packet initializer")
    io.println("{packet_initializer.parameters()[0].name()}:{packet_initializer.parameters()[1].name()}")
    let packet_value: reflect.Value = packet_initializer.call([
        reflect.value("box"), reflect.value(5)]).expect("construct Packet")
    let packet: Packet = (packet_value as? Packet).expect("Packet")
    io.println("{packet.label}:{packet.count}")

    match type_of(Built).initializer().expect("Built init").call([]) {
        ok(_) => io.println("bad count"),
        err(problem) => io.println(problem.kind()),
    }
    match type_of(Signal).variant("pair").expect("pair").make([
              reflect.value(1), reflect.value(2)]) {
        ok(_) => io.println("bad type"),
        err(problem) => io.println(problem.kind()),
    }
    match type_of(Closed).initializer().expect("Closed init").call([]) {
        ok(_) => io.println("bad private"),
        err(problem) => io.println(problem.kind()),
    }
}
