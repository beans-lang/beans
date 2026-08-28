// The civil calendar: a date and time of day, its conversions to and from the
// epoch, and the two wire formats a program actually meets — RFC 9110 HTTP
// dates and RFC 3339 timestamps.
//
// `std.time` names moments in nanoseconds and knows nothing about years; this
// package is the other half. It is separate from `std.time` rather than part
// of it because `std.time`'s clocks are compiler builtins, and a Beans package
// named `std.time` cannot call them without importing itself.
//
// UTC ONLY. There is no local time, no zone database and no daylight-saving
// rule here, on purpose: a wrong timezone answer is worse than no timezone
// answer, and the rules change by political decision several times a year. A
// parsed offset is arithmetic, not a zone — `2024-03-05T09:30:00+05:30` is
// read as the instant it names and stored as UTC.
//
// LEAP SECONDS ARE NOT MODELLED. Every minute here has exactly 60 seconds and
// every day exactly 86400, which is what the epoch counters in `std.time`
// already assume. `second` is therefore 0..=59, and a timestamp written with
// `:60` is refused rather than quietly moved.
//
// The two conversion kernels, `days_from_civil` and its inverse, are Howard
// Hinnant's, from "chrono-Compatible Low-Level Date Algorithms"
// (https://howardhinnant.github.io/date_algorithms.html), which is in the
// public domain. They use the proleptic Gregorian calendar — the Gregorian
// leap rule extended backwards through the years it was not yet in use — so
// year 1500 here is Gregorian, not Julian.

package calendar

import std.time as clock

// Beans has no package-level constants, so the fixed numbers are functions.
// Each is one literal, and both backends fold them away.
fn nanos_per_second() -> int { return 1000000000 }
fn nanos_per_day() -> int { return 86400000000000 }
fn seconds_per_day() -> int { return 86400 }
fn seconds_per_hour() -> int { return 3600 }
fn seconds_per_minute() -> int { return 60 }

// The years a DateTime holds. RFC 3339 and RFC 9110 both write the year in
// four digits, so a value outside this range has no wire form.
fn min_year() -> int { return 1 }
fn max_year() -> int { return 9999 }

// Epoch seconds at 0001-01-01T00:00:00Z and 9999-12-31T23:59:59Z.
// test/calendar.sh checks both against days_from_civil so they cannot drift.
fn min_epoch_seconds() -> int { return -62135596800 }
fn max_epoch_seconds() -> int { return 253402300799 }

// The i64 nanosecond window, which is what `std.time.wall_nanos` speaks:
// 1677-09-21T00:12:43.145224192Z through 2262-04-11T23:47:16.854775807Z.
fn min_nanos_second() -> int { return -9223372037 }
fn max_nanos_second() -> int { return 9223372036 }
fn min_nanos_fraction() -> int { return 145224192 }
fn max_nanos_fraction() -> int { return 854775807 }

/// Days of the week, Sunday first — the order the day-number arithmetic
/// produces, not a claim about which day starts a week.
pub enum Weekday {
    sunday
    monday
    tuesday
    wednesday
    thursday
    friday
    saturday

    /// The English name: `Sunday`.
    pub fn name() -> string {
        return match self {
            sunday => "Sunday",
            monday => "Monday",
            tuesday => "Tuesday",
            wednesday => "Wednesday",
            thursday => "Thursday",
            friday => "Friday",
            saturday => "Saturday",
        }
    }

    /// The three-letter form HTTP dates use: `Sun`.
    pub fn short_name() -> string {
        return match self {
            sunday => "Sun",
            monday => "Mon",
            tuesday => "Tue",
            wednesday => "Wed",
            thursday => "Thu",
            friday => "Fri",
            saturday => "Sat",
        }
    }

    /// 0 for Sunday through 6 for Saturday.
    pub fn number() -> int {
        return match self {
            sunday => 0,
            monday => 1,
            tuesday => 2,
            wednesday => 3,
            thursday => 4,
            friday => 5,
            saturday => 6,
        }
    }
}

