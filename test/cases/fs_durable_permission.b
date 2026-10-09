import std.fs
import std.io
import std.os

fn main() {
    // The harness seeds a read-only file, so failure must preserve its bytes.
    let readonly: string = os.args().get(0).expect("readonly path")
    match fs.write_durable(readonly, "changed") {
        ok(_) => { panic("read-only write succeeded") }
        err(e) => { io.println("fs durable permission {e.kind}") }
    }
    match fs.write_bytes_durable(readonly, new Bytes(1)) {
        ok(_) => { panic("read-only binary write succeeded") }
        err(e) => { io.println("fs durable bytes permission {e.kind}") }
    }
    match fs.sync(readonly) {
        ok(_) => { panic("read-only sync succeeded") }
        err(e) => { io.println("fs sync permission {e.kind} {fs.read(readonly).expect("read-only retained") == "retained\n"}") }
    }
}
