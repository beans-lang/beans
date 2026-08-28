// Terminal input, decoded.
//
// A raw terminal delivers bytes, not keys: a printable character is its UTF-8,
// but Enter is `0x0d`, Ctrl-C is `0x03`, and every arrow, Home, Page-Up and
// function key is a CSI escape sequence — `ESC [ A`, `ESC [ 5 ~`, `ESC [ 1 ; 5 C`
// for Ctrl-Right. Those sequences also **arrive split**: a read can end in the
// middle of one, with the rest in the next read.
//
// `KeyDecoder` is fed bytes and asked for keys. It holds an incomplete sequence
// until the bytes that finish it arrive, so a split sequence is one key, not two
// wrong ones. A lone `ESC` is the one genuine ambiguity — the Escape key, or the
// start of a sequence still on its way — so `next()` holds it and `flush()`,
// which you call once input has settled, resolves it to the Escape key.

package term

/// One decoded keypress.
///
/// The modifier fields are a bitmask: `mod_shift`, `mod_alt`, `mod_ctrl` OR-ed
/// together, exactly as a terminal reports them (`0` for none). Use `has_shift`,
/// `has_alt`, `has_ctrl` to read it. `ctrl` carries the letter as its uppercase
/// codepoint (`Ctrl-A` is `ctrl(65)`), and `char`/`alt` carry a Unicode
/// codepoint.
pub enum Key {
    char(codepoint: int)
    alt(codepoint: int)
    ctrl(letter: int)
    enter
    tab
    backspace
    escape
    up(mods: int)
    down(mods: int)
    left(mods: int)
    right(mods: int)
    home(mods: int)
    end(mods: int)
    page_up(mods: int)
    page_down(mods: int)
    insert(mods: int)
    delete(mods: int)
    function(number: int, mods: int)
    // A recognised escape shape we have no name for: the final byte, so a caller
    // can log it without the decoder stalling.
    unknown(final: int)
}

/// The Shift bit of a modifier mask.
pub fn mod_shift() -> int { return 1 }
/// The Alt (Meta) bit of a modifier mask.
pub fn mod_alt() -> int { return 2 }
/// The Ctrl bit of a modifier mask.
pub fn mod_ctrl() -> int { return 4 }

/// Whether a modifier mask includes Shift.
pub fn has_shift(mods: int) -> bool { return mods % 2 == 1 }
/// Whether a modifier mask includes Alt.
pub fn has_alt(mods: int) -> bool { return (mods / 2) % 2 == 1 }
/// Whether a modifier mask includes Ctrl.
pub fn has_ctrl(mods: int) -> bool { return (mods / 4) % 2 == 1 }

/// Turns a stream of terminal bytes into keys, buffering an incomplete escape
/// sequence across feeds.
pub class KeyDecoder {
    buffer: Bytes

    pub fn init() {
        self.buffer = new Bytes(0)
    }

    /// Adds bytes read from the terminal. Call `next` in a loop afterwards.
    pub fn feed(data: Bytes) {
        self.buffer.append(data)
    }

    /// How many bytes are held unparsed, i.e. an incomplete sequence's start.
    pub fn pending() -> int {
        return self.buffer.len()
    }

    fn consume(count: int) {
        self.buffer = self.buffer.slice(count, self.buffer.len())
    }

    /// The next key, or `none` when what is buffered is only the start of a
    /// sequence — read more, `feed` it, and call again. A lone `ESC` is held as
    /// incomplete; `flush` resolves it.
    pub fn next() -> Option<Key> {
        let n: int = self.buffer.len()
        if n == 0 { return none }
        let b0: int = self.buffer.get(0)
        if b0 != 27 {
            return self.decode_plain()
        }
        if n == 1 {
            // A lone ESC: the Escape key, or the start of a sequence still
            // arriving. Held until more bytes come or flush() decides.
            return none
        }
        let b1: int = self.buffer.get(1)
        if b1 == 91 {
            return self.decode_csi()
        }
        if b1 == 79 {
            return self.decode_ss3()
        }
        return self.decode_alt()
    }

    /// Resolves a buffer that `next` is holding as incomplete: a lone `ESC`, or
    /// an escape sequence that never completed, becomes the Escape key. Call it
    /// once input has settled — after a poll timeout, say — so a real Escape
    /// press is not held forever waiting for bytes that will never come.
    pub fn flush() -> Option<Key> {
        match self.next() {
            some(key) => { return some(key) }
            none => {}
        }
        if self.buffer.len() > 0 && self.buffer.get(0) == 27 {
            // Drop the stuck ESC and report it; a following byte, if any, is
            // decoded on the next call.
            self.consume(1)
            return some(Key.escape)
        }
        return none
    }

    // buffer[0] is not ESC: a control byte, a printable ASCII char, or the start
    // of a UTF-8 character.
    fn decode_plain() -> Option<Key> {
        let b: int = self.buffer.get(0)
        if b == 13 || b == 10 {
            self.consume(1)
            return some(Key.enter)
        }
        if b == 9 {
            self.consume(1)
            return some(Key.tab)
        }
        if b == 127 {
            self.consume(1)
            return some(Key.backspace)
        }
        if b < 32 {
            // A control byte is Ctrl-<letter>; b | 0x40 is that letter's
            // uppercase codepoint, and b < 32 makes b | 0x40 equal b + 64.
            self.consume(1)
            return some(Key.ctrl(b + 64))
        }
        if b < 128 {
            self.consume(1)
            return some(Key.char(b))
        }
        return self.decode_utf8()
    }

