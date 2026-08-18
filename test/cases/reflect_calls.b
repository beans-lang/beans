import std.io
import std.reflect

pub fn add(left: int, right: int) -> int {
    return left + right
}

pub fn take_text(move text: string) -> string {
    return text
}

pub fn change(inout value: int) -> int {
    value += 1
    return value
}

struct Parcel {
    label: string
    count: int
}

pub fn round_trip(move parcel: Parcel) -> Parcel {
    return move parcel
}

class Parent {
    pub fn label(value: int) -> string {
        return "parent:{value}"
    }
}

class Child extends Parent {
    pub override fn label(value: int) -> string {
        return "child:{value}"
    }

    pub static fn twice(value: int) -> int {
        return value * 2
    }

    fn hidden() -> int { return 9 }
}

fn main() {
    let add_fn: reflect.Function =
        reflect.find_function("main.add").expect("add")
    let sum: reflect.Value = add_fn.call([
        reflect.value(20), reflect.value(22)]).expect("call add")
    io.println((sum as? int).expect("sum"))

    let text_fn: reflect.Function =
        reflect.find_function("main.take_text").expect("take_text")
    let text: reflect.Value = text_fn.call([
        reflect.value("moved")]).expect("call take_text")
    io.println((text as? string).expect("text"))

    let child: Child = new Child()
    let receiver: reflect.Value = reflect.value(move child)
    let label: reflect.Method =
        type_of(Parent).method("label").expect("label")
    let called: reflect.Value = label.call(receiver, [
        reflect.value(7)]).expect("call label")
    io.println((called as? string).expect("label result"))

    let twice: reflect.Method =
        type_of(Child).method("twice").expect("twice")
    let doubled: reflect.Value = twice.call_static([
        reflect.value(6)]).expect("call twice")
    io.println((doubled as? int).expect("twice result"))

    let parcel: Parcel = Parcel { label: "safe", count: 2 }
    let round_trip: reflect.Function =
        reflect.find_function("main.round_trip").expect("round_trip")
    let parcel_result: reflect.Value = round_trip.call([
        reflect.value(move parcel)]).expect("call round_trip")
    let restored_parcel: Parcel =
        (parcel_result as? Parcel).expect("Parcel")
    io.println("{restored_parcel.label}:{restored_parcel.count}")

    match add_fn.call([reflect.value(1)]) {
        ok(_) => io.println("bad count"),
        err(problem) => io.println(problem.kind()),
    }
    match add_fn.call([
              reflect.value("wrong"), reflect.value(2)]) {
        ok(_) => io.println("bad type"),
        err(problem) => io.println(problem.kind()),
    }
    let hidden: reflect.Method =
        type_of(Child).method("hidden").expect("hidden")
    match hidden.call(receiver, []) {
        ok(_) => io.println("bad private"),
        err(problem) => io.println(problem.kind()),
    }
    let change_fn: reflect.Function =
        reflect.find_function("main.change").expect("change")
    match change_fn.call([reflect.value(3)]) {
        ok(_) => io.println("bad inout"),
        err(problem) => io.println(problem.kind()),
    }
}
