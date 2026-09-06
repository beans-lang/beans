// RSS-release gate (driven by test/rss_release.sh).
//
// Allocates 32 live one-mebibyte backings at once, holds them while the shell
// samples resident memory, frees them all, and holds again while the shell
// samples once more. Every backing is *touched* (filled), so its pages are
// really resident — an untouched mmap backing is demand-paged and would never
// show up in `ps`. A backing past the runtime's mmap threshold is unmapped
// when it is freed, so the second sample falls back near the first; a freed
// block left on a MADV_FREE page the OS still counts as resident would not.
//
// The markers go to stderr, which is unbuffered, so the shell sees each one
// the instant it is printed; stdout stays clean. After each marker the program
// blocks on a line from stdin, so the shell decides when to advance and the
// resident set is never sampled mid-phase.
import std.io

fn marker(name: string) {
    io.eprintln("phase {name}")
    match io.read_line() {
        some(_) => {}
        none => {}
    }
}

fn main() {
    let count: int = 32
    let bytes_len: int = 1048576        // one mebibyte, well past the map threshold
    let ints_len: int = 131072          // 131072 * 8 bytes = one mebibyte

    marker("baseline")

    // 32 live 1 MiB Bytes backings, each filled so its pages are resident.
    var bytes_hold: List<Bytes> = []
    for i: int in 0..count {
        bytes_hold.push(Bytes.filled(bytes_len, 65))
    }
    marker("allocated-bytes")
    bytes_hold = []                     // drop all 32; each backing is unmapped here
    marker("freed-bytes")

    // One touched 1 MiB List<int>, cloned so all 32 backings are resident
    // without pushing four million times through the interpreter.
    var template: List<int> = []
    for i: int in 0..ints_len { template.push(i) }
    var ints_hold: List<List<int>> = []
    for i: int in 0..count {
        ints_hold.push(template.clone())
    }
    template = []                       // done with the template
    marker("allocated-lists")
    ints_hold = []                      // drop all 32
    marker("freed-lists")

    // 32 live 1 MiB strings. A large string is a non-pooled beans_alloc object,
    // so it takes the rt_obj map path, not the backing path — this checks that
    // path returns RSS too. repeat builds and touches the whole string.
    var str_hold: List<string> = []
    for i: int in 0..count {
        str_hold.push("x".repeat(bytes_len))
    }
    marker("allocated-strings")
    str_hold = []                       // drop all 32; each string is unmapped here
    marker("freed-strings")

    // Records-sized backings: 200 KB each — above a 128 KB threshold, below a
    // 256 KB one. This is the range a held-and-freed response body lives in, and
    // the phase returns its pages only when the threshold reaches down to it.
    // 160 of them so the total clears the same resident bar as the phases above.
    let rec_len: int = 204800
    let rec_count: int = 160
    var rec_hold: List<Bytes> = []
    for i: int in 0..rec_count {
        rec_hold.push(Bytes.filled(rec_len, 65))
    }
    marker("allocated-records")
    rec_hold = []                       // drop all 160
    marker("freed-records")
}
