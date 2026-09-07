// Building the object graph a JSON response is made of, which is where a
// server's allocator time actually goes.
//
// The shape is the espresso benchmark's /records row (bench/json_encode_records.b
// encodes the same struct): five scalars, three strings and a three-element tag
// list per record. Nothing here is arithmetic — a record is four or five heap
// blocks and the same number of frees, each recycled block memset on the way
// out. Issue #150 measured the thousand-record build at 167 microseconds
// against Bun's 89 on the same document, with the encoder excluded.
//
// The tags are string literals, which are immortal statics and cost no
// allocation, so what this counts per record is: the name, the email, the note,
// and the tag list. One in a thousand records survives into a list, the same
// contract bench/churn.b uses, so the build is not dead code.
import std.io
import std.os

struct Record {
    pub id: int
    pub name: string
    pub email: string
    pub active: bool
    pub score: int
    pub tags: List<string>
    pub note: string
    pub balance: int
}

fn tag_at(index: int) -> string {
    return match index % 5 {
        0 => "alpha",
        1 => "beta",
        2 => "gamma",
        3 => "delta",
        _ => "epsilon",
    }
}

fn make_record(index: int) -> Record {
    return Record {
        id: index,
        name: "record-{index}",
        email: "user{index}@example.com",
        active: index % 3 == 0,
        score: (index * 2654435761) % 100000,
        tags: [tag_at(index), tag_at(index + 2), tag_at(index + 4)],
        note: "record {index}: the quick brown fox jumps over the lazy dog while the barista pulls a double ristretto shot",
        balance: (index * 7919) % 1000000,
    }
}

fn main() {
    let args: List<string> = os.args()
    let n: int = args.get(0).or("").to_int().or(400_000)
    let seed: int = args.get(1).or("").to_int().or(1)
    var keep: List<Record> = []
    keep.reserve(n / 1000 + 1)
    var bytes: int = 0
    var total: int = 0
    for i: int in 0..n {
        let record: Record = make_record(i + seed)
        bytes = bytes + record.name.len() + record.email.len() + record.note.len()
        total = total + record.id + record.score + record.balance + record.tags.len()
        if record.active {
            total = total + 1
        }
        if i % 1000 == 0 {
            keep.push(move record)
        }
    }
    io.println("bytes {bytes} total {total} kept {keep.len()}")
}
