// The parts of std.calendar the Python differential does not reach: the three
// HTTP date forms a recipient must accept, RFC 3339 offsets and fractions,
// calendar arithmetic across month and year boundaries, ordering, and every
// error path. Deterministic output, pinned by a golden and identical on both
// backends.

import std.io
import std.calendar

fn show(label: string, result: Result<calendar.DateTime>) {
    match result {
        ok(stamp) => { io.println("{label}: {stamp.to_rfc3339()}") }
        err(problem) => { io.println("{label}: err({problem.kind}) {problem.msg}") }
    }
}

fn show_int(label: string, result: Result<int>) {
    match result {
        ok(value) => { io.println("{label}: {value}") }
        err(problem) => { io.println("{label}: err({problem.kind}) {problem.msg}") }
    }
}

fn main() {
    let example: calendar.DateTime =
        calendar.DateTime.of(1994, 11, 6, 8, 49, 37, 0).expect("valid")

    // --- the three HTTP date forms, all naming the same instant -------------
    io.println("== http parse ==")
    show("imf   ", calendar.DateTime.parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT"))
    show("rfc850", calendar.DateTime.parse_http_date("Sunday, 06-Nov-94 08:49:37 GMT"))
    show("asctime", calendar.DateTime.parse_http_date("Sun Nov  6 08:49:37 1994"))
    io.println("format: {example.to_http_date()}")

    // A bad day name and a bad terminator are refused.
    show("bad-day ", calendar.DateTime.parse_http_date("Xxx, 06 Nov 1994 08:49:37 GMT"))
    show("bad-zone", calendar.DateTime.parse_http_date("Sun, 06 Nov 1994 08:49:37 UTC"))

    // --- RFC 3339 -----------------------------------------------------------
    io.println("== rfc3339 parse ==")
    show("basic  ", calendar.DateTime.parse_rfc3339("1994-11-06T08:49:37Z"))
    show("lower-t", calendar.DateTime.parse_rfc3339("1994-11-06t08:49:37z"))
    show("space  ", calendar.DateTime.parse_rfc3339("1994-11-06 08:49:37Z"))
    show("offset+", calendar.DateTime.parse_rfc3339("2024-03-05T09:30:00+05:30"))
    show("offset-", calendar.DateTime.parse_rfc3339("2024-03-05T09:30:00-08:00"))
    show("frac   ", calendar.DateTime.parse_rfc3339("1994-11-06T08:49:37.123456789Z"))
    show("leap60 ", calendar.DateTime.parse_rfc3339("2016-12-31T23:59:60Z"))
    show("no-zone", calendar.DateTime.parse_rfc3339("1994-11-06T08:49:37"))
    let fractional: calendar.DateTime =
        calendar.DateTime.parse_rfc3339("1994-11-06T08:49:37.123456789Z").expect("valid")
    io.println("frac-format: {fractional.to_rfc3339()}")

    // --- construction errors ------------------------------------------------
    io.println("== of() errors ==")
    show("feb29-1900", calendar.DateTime.of(1900, 2, 29, 0, 0, 0, 0))
    show("feb29-2000", calendar.DateTime.of(2000, 2, 29, 0, 0, 0, 0))
    show("month13   ", calendar.DateTime.of(2024, 13, 1, 0, 0, 0, 0))
    show("hour24    ", calendar.DateTime.of(2024, 1, 1, 24, 0, 0, 0))
    show("leap-sec  ", calendar.DateTime.of(2016, 12, 31, 23, 59, 60, 0))
    show("year0     ", calendar.DateTime.of(0, 1, 1, 0, 0, 0, 0))

    // --- epoch range guards -------------------------------------------------
    io.println("== epoch ranges ==")
    show("millis-huge", calendar.DateTime.from_epoch_millis(999999999999999999))
    // Year 9999 is inside a DateTime but past the i64 nanosecond window.
    let far: calendar.DateTime =
        calendar.DateTime.of(9999, 1, 1, 0, 0, 0, 0).expect("valid")
    show_int("nanos-9999", far.epoch_nanos())
    let near: calendar.DateTime =
        calendar.DateTime.of(2000, 1, 1, 0, 0, 0, 0).expect("valid")
    show_int("nanos-2000", near.epoch_nanos())

    // --- arithmetic ---------------------------------------------------------
    io.println("== arithmetic ==")
    let base: calendar.DateTime =
        calendar.DateTime.of(2024, 1, 31, 12, 0, 0, 0).expect("valid")
    show("plus1day ", base.plus_days(1))            // into February
    show("plus400d ", base.plus_days(400))          // across a leap year
    show("minus1day", base.plus_days(-32))          // back into December 2023
    let midnight: calendar.DateTime =
        calendar.DateTime.of(2024, 3, 1, 0, 0, 30, 0).expect("valid")
    show("minus60s ", midnight.plus_seconds(-60))   // wrap to the previous day
    show("plus90m  ", midnight.plus_minutes(90))
    show("plus25h  ", midnight.plus_hours(25))

    // --- ordering and gaps --------------------------------------------------
    io.println("== ordering ==")
    let earlier: calendar.DateTime =
        calendar.DateTime.of(2024, 1, 1, 0, 0, 0, 0).expect("valid")
    let later: calendar.DateTime =
        calendar.DateTime.of(2024, 1, 2, 0, 0, 0, 0).expect("valid")
    io.println("before={earlier.is_before(later)} after={earlier.is_after(later)} cmp={earlier.compare(later)}")
    io.println("seconds_until={earlier.seconds_until(later)} millis_until={earlier.millis_until(later)}")
    io.println("now_after_epoch={calendar.DateTime.now().is_after(calendar.DateTime.epoch())}")

    // --- calendar facts -----------------------------------------------------
    io.println("== facts ==")
    io.println("leap 2000={calendar.is_leap_year(2000)} 1900={calendar.is_leap_year(1900)} 2024={calendar.is_leap_year(2024)}")
    io.println("days feb2024={calendar.days_in_month(2024, 2)} feb2023={calendar.days_in_month(2023, 2)} apr={calendar.days_in_month(2024, 4)}")
    io.println("weekday {example.weekday().name()} short {example.weekday().short_name()} num {example.weekday().number()}")
    io.println("day_of_year {example.day_of_year()} epoch_day {example.epoch_day()}")
}