fn weekday_of(number: int) -> Weekday {
    return match number {
        0 => Weekday.sunday,
        1 => Weekday.monday,
        2 => Weekday.tuesday,
        3 => Weekday.wednesday,
        4 => Weekday.thursday,
        5 => Weekday.friday,
        _ => Weekday.saturday,
    }
}

// Floor division and modulus. Beans `/` truncates toward zero like C, which
// puts a negative epoch on the wrong day: one second before the epoch is day
// -1, not day 0.
fn floor_div(value: int, divisor: int) -> int {
    var quotient: int = value / divisor
    if value % divisor != 0 && ((value < 0) != (divisor < 0)) {
        quotient -= 1
    }
    return quotient
}

fn floor_mod(value: int, divisor: int) -> int {
    return value - floor_div(value, divisor) * divisor
}

/// True when `year` has a 29th of February, under the proleptic Gregorian
/// rule: divisible by 4, except centuries, except every fourth century.
pub fn is_leap_year(year: int) -> bool {
    if year % 4 != 0 { return false }
    if year % 100 != 0 { return true }
    return year % 400 == 0
}

/// Days in `month` (1..=12) of `year`. A month outside 1..=12 answers 0.
pub fn days_in_month(year: int, month: int) -> int {
    if month == 1 || month == 3 || month == 5 || month == 7 ||
       month == 8 || month == 10 || month == 12 {
        return 31
    }
    if month == 4 || month == 6 || month == 9 || month == 11 {
        return 30
    }
    if month == 2 {
        return if is_leap_year(year) { 29 } else { 28 }
    }
    return 0
}

/// Days from 1970-01-01 to `year`-`month`-`day`, negative before the epoch.
///
/// Howard Hinnant's `days_from_civil`. The era trick — 400 years, 146097 days,
/// with March starting the shifted year — is what keeps it branch-light and
/// exact for negative years, where a naive leap-year loop goes wrong.
pub fn days_from_civil(year: int, month: int, day: int) -> int {
    let shifted: int = if month <= 2 { year - 1 } else { year }
    let era: int = floor_div(shifted, 400)
    let year_of_era: int = shifted - era * 400
    let month_shift: int = if month > 2 { month - 3 } else { month + 9 }
    let day_of_year: int = (153 * month_shift + 2) / 5 + day - 1
    let day_of_era: int =
        year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year
    return era * 146097 + day_of_era - 719468
}

// One civil date recovered from a day number. Hinnant's `civil_from_days`,
// the exact inverse of days_from_civil over the whole int range.
struct CivilDate {
    year: int
    month: int
    day: int
}

fn civil_from_days(days: int) -> CivilDate {
    let shifted: int = days + 719468
    let era: int = floor_div(shifted, 146097)
    let day_of_era: int = shifted - era * 146097
    let year_of_era: int =
        (day_of_era - day_of_era / 1460 + day_of_era / 36524 -
         day_of_era / 146096) / 365
    let year: int = year_of_era + era * 400
    let day_of_year: int =
        day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100)
    let month_shift: int = (5 * day_of_year + 2) / 153
    let day: int = day_of_year - (153 * month_shift + 2) / 5 + 1
    let month: int =
        if month_shift < 10 { month_shift + 3 } else { month_shift - 9 }
    return CivilDate {
        year: if month <= 2 { year + 1 } else { year },
        month: month,
        day: day,
    }
}

// The weekday of a day number counted from 1970-01-01, which was a Thursday.
fn weekday_from_days(days: int) -> Weekday {
    return weekday_of(floor_mod(days + 4, 7))
}

// Zero-padded decimal for a non-negative value, used by every formatter here.
fn pad(value: int, width: int) -> string {
    var text: string = "{value}"
    for text.len() < width {
        text = "0{text}"
    }
    return text
}

fn month_short_name(month: int) -> string {
    return match month {
        1 => "Jan",
        2 => "Feb",
        3 => "Mar",
        4 => "Apr",
        5 => "May",
        6 => "Jun",
        7 => "Jul",
        8 => "Aug",
        9 => "Sep",
        10 => "Oct",
        11 => "Nov",
        _ => "Dec",
    }
}

