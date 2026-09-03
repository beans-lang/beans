// The accumulating half of std.fmt. Interpolation and the sprintf-style
// helpers render one value; this renders a stream of them into one buffer.
//
// Interpolation is the right tool for a single string and the wrong one for a
// loop: `text = "{text}x"` builds a whole new string every turn, so appending
// n pieces copies O(n^2) bytes. A builder appends into one growing buffer and
// converts once, which is O(n).

package fmt

/// Text accumulated in one buffer, converted to a `string` once at the end.
///
/// Reach for this whenever a string is built in a loop. The obvious-looking
/// `text = "{text}piece"` copies everything written so far on every turn, so
/// the cost grows with the square of the length; a builder appends and copies
/// once.
///
/// ```
/// var out: fmt.StringBuilder = new fmt.StringBuilder()
/// var index: int = 0
/// for index < 20000 {
///     out.push("x")
///     index += 1
/// }
/// let text: string = out.to_string()
/// ```
///
/// The buffer holds bytes, so a piece already rendered by interpolation or by
/// `fmt.float`/`fmt.decimal`/`fmt.pad_left` goes in with `push`:
/// `out.push("{ratio:.2}")`. Nothing here validates UTF-8, exactly as `Bytes`
/// does not: what goes in comes out.
pub class StringBuilder {
    buffer: Bytes = new Bytes(0)

    /// A new, empty builder. `capacity` reserves that many bytes up front, so a
    /// build of a known size never regrows; a value of zero or less reserves
    /// nothing.
    pub fn init(capacity: int = 0) {
        if capacity > 0 {
            self.buffer.reserve(capacity)
        }
    }

    /// Append the bytes of `text`.
    pub fn push(text: string) {
        self.buffer.append_string(text)
    }

    /// Append `text` and then one `\n`.
    pub fn push_line(text: string) {
        self.buffer.append_string(text)
        self.buffer.push(10)
    }

    /// Append the decimal text of `value`, with a leading `-` when negative.
    pub fn push_int(value: int) {
        self.buffer.append_int_text(value)
    }

    /// Append `true` or `false`.
    pub fn push_bool(value: bool) {
        if value {
            self.buffer.append_string("true")
        } else {
            self.buffer.append_string("false")
        }
    }

    /// Append one raw byte — the low eight bits of `value`. Keeping the result
    /// valid UTF-8 is the caller's job, the same as it is for `Bytes.push`.
    pub fn push_byte(value: int) {
        self.buffer.push(value)
    }

    /// Bytes written so far. Not a character count: `len` is bytes here for the
    /// same reason `string.len` is.
    pub fn len() -> int {
        return self.buffer.len()
    }

    /// True while nothing has been pushed.
    pub fn is_empty() -> bool {
        return self.buffer.len() == 0
    }

    /// Make room for at least `capacity` bytes in total. A value of zero or
    /// less does nothing.
    pub fn reserve(capacity: int) {
        if capacity > 0 {
            self.buffer.reserve(capacity)
        }
    }

    /// Drop everything written so far and keep the buffer for the next build.
    pub fn clear() {
        self.buffer.resize(0)
    }

    /// Every byte written so far, as one string. The builder is unchanged, so
    /// it can be read twice or pushed to again afterwards.
    pub fn to_string() -> string {
        return self.buffer.to_string()
    }

    /// Every byte written so far, as an independent `Bytes` copy — the form a
    /// socket or a file wants.
    pub fn to_bytes() -> Bytes {
        return self.buffer.slice(0, self.buffer.len())
    }
}
