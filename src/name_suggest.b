package main

fn name_edit_distance(left: string, right: string) -> int {
    var previous: List<int> = [0]
    for index: int in 0..right.len() {
        previous.push(index + 1)
    }
    for left_index: int in 0..left.len() {
        var current: List<int> = [left_index + 1]
        for right_index: int in 0..right.len() {
            let deletion: int = previous[right_index + 1] + 1
            let insertion: int = current[right_index] + 1
            let substitution: int =
                previous[right_index] +
                if left.byte_at(left_index) ==
                   right.byte_at(right_index) { 0 } else { 1 }
            var best: int = deletion
            if insertion < best { best = insertion }
            if substitution < best { best = substitution }
            current.push(best)
        }
        previous = move current
    }
    return previous[right.len()]
}

// Keep suggestions conservative: one edit is close enough to be useful and
// unlikely to point at an unrelated name. Sorting makes ties deterministic.
fn nearest_name(written: string,
                candidates: List<string>) -> string {
    var ordered: List<string> = []
    for candidate: string in candidates {
        if candidate != written && !ordered.contains(candidate) {
            ordered.push(candidate)
        }
    }
    ordered.sort()
    var best: string = ""
    var best_distance: int = 2
    for candidate: string in ordered {
        let distance: int =
            name_edit_distance(written, candidate)
        if distance < best_distance {
            best = candidate
            best_distance = distance
        }
    }
    return best
}

fn add_name_suggestion(message: string, written: string,
                       candidates: List<string>) -> string {
    let nearest: string = nearest_name(written, candidates)
    if nearest == "" { return message }
    return "{message} — did you mean '{nearest}'?"
}