/// A civil date and time of day in UTC, to nanosecond resolution.
///
/// The fields are public and read directly (`stamp.year`, `stamp.second`), the
/// way `net.Address` reads its host and port. Build one through `DateTime.of`,
/// `DateTime.now` or a `from_epoch_*` factory: those are the paths that check
/// the field ranges, and every method here assumes a value one of them made.
///
/// ```
/// import std.calendar
/// import std.time
///
/// let stamp: calendar.DateTime =
///     calendar.DateTime.from_epoch_nanos(time.wall_nanos())
/// io.println(stamp.to_http_date())     // Sun, 06 Nov 1994 08:49:37 GMT
/// io.println(stamp.to_rfc3339())       // 1994-11-06T08:49:37Z
/// ```
pub struct DateTime {
    /// The proleptic Gregorian year, 1..=9999 for any value a factory built.
    pub year: int
    /// 1..=12.
    pub month: int
    /// 1..=31, never past the length of `month`.
    pub day: int
    /// 0..=23.
    pub hour: int
    /// 0..=59.
    pub minute: int
    /// 0..=59. Leap seconds are not modelled, so 60 never appears.
    pub second: int
    /// 0..=999999999.
    pub nanosecond: int

    /// The moment the wall clock reports. It moves backwards when someone sets
    /// the date, so measure a duration with `std.time.monotonic_nanos`
    /// instead — a calendar cannot.
    pub static fn now() -> DateTime {
        return DateTime.from_epoch_nanos(clock.wall_nanos())
    }

    /// 1970-01-01T00:00:00Z, the moment every epoch count is measured from.
    pub static fn epoch() -> DateTime {
        return DateTime {
            year: 1970, month: 1, day: 1,
            hour: 0, minute: 0, second: 0, nanosecond: 0,
        }
    }

    /// A moment from nanoseconds since 1970-01-01T00:00:00Z, negative before
    /// it. This one cannot fail: every `int` nanosecond count lands between
    /// 1677 and 2262, well inside the years a `DateTime` holds.
    pub static fn from_epoch_nanos(nanos: int) -> DateTime {
        let seconds: int = floor_div(nanos, nanos_per_second())
        let fraction: int = nanos - seconds * nanos_per_second()
        return build_from_seconds(seconds, fraction)
    }

    /// A moment from milliseconds since the epoch. `int` milliseconds reach far
    /// past year 9999, so a value outside the calendar is an `err` with kind
    /// `range` rather than a nonsense year.
    pub static fn from_epoch_millis(millis: int) -> Result<DateTime> {
        let seconds: int = floor_div(millis, 1000)
        let fraction: int = (millis - seconds * 1000) * 1000000
        if seconds < min_epoch_seconds() || seconds > max_epoch_seconds() {
            return err(
                "epoch millisecond {millis} is outside years 1..9999", "range")
        }
        return ok(build_from_seconds(seconds, fraction))
    }

    /// A moment from whole seconds since the epoch. Outside years 1..=9999 this
    /// is an `err` with kind `range`, for the same reason as
    /// `from_epoch_millis`.
    pub static fn from_epoch_seconds(seconds: int) -> Result<DateTime> {
        if seconds < min_epoch_seconds() || seconds > max_epoch_seconds() {
            return err(
                "epoch second {seconds} is outside years 1..9999", "range")
        }
        return ok(build_from_seconds(seconds, 0))
    }

