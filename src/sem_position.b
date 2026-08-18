package main

fn sem_before(line: int, col: int,
              other_line: int, other_col: int) -> bool {
    if line != other_line { return line < other_line }
    return col < other_col
}

fn sem_contains(start_line: int, start_col: int,
                end_line: int, end_col: int,
                line: int, col: int) -> bool {
    if sem_before(line, col, start_line, start_col) {
        return false
    }
    return !sem_before(end_line, end_col, line, col)
}

// Two bindings can be confused with each other only where their scopes meet.
// Renaming one into the other's name is safe exactly when they never do.
fn sem_scopes_overlap(left: SemanticBinding,
                      right: SemanticBinding) -> bool {
    if sem_before(left.scope_end_line, left.scope_end_col,
                  right.scope_line, right.scope_col) {
        return false
    }
    if sem_before(right.scope_end_line, right.scope_end_col,
                  left.scope_line, left.scope_col) {
        return false
    }
    return true
}

// ---------------------------------------------------------------------------
// Buckets
// ---------------------------------------------------------------------------

// Every index below is a multimap, and a multimap cannot store a `List<T>`
// directly: a list is move-only, so stage 0 can read it back neither with
// `m.get(k)` nor with `m[k]` — "a consuming map read is not available yet".
// A class is a reference, so a bucket holding the list reads out fine, the
// same way `Map<string, HirFunction>` does elsewhere in the compiler.
//
// Read one with `let bucket: SemIds = m[k]`, then use `bucket.items`.
