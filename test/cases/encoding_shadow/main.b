// Negative proof for the compiler-shipped encoding intrinsics: a user
// module whose own packages are named json, xml and base64, declaring the
// intrinsic names with the exact signatures the compiler validates.
//
// Every call below must reach the user's own Beans body. If the native
// backend lowered any of them as an intrinsic, the marks would be missing
// and the addresses would be real pointers instead of the sentinels.

package main

import encshadow.json
import encshadow.xml
import encshadow.base64

import std.io

fn main() {
    var probe: Bytes = new Bytes(4)

    json.enc_copy_to_raw(probe, 0, 0, 0)
    io.println("json copy_to_raw mark {probe.get(0)}")
    json.enc_copy_from_raw(0, probe, 0, 0)
    io.println("json copy_from_raw mark {probe.get(0)}")
    io.println("json bytes_address {json.enc_bytes_address(probe)}")
    io.println("json string_address {json.enc_string_address("x")}")

    xml.enc_copy_to_raw(probe, 0, 0, 0)
    io.println("xml copy_to_raw mark {probe.get(0)}")
    io.println("xml bytes_address {xml.enc_bytes_address(probe)}")

    base64.enc_copy_to_raw(probe, 0, 0, 0)
    io.println("base64 copy_to_raw mark {probe.get(0)}")
    io.println("base64 bytes_address {base64.enc_bytes_address(probe)}")
    io.println("base64 string_uninit {base64.enc_string_uninit(7)}")

    io.println("user packages kept their own bodies")
}