    /// A checked civil moment. Every field is validated against the calendar —
    /// 2023-02-29 is an `err`, 2024-02-29 is not — and the error names the
    /// field that was wrong, with kind `invalid`.
    pub static fn of(year: int, month: int, day: int,
                     hour: int, minute: int, second: int,
                     nanosecond: int) -> Result<DateTime> {
        if year < min_year() || year > max_year() {
            return err("year {year} is outside 1..9999", "invalid")
        }
        if month < 1 || month > 12 {
            return err("month {month} is outside 1..12", "invalid")
        }
        let last: int = days_in_month(year, month)
        if day < 1 || day > last {
            return err(
                "day {day} is outside 1..{last} for {year}-{pad(month, 2)}",
                "invalid")
        }
        if hour < 0 || hour > 23 {
            return err("hour {hour} is outside 0..23", "invalid")
        }
        if minute < 0 || minute > 59 {
            return err("minute {minute} is outside 0..59", "invalid")
        }
        if second == 60 {
            return err(
                "second 60 is a leap second, which this calendar does not model",
                "invalid")
        }
        if second < 0 || second > 59 {
            return err("second {second} is outside 0..59", "invalid")
        }
        if nanosecond < 0 || nanosecond >= nanos_per_second() {
            return err(
                "nanosecond {nanosecond} is outside 0..999999999", "invalid")
        }
        return ok(DateTime {
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second,
            nanosecond: nanosecond,
        })
    }

    /// Midnight on a checked civil date — `DateTime.of` with a zero time.
    pub static fn of_date(year: int, month: int, day: int) -> Result<DateTime> {
        return DateTime.of(year, month, day, 0, 0, 0, 0)
    }

    /// RFC 3339 text, with or without a fraction, and ending in `Z` or a
    /// numeric offset. An offset is converted to UTC, which is arithmetic
    /// rather than a timezone rule. The `T` may be lower case or a single
    /// space, as RFC 3339 permits. A `:60` second is refused: this calendar
    /// does not model leap seconds, and moving one silently would be a wrong
    /// answer.
    pub static fn parse_rfc3339(text: string) -> Result<DateTime> {
        return parse_rfc3339_text(text)
    }

    /// An HTTP date in any of the three forms RFC 9110 requires a recipient to
    /// accept: IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), the obsolete
    /// RFC 850 form (`Sunday, 06-Nov-94 08:49:37 GMT`), and asctime
    /// (`Sun Nov  6 08:49:37 1994`).
    ///
    /// The day name must be one of the seven but need not agree with the date,
    /// because RFC 9110 calls it redundant. A two-digit RFC 850 year is read as
    /// 1970..2069: RFC 9110's sliding fifty-year window would make parsing
    /// depend on the current clock, and a parser whose answer changes with the
    /// date is worse than a fixed window.
    pub static fn parse_http_date(text: string) -> Result<DateTime> {
        return parse_http_date_text(text)
    }

    /// Days from 1970-01-01 to this date, negative before it.
    pub fn epoch_day() -> int {
        return days_from_civil(self.year, self.month, self.day)
    }

    /// Seconds since 1970-01-01T00:00:00Z, negative before it. Exact for every
    /// year a `DateTime` holds.
    pub fn epoch_seconds() -> int {
        return self.epoch_day() * seconds_per_day() +
               self.hour * seconds_per_hour() +
               self.minute * seconds_per_minute() +
               self.second
    }

    /// Milliseconds since the epoch. The fraction is truncated toward the
    /// past for a moment before the epoch, the direction `epoch_seconds`
    /// already truncates.
    pub fn epoch_millis() -> int {
        return self.epoch_seconds() * 1000 + self.nanosecond / 1000000
    }

    /// Nanoseconds since the epoch, the unit `std.time.wall_nanos` speaks.
    ///
    /// This is the one conversion that can fail: `int` nanoseconds only reach
    /// from 1677-09-21 to 2262-04-11, while a `DateTime` reaches year 9999. A
    /// moment outside that window is an `err` with kind `range`. Anything built
    /// by `from_epoch_nanos` or `now` is always inside it.
    pub fn epoch_nanos() -> Result<int> {
        let seconds: int = self.epoch_seconds()
        if seconds < min_nanos_second() || seconds > max_nanos_second() {
            return err(
                "{self.to_rfc3339()} is outside the nanosecond epoch range",
                "range")
        }
        // Both ends of the window stop part-way through a second, so the
        // fraction is checked against what is actually left rather than
        // assumed to fit.
        if seconds == max_nanos_second() &&
           self.nanosecond > max_nanos_fraction() {
            return err(
                "{self.to_rfc3339()} is outside the nanosecond epoch range",
                "range")
        }
        if seconds == min_nanos_second() &&
           self.nanosecond < min_nanos_fraction() {
            return err(
                "{self.to_rfc3339()} is outside the nanosecond epoch range",
                "range")
        }
        return ok(seconds * nanos_per_second() + self.nanosecond)
    }

