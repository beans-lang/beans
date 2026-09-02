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
    // One walk decides where a format spec starts, shared with the checker
    // and the LLVM emitter (src/interpolation.b).
    let colon: int = interpolation_format_colon(segment)
    if colon < 0 { return result }

    result.has = true
    var index: int = colon + 1
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
