import std.io
import std.os

struct ManualOption {
    present: bool
    value: int
}

struct ManualResult {
    okay: bool
    value: int
    problem: string
}

fn optional(value: int, present: bool) -> Option<int> {
    if present { return some(value) }
    return none
}

fn manual_optional(value: int, present: bool) -> ManualOption {
    return ManualOption {
        present: present,
        value: value,
    }
}

fn fallible(value: int, succeeds: bool) -> Result<int, string> {
    if succeeds { return ok(value) }
    return err("bad")
}

fn manual_fallible(value: int, succeeds: bool) -> ManualResult {
    return ManualResult {
        okay: succeeds,
        value: value,
        problem: if succeeds { "" } else { "bad" },
    }
}

fn main() {
    let args: List<string> = os.args()
    let mode: string = args.get(0).or("option")
    let n: int = args.get(1).or("").to_int().or(1_000_000)
    let seed: int = args.get(2).or("").to_int().or(1)
    var sum: int = 0
    var index: int = 0
    if mode == "option" {
        for index < n {
            match optional(index + seed, index % 7 != 0) {
                some(value) => { sum += value },
                none => { sum -= 1 },
            }
            index += 1
        }
    } else if mode == "manual_option" {
        for index < n {
            let got: ManualOption =
                manual_optional(index + seed, index % 7 != 0)
            if got.present {
                sum += got.value
            } else {
                sum -= 1
            }
            index += 1
        }
    } else if mode == "result" {
        for index < n {
            match fallible(index + seed, index % 7 != 0) {
                ok(value) => { sum += value },
                err(_) => { sum -= 1 },
            }
            index += 1
        }
    } else {
        for index < n {
            let got: ManualResult =
                manual_fallible(index + seed, index % 7 != 0)
            if got.okay {
                sum += got.value
            } else {
                sum -= 1
            }
            index += 1
        }
    }
    io.println(sum)
}