    /// The day of the week this date falls on.
    pub fn weekday() -> Weekday {
        return weekday_from_days(self.epoch_day())
    }

    /// 1 on the 1st of January, 365 or 366 on the 31st of December.
    pub fn day_of_year() -> int {
        return self.epoch_day() - days_from_civil(self.year, 1, 1) + 1
    }

    /// This moment plus `nanos` nanoseconds; `err` with kind `range` when the
    /// result leaves years 1..=9999.
    pub fn plus_nanos(nanos: int) -> Result<DateTime> {
        let days: int = floor_div(nanos, nanos_per_day())
        let rest: int = nanos - days * nanos_per_day()
        let moved: DateTime = self.shift_days(days)?
        return moved.shift_nanos_within_day(rest)
    }

    /// This moment plus `seconds` seconds; `err` with kind `range` when the
    /// result leaves years 1..=9999.
    pub fn plus_seconds(seconds: int) -> Result<DateTime> {
        let days: int = floor_div(seconds, seconds_per_day())
        let rest: int = seconds - days * seconds_per_day()
        let moved: DateTime = self.shift_days(days)?
        return moved.shift_nanos_within_day(rest * nanos_per_second())
    }

    /// This moment plus `minutes` minutes.
    pub fn plus_minutes(minutes: int) -> Result<DateTime> {
        if minutes < -153722867280912 || minutes > 153722867280912 {
            return err("adding {minutes} minutes leaves the calendar", "range")
        }
        return self.plus_seconds(minutes * seconds_per_minute())
    }

    /// This moment plus `hours` hours.
    pub fn plus_hours(hours: int) -> Result<DateTime> {
        if hours < -2562047788015 || hours > 2562047788015 {
            return err("adding {hours} hours leaves the calendar", "range")
        }
        return self.plus_seconds(hours * seconds_per_hour())
    }

    /// The same time of day, `days` days later. This is calendar arithmetic
    /// rather than 86400-second arithmetic — with no zones and no daylight
    /// saving the two agree, which is part of why zones are left out.
    pub fn plus_days(days: int) -> Result<DateTime> {
        return self.shift_days(days)
    }

    // Move the date by whole days, keeping the time of day. The day number is
    // checked before it is converted back, so an absurd operand cannot produce
    // a year the formatters would then have to render.
    fn shift_days(days: int) -> Result<DateTime> {
        let first: int = days_from_civil(min_year(), 1, 1)
        let last: int = days_from_civil(max_year(), 12, 31)
        let here: int = self.epoch_day()
        if days < first - here || days > last - here {
            return err("adding {days} days leaves the calendar", "range")
        }
        let moved: CivilDate = civil_from_days(here + days)
        return ok(DateTime {
            year: moved.year, month: moved.month, day: moved.day,
            hour: self.hour, minute: self.minute, second: self.second,
            nanosecond: self.nanosecond,
        })
    }

    // Add a nanosecond count smaller in magnitude than one day, carrying into
    // the date when the time of day wraps.
    fn shift_nanos_within_day(nanos: int) -> Result<DateTime> {
        let start: int =
            self.hour * seconds_per_hour() * nanos_per_second() +
            self.minute * seconds_per_minute() * nanos_per_second() +
            self.second * nanos_per_second() + self.nanosecond
        let total: int = start + nanos
        let carry: int = floor_div(total, nanos_per_day())
        let within: int = total - carry * nanos_per_day()
        var moved: DateTime = self
        if carry != 0 {
            moved = self.shift_days(carry)?
        }
        let whole: int = within / nanos_per_second()
        return ok(DateTime {
            year: moved.year, month: moved.month, day: moved.day,
            hour: whole / seconds_per_hour(),
            minute: (whole / seconds_per_minute()) % 60,
            second: whole % 60,
            nanosecond: within - whole * nanos_per_second(),
        })
    }

