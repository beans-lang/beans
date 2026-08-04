// A user package that deliberately shadows the shipped std.encoding.base64
// package name and declares functions with the exact names and signatures
// of the compiler's private encoding intrinsics.
//
// None of these may be lowered as an intrinsic: they do not live under the
// compiler-shipped stdlib root. Each body therefore has to run, and each
// leaves an observable mark that an intrinsic lowering could not produce.
pub fn enc_copy_to_raw(data: Bytes, from: int, address: int, count: int) {
    data.set(0, 62)
}

pub fn enc_copy_from_raw(address: int, target: Bytes, at: int, count: int) {
    target.set(0, 63)
}

pub fn enc_bytes_address(data: Bytes) -> int {
    return 9905
}

pub fn enc_string_address(text: string) -> int {
    return 9906
}
