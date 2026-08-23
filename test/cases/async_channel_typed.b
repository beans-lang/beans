import std.async as aio
import std.io

struct OwnedWide {
    pub label: string
    pub values: List<int>
}

unique class Parcel implements Send {
    pub value: int
    pub fn init(value: int) { self.value = value }
}

async fn main() {
    let wide_channel: Channel<OwnedWide> = new Channel<OwnedWide>(1)
    let wide: OwnedWide = OwnedWide {
        label: "wide", values: [4, 5]
    }
    await wide_channel.send_async(move wide)
    let got_wide: OwnedWide =
        (await wide_channel.receive_async()).expect("wide")
    io.println("typed {got_wide.label} {got_wide.values[0] + got_wide.values[1]}")

    let parcel_channel: Channel<Parcel> = new Channel<Parcel>(1)
    let parcel: Parcel = new Parcel(42)
    await parcel_channel.send_async(move parcel)
    let got_parcel: Parcel =
        (await parcel_channel.receive_async()).expect("parcel")
    io.println("move {got_parcel.value}")
}
