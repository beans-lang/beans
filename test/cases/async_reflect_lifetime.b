import std.async as aio
import std.io
import std.reflect

class Counts {
    static before_poll: int = 0
    static pending: int = 0
    static invalid: int = 0
    static wrong_arity: int = 0
    static wrong_receiver: int = 0
    static wrong_static: int = 0
}

unique class Probe {
    kind: int

    fn init(kind: int) { self.kind = kind }

    fn deinit() {
        if self.kind == 1 {
            Counts.before_poll += 1
        } else if self.kind == 2 {
            Counts.pending += 1
        } else if self.kind == 3 {
            Counts.invalid += 1
        } else if self.kind == 4 {
            Counts.wrong_arity += 1
        } else if self.kind == 5 {
            Counts.wrong_receiver += 1
        } else {
            Counts.wrong_static += 1
        }
    }
}

pub async fn blocked(move probe: Probe, gate: aio.Event) -> int {
    await gate.wait()
    return 1
}

pub async fn validate(move probe: Probe, value: int) -> int {
    return value
}

class Receiver {
    label: string

    fn init(label: string) { self.label = label }

    pub async fn suspended(gate: aio.Event) -> string {
        await gate.wait()
        return self.label
    }

    pub async fn consume(move probe: Probe) -> int {
        return 1
    }
}

class Other {}

async fn cancel_before(function: reflect.Function) {
    let group: aio.TaskGroup<Result<reflect.Value, reflect.ReflectError>> =
        new aio.TaskGroup<Result<reflect.Value, reflect.ReflectError>>()
    let probe: Probe = new Probe(1)
    group.start(function.call_async([
        reflect.value(move probe), reflect.value(new aio.Event())]))
    group.cancel_all()
}

async fn cancel_pending(function: reflect.Function) -> bool {
    let gate: aio.Event = new aio.Event()
    let group: aio.TaskGroup<Result<reflect.Value, reflect.ReflectError>> =
        new aio.TaskGroup<Result<reflect.Value, reflect.ReflectError>>()
    let probe: Probe = new Probe(2)
    group.start(function.call_async([
        reflect.value(move probe), reflect.value(gate)]))
    let first: Option<Result<reflect.Value, reflect.ReflectError>> =
        group.try_next()
    group.cancel_all()
    return first.is_none()
}

async fn main() {
    let blocked_function: reflect.Function =
        reflect.find_function("main.blocked").expect("blocked")

    await cancel_before(blocked_function)
    io.println("before {Counts.before_poll}")

    let was_blocked: bool = await cancel_pending(blocked_function)
    io.println("blocked {was_blocked}")
    io.println("pending {Counts.pending}")

    let validate_function: reflect.Function =
        reflect.find_function("main.validate").expect("validate")
    let invalid_probe: Probe = new Probe(3)
    match await validate_function.call_async([
              reflect.value(move invalid_probe),
              reflect.value("wrong")]) {
        ok(_) => io.println("bad validation"),
        err(problem) => io.println(problem.kind()),
    }
    io.println("invalid {Counts.invalid}")

    let arity_probe: Probe = new Probe(4)
    match await validate_function.call_async([
              reflect.value(move arity_probe)]) {
        ok(_) => io.println("bad arity"),
        err(problem) => io.println(problem.kind()),
    }
    io.println("arity {Counts.wrong_arity}")

    let consume: reflect.Method =
        type_of(Receiver).method("consume").expect("consume")
    let receiver_probe: Probe = new Probe(5)
    match await consume.call_async(
              reflect.value(new Other()),
              [reflect.value(move receiver_probe)]) {
        ok(_) => io.println("bad receiver"),
        err(problem) => io.println(problem.kind()),
    }
    io.println("wrong receiver {Counts.wrong_receiver}")

    let static_probe: Probe = new Probe(6)
    match await consume.call_static_async([
              reflect.value(move static_probe)]) {
        ok(_) => io.println("bad static"),
        err(problem) => io.println(problem.kind()),
    }
    io.println("wrong static {Counts.wrong_static}")

    let receiver_gate: aio.Event = new aio.Event()
    let method: reflect.Method =
        type_of(Receiver).method("suspended").expect("suspended")
    let receiver_group:
        aio.TaskGroup<Result<reflect.Value, reflect.ReflectError>> =
        new aio.TaskGroup<Result<reflect.Value, reflect.ReflectError>>()
    receiver_group.start(method.call_async(
        reflect.value(new Receiver("alive")),
        [reflect.value(receiver_gate)]))
    let receiver_first:
        Option<Result<reflect.Value, reflect.ReflectError>> =
        receiver_group.try_next()
    io.println("receiver blocked {receiver_first.is_none()}")
    receiver_gate.set()
    let receiver_result: reflect.Value =
        (await receiver_group.next()).expect("receiver result").expect("call")
    io.println((receiver_result as? string).expect("receiver string"))
}