    /// Whole seconds from this moment to `other`, negative when `other` is
    /// earlier. Exact across the whole calendar.
    pub fn seconds_until(other: DateTime) -> int {
        return other.epoch_seconds() - self.epoch_seconds()
    }

    /// Whole milliseconds from this moment to `other`, negative when `other`
    /// is earlier.
    pub fn millis_until(other: DateTime) -> int {
        return other.epoch_millis() - self.epoch_millis()
    }

    /// -1, 0 or 1 as this moment sorts before, with, or after `other`.
    pub fn compare(other: DateTime) -> int {
        if self.year != other.year {
            return if self.year < other.year { -1 } else { 1 }
        }
        if self.month != other.month {
            return if self.month < other.month { -1 } else { 1 }
        }
        if self.day != other.day {
            return if self.day < other.day { -1 } else { 1 }
        }
        if self.hour != other.hour {
            return if self.hour < other.hour { -1 } else { 1 }
        }
        if self.minute != other.minute {
            return if self.minute < other.minute { -1 } else { 1 }
        }
        if self.second != other.second {
            return if self.second < other.second { -1 } else { 1 }
        }
        if self.nanosecond != other.nanosecond {
            return if self.nanosecond < other.nanosecond { -1 } else { 1 }
        }
        return 0
    }

    /// True when this moment is earlier than `other`.
    pub fn is_before(other: DateTime) -> bool {
        return self.compare(other) < 0
    }

    /// True when this moment is later than `other`.
    pub fn is_after(other: DateTime) -> bool {
        return self.compare(other) > 0
    }

    /// `1994-11-06`.
    pub fn to_date_string() -> string {
        return "{pad(self.year, 4)}-{pad(self.month, 2)}-{pad(self.day, 2)}"
    }

    /// `08:49:37`, without the fraction.
    pub fn to_time_string() -> string {
        return "{pad(self.hour, 2)}:{pad(self.minute, 2)}:{pad(self.second, 2)}"
    }

    /// RFC 3339 / ISO 8601: `1994-11-06T08:49:37Z`, or
    /// `1994-11-06T08:49:37.123456789Z` when there is a fraction. The fraction
    /// is written with all nine digits or not at all, so the text round-trips
    /// through `DateTime.parse_rfc3339` exactly.
    pub fn to_rfc3339() -> string {
        let stamp: string = "{self.to_date_string()}T{self.to_time_string()}"
        if self.nanosecond == 0 {
            return "{stamp}Z"
        }
        return "{stamp}.{pad(self.nanosecond, 9)}Z"
    }

    /// The HTTP date, RFC 9110's IMF-fixdate:
    /// `Sun, 06 Nov 1994 08:49:37 GMT`. This is the only form a sender may
    /// produce, and the one a `Date`, `Last-Modified` or `Expires` header
    /// wants. The fraction is dropped — the format has no room for one.
    pub fn to_http_date() -> string {
        let day: string = "{pad(self.day, 2)}"
        let month: string = month_short_name(self.month)
        let year: string = "{pad(self.year, 4)}"
        return "{self.weekday().short_name()}, {day} {month} {year} {self.to_time_string()} GMT"
    }
}

// ---- parsing ---------------------------------------------------------------

fn digit_at(text: string, index: int) -> int {
    if index < 0 || index >= text.len() { return -1 }
    let byte: int = text.byte_at(index)
    if byte < 48 || byte > 57 { return -1 }
    return byte - 48
}

// A fixed-width run of digits, or -1 when any of them is missing.
fn digits_at(text: string, start: int, count: int) -> int {
    var value: int = 0
    for index: int in 0..count {
        let digit: int = digit_at(text, start + index)
        if digit < 0 { return -1 }
        value = value * 10 + digit
    }
    return value
}

fn byte_is(text: string, index: int, byte: int) -> bool {
    if index < 0 || index >= text.len() { return false }
    return text.byte_at(index) == byte
}

