import std.io
import std.os

fn main() {
    // opt_i64 boxing: BOpt {val, has} into inline and niche Options
    let hit: Option<int> = "abcabc".find("ca")
    io.println(hit.expect("find"))
    io.println("abc".find("zz").is_none())

    // Bytes: constructor (panics row), mutators, queries, res_str decode
    var data: Bytes = new Bytes(3)
    data.set(0, 104)
    data.set(1, 105)
    data.append_string("!")
    io.println(data.len())
    io.println(data.get(1))
    let text: string = data.slice(0, 2).to_string_until_nul()
    io.println(text)
    io.println(Bytes.from("xy").len())

    // File and Dir through statics, methods, res_file/res_bytes/res_bool
    let path: string = "{Dir.temp_path()}/beans_self_host_registry.txt"
    let out: File = File.open(path, "create").expect("open create")
    out.write(Bytes.from("first line\n")).expect("write")
    out.close().expect("close create")
    let back: File = File.open(path, "r").expect("open r")
    let bytes: Bytes = back.read(64).expect("read")
    back.close().expect("close r")
    io.println(bytes.to_string_until_nul())
    io.println(File.exists(path))
    io.println(File.remove(path).expect("remove"))
    io.println(File.exists(path))

    // module fns: env fallback stays deterministic
    io.println(os.env("BEANS_SELF_HOST_REGISTRY_UNSET").or("fallback"))
}
