import std.async as aio
import std.io
import std.reflect

pub async fn add(left: int, right: int) -> int {
    await aio.yield_now()
    return left + right
}

pub fn sync_add(left: int, right: int) -> int {
    return left + right
}

struct Parcel {
    label: string
    count: int
}

pub async fn parcel_round_trip(move parcel: Parcel) -> Parcel {
    await aio.yield_now()
    return move parcel
}

unique class Token {
    value: int

    fn init(value: int) { self.value = value }
    fn read() -> int { return self.value }
}

pub async fn token_round_trip(move token: Token) -> Token {
    await aio.yield_now()
    return move token
}

pub async fn finish_unit() {
    await aio.yield_now()
}

pub async fn sum_ten(a: int, b: int, c: int, d: int, e: int,
                     f: int, g: int, h: int, i: int, j: int) -> int {
    await aio.yield_now()
    return a + b + c + d + e + f + g + h + i + j
}

class ParcelOwner {
    label: string

    fn init(label: string) { self.label = label }
}

struct OwnedParcel {
    owner: ParcelOwner
    suffix: string
}

pub async fn owned_parcel() -> OwnedParcel {
    await aio.yield_now()
    return OwnedParcel {
        owner: new ParcelOwner("held"), suffix: "wide"
    }
}

fn take_token(move value: reflect.Value) -> Token {
    return (move value as? Token).expect("token result")
}

class Base {
    pub fn sync_label(value: int) -> string {
        return "sync:{value}"
    }

    pub async fn label(value: int) -> string {
        await aio.yield_now()
        return "base:{value}"
    }
}

class Child extends Base {
    pub override async fn label(value: int) -> string {
        await aio.yield_now()
        return "child:{value}"
    }

    pub static async fn twice(value: int) -> int {
        return value * 2
    }
}

class ShadowBase {
    pub async fn collide(value: int) -> string {
        await aio.yield_now()
        return "instance:{value}"
    }
}

class ShadowChild extends ShadowBase {
    pub static async fn collide(value: int) -> string {
        return "static:{value}"
    }
}

async fn main() {
    let function: reflect.Function =
        reflect.find_function("main.add").expect("add")
    io.println(function.result_type().qualified_name())
    let sum: reflect.Value = (await function.call_async([
        reflect.value(20), reflect.value(22)])).expect("add")
    io.println((sum as? int).expect("sum"))

    let receiver: reflect.Value = reflect.value(new Child())
    let label: reflect.Method =
        type_of(Base).method("label").expect("label")
    io.println(label.result_type().qualified_name())
    let called: reflect.Value = (await label.call_async(
        receiver, [reflect.value(7)])).expect("label")
    io.println((called as? string).expect("label result"))
    match label.call(receiver, [reflect.value(1)]) {
        ok(_) => io.println("bad method sync async"),
        err(problem) => io.println(problem.kind()),
    }
    let sync_label: reflect.Method =
        type_of(Base).method("sync_label").expect("sync label")
    match await sync_label.call_async(receiver, [reflect.value(1)]) {
        ok(_) => io.println("bad method async sync"),
        err(problem) => io.println(problem.kind()),
    }

    let twice: reflect.Method =
        type_of(Child).method("twice").expect("twice")
    let doubled: reflect.Value = (await twice.call_static_async([
        reflect.value(6)])).expect("twice")
    io.println((doubled as? int).expect("twice result"))

    let collide: reflect.Method =
        type_of(ShadowBase).method("collide").expect("collide")
    let collided: reflect.Value = (await collide.call_async(
        reflect.value(new ShadowChild()),
        [reflect.value(8)])).expect("instance collision")
    io.println((collided as? string).expect("collision result"))

    let parcel_function: reflect.Function =
        reflect.find_function("main.parcel_round_trip").expect("parcel")
    let sent_parcel: Parcel = Parcel { label: "wide", count: 5 }
    let parcel_value: reflect.Value = (await parcel_function.call_async([
        reflect.value(move sent_parcel)
    ])).expect("parcel call")
    let parcel: Parcel =
        (parcel_value as? Parcel).expect("parcel result")
    io.println("{parcel.label}:{parcel.count}")

    let token_function: reflect.Function =
        reflect.find_function("main.token_round_trip").expect("token")
    let sent_token: Token = new Token(9)
    let token_value: reflect.Value = (await token_function.call_async([
        reflect.value(move sent_token)
    ])).expect("token call")
    let token: Token = take_token(move token_value)
    io.println(token.read())

    let unit_function: reflect.Function =
        reflect.find_function("main.finish_unit").expect("unit")
    let unit_value: reflect.Value =
        (await unit_function.call_async([])).expect("unit call")
    io.println(unit_value.type().qualified_name())

    let ten: reflect.Function =
        reflect.find_function("main.sum_ten").expect("sum ten")
    let ten_value: reflect.Value = (await ten.call_async([
        reflect.value(1), reflect.value(2), reflect.value(3),
        reflect.value(4), reflect.value(5), reflect.value(6),
        reflect.value(7), reflect.value(8), reflect.value(9),
        reflect.value(10)
    ])).expect("sum ten call")
    io.println((ten_value as? int).expect("sum ten result"))

    let owned_function: reflect.Function =
        reflect.find_function("main.owned_parcel").expect("owned parcel")
    let owned_value: reflect.Value =
        (await owned_function.call_async([])).expect("owned parcel call")
    let owned: OwnedParcel =
        (owned_value as? OwnedParcel).expect("owned parcel result")
    io.println("{owned.owner.label}:{owned.suffix}")

    match function.call([reflect.value(1), reflect.value(2)]) {
        ok(_) => io.println("bad sync async"),
        err(problem) => io.println(problem.kind()),
    }
    let sync_function: reflect.Function =
        reflect.find_function("main.sync_add").expect("sync add")
    match await sync_function.call_async([
              reflect.value(1), reflect.value(2)]) {
        ok(_) => io.println("bad async sync"),
        err(problem) => io.println(problem.kind()),
    }
}