// 1..=12 for a three-letter English month name, 0 for anything else.
fn month_number(name: string) -> int {
    for index: int in 1..13 {
        if month_short_name(index) == name { return index }
    }
    return 0
}

fn is_weekday_short(name: string) -> bool {
    for index: int in 0..7 {
        if weekday_of(index).short_name() == name { return true }
    }
    return false
}

fn is_weekday_long(name: string) -> bool {
    for index: int in 0..7 {
        if weekday_of(index).name() == name { return true }
    }
    return false
}

fn build_from_seconds(seconds: int, nanosecond: int) -> DateTime {
    let days: int = floor_div(seconds, seconds_per_day())
    let within: int = seconds - days * seconds_per_day()
    let date: CivilDate = civil_from_days(days)
    return DateTime {
        year: date.year, month: date.month, day: date.day,
        hour: within / seconds_per_hour(),
        minute: (within / seconds_per_minute()) % 60,
        second: within % 60,
        nanosecond: nanosecond,
    }
}

fn parse_rfc3339_text(text: string) -> Result<DateTime> {
    if text.len() < 20 {
        return err("'{text}' is too short for an RFC 3339 timestamp", "invalid")
    }
    let year: int = digits_at(text, 0, 4)
    let month: int = digits_at(text, 5, 2)
    let day: int = digits_at(text, 8, 2)
    if year < 0 || month < 0 || day < 0 ||
       !byte_is(text, 4, 45) || !byte_is(text, 7, 45) {
        return err("'{text}' is not an RFC 3339 date", "invalid")
    }
    // RFC 3339 section 5.6 writes 'T'; its NOTE allows a lower-case 't' or a
    // single space where a human reads the value.
    if !byte_is(text, 10, 84) && !byte_is(text, 10, 116) &&
       !byte_is(text, 10, 32) {
        return err("'{text}' has no date/time separator", "invalid")
    }
    let hour: int = digits_at(text, 11, 2)
    let minute: int = digits_at(text, 14, 2)
    let second: int = digits_at(text, 17, 2)
    if hour < 0 || minute < 0 || second < 0 ||
       !byte_is(text, 13, 58) || !byte_is(text, 16, 58) {
        return err("'{text}' is not an RFC 3339 time", "invalid")
    }
    var cursor: int = 19
    var nanosecond: int = 0
    if byte_is(text, cursor, 46) {
        cursor += 1
        var digits: int = 0
        var scale: int = 100000000
        for digit_at(text, cursor) >= 0 {
            if digits < 9 {
                nanosecond += digit_at(text, cursor) * scale
                scale = scale / 10
            }
            digits += 1
            cursor += 1
        }
        if digits == 0 {
            return err("'{text}' has a '.' with no fraction", "invalid")
        }
    }
    var offset_seconds: int = 0
    if byte_is(text, cursor, 90) || byte_is(text, cursor, 122) {
        cursor += 1
    } else if byte_is(text, cursor, 43) || byte_is(text, cursor, 45) {
        let negative: bool = byte_is(text, cursor, 45)
        let offset_hour: int = digits_at(text, cursor + 1, 2)
        let offset_minute: int = digits_at(text, cursor + 4, 2)
        if offset_hour < 0 || offset_minute < 0 ||
           !byte_is(text, cursor + 3, 58) {
            return err("'{text}' has a malformed UTC offset", "invalid")
        }
        if offset_hour > 23 || offset_minute > 59 {
            return err("'{text}' has a UTC offset outside 23:59", "invalid")
        }
        offset_seconds = offset_hour * seconds_per_hour() +
                         offset_minute * seconds_per_minute()
        if negative { offset_seconds = -offset_seconds }
        cursor += 6
    } else {
        return err("'{text}' has no UTC offset", "invalid")
    }
    if cursor != text.len() {
        return err("'{text}' has trailing characters", "invalid")
    }
    let local: DateTime =
        DateTime.of(year, month, day, hour, minute, second, nanosecond)?
    if offset_seconds == 0 { return ok(local) }
    return local.plus_seconds(-offset_seconds)
}