    // buffer[0] is a byte >= 0x80: a UTF-8 lead, or a stray continuation byte.
    fn decode_utf8() -> Option<Key> {
        let b: int = self.buffer.get(0)
        if b < 192 {
            // A continuation byte with no lead: not valid, but passing it
            // through keeps the decoder from stalling on it.
            self.consume(1)
            return some(Key.char(b))
        }
        var length: int = 4
        var value: int = b - 240
        if b < 224 {
            length = 2
            value = b - 192
        } else if b < 240 {
            length = 3
            value = b - 224
        }
        if self.buffer.len() < length {
            // The character is split across reads; wait for the rest.
            return none
        }
        var i: int = 1
        for i < length {
            let c: int = self.buffer.get(i)
            value = value * 64 + (c - 128)
            i += 1
        }
        self.consume(length)
        return some(Key.char(value))
    }

    // buffer is `ESC [ ...`: a CSI sequence. Scan for its final byte.
    fn decode_csi() -> Option<Key> {
        let n: int = self.buffer.len()
        var i: int = 2
        for i < n {
            let c: int = self.buffer.get(i)
            if c >= 64 && c <= 126 {
                return self.finish_csi(i)
            }
            if c < 32 || c > 126 {
                // Not a parameter, intermediate or final byte: the sequence is
                // malformed. Report the ESC and let the rest be reprocessed.
                self.consume(1)
                return some(Key.escape)
            }
            i += 1
        }
        // No final byte yet: the sequence is still arriving.
        return none
    }

    fn finish_csi(final_index: int) -> Option<Key> {
        var params: List<int> = []
        var current: int = 0
        var have: bool = false
        var i: int = 2
        for i < final_index {
            let c: int = self.buffer.get(i)
            if c >= 48 && c <= 57 {
                current = current * 10 + (c - 48)
                have = true
            } else if c == 59 {
                params.push(current)
                current = 0
                have = false
            }
            i += 1
        }
        if have {
            params.push(current)
        }
        let final: int = self.buffer.get(final_index)
        let total: int = final_index + 1
        var result: Key = Key.unknown(final)
        match self.map_csi(final, params) {
            some(key) => { result = key }
            none => {}
        }
        self.consume(total)
        return some(result)
    }

    // A CSI final byte and its parameters, mapped to a key. `none` for a shape
    // this decoder does not name.
    fn map_csi(final: int, params: List<int>) -> Option<Key> {
        var mods: int = 0
        if params.len() >= 2 {
            mods = params[1] - 1
        }
        if mods < 0 {
            mods = 0
        }
        if final == 65 { return some(Key.up(mods)) }
        if final == 66 { return some(Key.down(mods)) }
        if final == 67 { return some(Key.right(mods)) }
        if final == 68 { return some(Key.left(mods)) }
        if final == 72 { return some(Key.home(mods)) }
        if final == 70 { return some(Key.end(mods)) }
        if final == 126 {
            var p0: int = 0
            if params.len() >= 1 {
                p0 = params[0]
            }
            return self.tilde_key(p0, mods)
        }
        return none
    }

    // The `CSI n ~` family: `n` selects the key, the modifier rides alongside.
    fn tilde_key(p0: int, mods: int) -> Option<Key> {
        if p0 == 1 { return some(Key.home(mods)) }
        if p0 == 2 { return some(Key.insert(mods)) }
        if p0 == 3 { return some(Key.delete(mods)) }
        if p0 == 4 { return some(Key.end(mods)) }
        if p0 == 5 { return some(Key.page_up(mods)) }
        if p0 == 6 { return some(Key.page_down(mods)) }
        if p0 == 7 { return some(Key.home(mods)) }
        if p0 == 8 { return some(Key.end(mods)) }
        if p0 == 11 { return some(Key.function(1, mods)) }
        if p0 == 12 { return some(Key.function(2, mods)) }
        if p0 == 13 { return some(Key.function(3, mods)) }
        if p0 == 14 { return some(Key.function(4, mods)) }
        if p0 == 15 { return some(Key.function(5, mods)) }
        if p0 == 17 { return some(Key.function(6, mods)) }
        if p0 == 18 { return some(Key.function(7, mods)) }
        if p0 == 19 { return some(Key.function(8, mods)) }
        if p0 == 20 { return some(Key.function(9, mods)) }
        if p0 == 21 { return some(Key.function(10, mods)) }
        if p0 == 23 { return some(Key.function(11, mods)) }
        if p0 == 24 { return some(Key.function(12, mods)) }
        return none
    }

    // buffer is `ESC O <byte>`: SS3, the application-cursor form of the arrows
    // and F1–F4.
    fn decode_ss3() -> Option<Key> {
        if self.buffer.len() < 3 {
            return none
        }
        let c: int = self.buffer.get(2)
        var result: Key = Key.unknown(c)
        if c == 65 { result = Key.up(0) }
        else if c == 66 { result = Key.down(0) }
        else if c == 67 { result = Key.right(0) }
        else if c == 68 { result = Key.left(0) }
        else if c == 72 { result = Key.home(0) }
        else if c == 70 { result = Key.end(0) }
        else if c == 80 { result = Key.function(1, 0) }
        else if c == 81 { result = Key.function(2, 0) }
        else if c == 82 { result = Key.function(3, 0) }
        else if c == 83 { result = Key.function(4, 0) }
        self.consume(3)
        return some(result)
    }

    // buffer is `ESC <byte>` where the byte is neither `[` nor `O`: Alt + that
    // key. Alt is reported for a printable ASCII byte; anything else reports the
    // ESC as Escape and leaves the rest for the next call.
    fn decode_alt() -> Option<Key> {
        let b1: int = self.buffer.get(1)
        if b1 >= 32 && b1 < 127 {
            self.consume(2)
            return some(Key.alt(b1))
        }
        self.consume(1)
        return some(Key.escape)
    }
}
