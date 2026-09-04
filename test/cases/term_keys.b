// The CSI key decoder and the ANSI frame, exercised on fixed byte streams so the
// answers are the target's own and identical on both backends. No terminal is
// needed: the decoder is fed bytes and the frame is inspected by length.
import std.io
import std.term

fn bytes_of(values: List<int>) -> Bytes {
    var b: Bytes = new Bytes(0)
    for v: int in values {
        b.push(v)
    }
    return move b
}

fn drain(decoder: term.KeyDecoder) {
    var going: bool = true
    for going {
        match decoder.next() {
            some(key) => { io.println("  {key}") }
            none => { going = false }
        }
    }
}

fn main() {
    io.println("is_tty(stdin)={term.is_tty(0)}")

    // One decoder, one long tail: promotions of the shapes a terminal sends.
    var d: term.KeyDecoder = new term.KeyDecoder()
    d.feed(bytes_of([27, 91, 65]))                 // CSI A       up
    d.feed(bytes_of([27, 91, 66]))                 // CSI B       down
    d.feed(bytes_of([27, 91, 67]))                 // CSI C       right
    d.feed(bytes_of([27, 91, 68]))                 // CSI D       left
    d.feed(bytes_of([27, 91, 72]))                 // CSI H       home
    d.feed(bytes_of([27, 91, 70]))                 // CSI F       end
    d.feed(bytes_of([27, 91, 53, 126]))            // CSI 5 ~     page up
    d.feed(bytes_of([27, 91, 54, 126]))            // CSI 6 ~     page down
    d.feed(bytes_of([27, 91, 50, 126]))            // CSI 2 ~     insert
    d.feed(bytes_of([27, 91, 51, 126]))            // CSI 3 ~     delete
    d.feed(bytes_of([27, 91, 49, 59, 53, 67]))     // CSI 1;5 C   ctrl+right
    d.feed(bytes_of([27, 91, 49, 59, 50, 65]))     // CSI 1;2 A   shift+up
    d.feed(bytes_of([27, 91, 49, 59, 54, 68]))     // CSI 1;6 D   ctrl+shift+left
    d.feed(bytes_of([27, 91, 49, 53, 126]))        // CSI 15 ~    F5
    d.feed(bytes_of([27, 91, 50, 52, 126]))        // CSI 24 ~    F12
    d.feed(bytes_of([27, 91, 50, 48, 59, 53, 126])) // CSI 20;5 ~ ctrl+F9
    d.feed(bytes_of([27, 79, 80]))                 // SS3 P       F1
    d.feed(bytes_of([27, 79, 65]))                 // SS3 A       up (application mode)
    d.feed(bytes_of([104, 105]))                   // h i
    d.feed(bytes_of([13]))                         // CR          enter
    d.feed(bytes_of([9]))                          // TAB
    d.feed(bytes_of([3]))                          // Ctrl-C
    d.feed(bytes_of([1]))                          // Ctrl-A
    d.feed(bytes_of([127]))                        // DEL         backspace
    d.feed(bytes_of([27, 98]))                     // ESC b       alt+b
    d.feed(bytes_of([226, 152, 131]))              // U+2603 snowman
    io.println("stream:")
    drain(d)

    // A sequence split across two feeds is one key, not two wrong ones.
    io.println("split:")
    var s: term.KeyDecoder = new term.KeyDecoder()
    s.feed(bytes_of([27, 91]))
    drain(s)                                        // nothing — incomplete
    s.feed(bytes_of([49, 59, 53, 66]))              // ...1;5 B    ctrl+down
    drain(s)

    // A UTF-8 character split down the middle.
    io.println("split-utf8:")
    var u: term.KeyDecoder = new term.KeyDecoder()
    u.feed(bytes_of([226, 152]))
    drain(u)                                        // nothing — incomplete
    u.feed(bytes_of([131]))
    drain(u)

    // A lone ESC is held until flush decides it is the Escape key.
    io.println("lone-esc:")
    var e: term.KeyDecoder = new term.KeyDecoder()
    e.feed(bytes_of([27]))
    drain(e)                                        // nothing — incomplete
    match e.flush() {
        some(key) => { io.println("  flush {key}") }
        none => { io.println("  flush none") }
    }

    // The modifier mask reads back the way a terminal packs it.
    io.println("mods(1)={term.has_shift(1)},{term.has_alt(1)},{term.has_ctrl(1)}")
    io.println("mods(4)={term.has_shift(4)},{term.has_alt(4)},{term.has_ctrl(4)}")
    io.println("mods(5)={term.has_shift(5)},{term.has_alt(5)},{term.has_ctrl(5)}")

    // The frame builds escape-and-text bytes; assert what went in.
    var f: term.Frame = new term.Frame()
    f.enter_alt_screen()
    f.hide_cursor()
    f.clear()
    f.move_to(3, 10)
    f.fg(1)
    f.bg_rgb(20, 30, 40)
    f.bold()
    f.text("hi")
    f.reset_style()
    f.show_cursor()
    f.leave_alt_screen()
    io.println("frame_bytes={f.len()}")
}