fn parse_http_date_text(text: string) -> Result<DateTime> {
    // IMF-fixdate: Sun, 06 Nov 1994 08:49:37 GMT — 29 bytes with every field
    // at a fixed offset, which is what the "fixdate" name promises.
    if text.len() == 29 && byte_is(text, 3, 44) && byte_is(text, 4, 32) {
        if !is_weekday_short(text.slice(0, 3)) {
            return err("'{text}' has no valid day name", "invalid")
        }
        let day: int = digits_at(text, 5, 2)
        let month: int = month_number(text.slice(8, 11))
        let year: int = digits_at(text, 12, 4)
        if day < 0 || month == 0 || year < 0 ||
           !byte_is(text, 7, 32) || !byte_is(text, 11, 32) ||
           !byte_is(text, 16, 32) {
            return err("'{text}' is not an IMF-fixdate", "invalid")
        }
        if text.slice(26, 29) != "GMT" {
            return err("'{text}' does not end in GMT", "invalid")
        }
        return parse_time_of_day(text, 17, day, month, year)
    }
    // asctime: Sun Nov  6 08:49:37 1994 — 24 bytes, and the only form whose
    // day is space-padded rather than zero-padded.
    if text.len() == 24 && byte_is(text, 3, 32) {
        if !is_weekday_short(text.slice(0, 3)) {
            return err("'{text}' has no valid day name", "invalid")
        }
        let month: int = month_number(text.slice(4, 7))
        if month == 0 || !byte_is(text, 7, 32) {
            return err("'{text}' is not an asctime date", "invalid")
        }
        var day: int = digits_at(text, 8, 2)
        if day < 0 {
            if !byte_is(text, 8, 32) {
                return err("'{text}' has a malformed day", "invalid")
            }
            day = digits_at(text, 9, 1)
            if day < 0 {
                return err("'{text}' has a malformed day", "invalid")
            }
        }
        let year: int = digits_at(text, 20, 4)
        if year < 0 || !byte_is(text, 10, 32) || !byte_is(text, 19, 32) {
            return err("'{text}' is not an asctime date", "invalid")
        }
        return parse_time_of_day(text, 11, day, month, year)
    }
    // rfc850-date: Sunday, 06-Nov-94 08:49:37 GMT. The day name is a full
    // name, so its length decides where every later field starts.
    let comma: int = text.find(",").or(-1)
    if comma > 0 && is_weekday_long(text.slice(0, comma)) {
        let start: int = comma + 2
        if text.len() != start + 22 || !byte_is(text, comma + 1, 32) {
            return err("'{text}' is not an RFC 850 date", "invalid")
        }
        let day: int = digits_at(text, start, 2)
        let month: int = month_number(text.slice(start + 3, start + 6))
        let short_year: int = digits_at(text, start + 7, 2)
        if day < 0 || month == 0 || short_year < 0 ||
           !byte_is(text, start + 2, 45) || !byte_is(text, start + 6, 45) ||
           !byte_is(text, start + 9, 32) {
            return err("'{text}' is not an RFC 850 date", "invalid")
        }
        if text.slice(start + 19, start + 22) != "GMT" {
            return err("'{text}' does not end in GMT", "invalid")
        }
        let year: int =
            if short_year >= 70 { 1900 + short_year } else { 2000 + short_year }
        return parse_time_of_day(text, start + 10, day, month, year)
    }
    return err("'{text}' is not an HTTP date", "invalid")
}

// `HH:MM:SS` at a fixed offset, joined to an already-parsed date.
fn parse_time_of_day(text: string, at: int, day: int, month: int,
                     year: int) -> Result<DateTime> {
    let hour: int = digits_at(text, at, 2)
    let minute: int = digits_at(text, at + 3, 2)
    let second: int = digits_at(text, at + 6, 2)
    if hour < 0 || minute < 0 || second < 0 ||
       !byte_is(text, at + 2, 58) || !byte_is(text, at + 5, 58) {
        return err("'{text}' has a malformed time of day", "invalid")
    }
    return DateTime.of(year, month, day, hour, minute, second, 0)
}
