package main

class TreeFormatSpec {
    has: bool
    width: int
    places: int
    left: bool

    fn init() {
        self.has = false
        self.width = 0
        self.places = -1
        self.left = false
    }
}

fn tree_format_spec(segment: string) -> TreeFormatSpec {
    let result: TreeFormatSpec =
        new TreeFormatSpec()
    var depth: int = 0
    var in_string: bool = false
    var colon: int = -1
    var index: int = 0
    for index < segment.len() {
        let byte: int = segment.byte_at(index)
        if byte == 92 {
            index += string_escape_length(
                segment, index, segment.len())
            continue
        }
        // A raw literal is bytes: a `:` or a brace in it is not a format
        // separator or a bracket. Step over it whole so the format spec is
        // found after the value, not inside a raw one.
        if !in_string &&
           raw_open_at(segment, index, segment.len()) {
            index = raw_literal_end(
                segment, index, segment.len())
            continue
        }
        if in_string {
            if byte == 34 { in_string = false }
            index += 1
            continue
        }
        if byte == 34 {
            in_string = true
        } else if byte == 40 || byte == 91 ||
                  byte == 123 {
            depth += 1
        } else if byte == 41 || byte == 93 ||
                  byte == 125 {
            depth -= 1
        } else if byte == 58 && depth == 0 {
            colon = index
            break
        }
        index += 1
    }
    if colon < 0 { return result }

    result.has = true
    index = colon + 1
    if index < segment.len() &&
       segment.byte_at(index) == 45 {
        result.left = true
        index += 1
    }
    for index < segment.len() {
        let byte: int = segment.byte_at(index)
        if byte < 48 || byte > 57 { break }
        result.width =
            result.width * 10 + byte - 48
        index += 1
    }
    if index < segment.len() &&
       segment.byte_at(index) == 46 {
        result.places = 0
        index += 1
        for index < segment.len() {
            let byte: int = segment.byte_at(index)
            if byte < 48 || byte > 57 { break }
            result.places =
                result.places * 10 + byte - 48
            index += 1
        }
    }
    return result
}
