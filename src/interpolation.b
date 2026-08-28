package main

fn interpolation_expression_source(segment: string) -> string {
    var depth: int = 0
    var in_string: bool = false
    var index: int = 0
    for index < segment.len() {
        let byte: int = segment.byte_at(index)
        if byte == 92 {
            index += string_escape_length(
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
            return segment.slice(0, index)
        }
        index += 1
    }
    return segment
}
