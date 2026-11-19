//! Calendar arithmetic and the reader's optional temporal hints.
//!
//! Everything here is pure: dates come from the caller (the trusted question
//! date, `time.validAt`) and nothing reads a clock. Two hints are built here
//! for `options.temporalHints`:
//!
//! * `writeOffset`: a session's distance from the question date, appended to
//!   its header (`10 days ago`, `~3 months (98 days) ago`);
//! * `resolveTimeReferences`: relative time expressions in the question,
//!   resolved to absolute dates (`"last month" = 2023-04-01 to 2023-04-30`).
//!
//! The resolver is a fixed phrase grammar over the question's own words. It
//! only restates those words as dates; it never changes retrieval or routing.
const std = @import("std");

pub const CivilDate = struct {
    year: i32,
    month: u8,
    day: u8,

    pub fn eql(self: CivilDate, other: CivilDate) bool {
        return self.year == other.year and self.month == other.month and self.day == other.day;
    }
};

/// The `YYYY-MM-DD` prefix of an ISO timestamp.
pub fn parseIsoDate(timestamp: []const u8) !CivilDate {
    if (timestamp.len < 10 or timestamp[4] != '-' or timestamp[7] != '-') return error.InvalidDate;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |index| {
        if (!std.ascii.isDigit(timestamp[index])) return error.InvalidDate;
    }
    const year = try std.fmt.parseInt(i32, timestamp[0..4], 10);
    const month = try std.fmt.parseInt(u8, timestamp[5..7], 10);
    const day = try std.fmt.parseInt(u8, timestamp[8..10], 10);
    if (month < 1 or month > 12) return error.InvalidDate;
    if (day < 1 or day > daysInMonth(year, month)) return error.InvalidDate;
    return .{ .year = year, .month = month, .day = day };
}

/// Days since 1970-01-01 in the proleptic Gregorian calendar.
pub fn daysFromCivil(date: CivilDate) i64 {
    const month: i64 = date.month;
    const year: i64 = if (month <= 2) @as(i64, date.year) - 1 else date.year;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month = @mod(month + 9, 12);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + @as(i64, date.day) - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

/// Inverse of `daysFromCivil`.
pub fn civilFromDays(days: i64) CivilDate {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const day_of_era = z - era * 146097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const shifted_month = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * shifted_month + 2, 5) + 1;
    const month = if (shifted_month < 10) shifted_month + 3 else shifted_month - 9;
    const year = year_of_era + era * 400 + @as(i64, if (month <= 2) 1 else 0);
    return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
}

pub fn addDays(date: CivilDate, days: i64) CivilDate {
    return civilFromDays(daysFromCivil(date) + days);
}

/// Calendar month shift. The day is clamped to the target month, so
/// 2024-03-31 minus one month is 2024-02-29 and 2024-02-29 minus twelve
/// months is 2023-02-28.
pub fn addMonths(date: CivilDate, months: i64) CivilDate {
    const index = @as(i64, date.year) * 12 + @as(i64, date.month) - 1 + months;
    const year: i32 = @intCast(@divFloor(index, 12));
    const month: u8 = @intCast(@mod(index, 12) + 1);
    return .{ .year = year, .month = month, .day = @min(date.day, daysInMonth(year, month)) };
}

/// 0 = Monday ... 6 = Sunday.
pub fn isoWeekday(date: CivilDate) u8 {
    // 1970-01-01 was a Thursday.
    return @intCast(@mod(daysFromCivil(date) + 3, 7));
}

const weekday_names = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };

pub fn weekdayName(date: CivilDate) []const u8 {
    return weekday_names[isoWeekday(date)];
}

pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 30,
    };
}

pub fn isLeapYear(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn firstOfMonth(date: CivilDate) CivilDate {
    return .{ .year = date.year, .month = date.month, .day = 1 };
}

fn lastOfMonth(date: CivilDate) CivilDate {
    return .{ .year = date.year, .month = date.month, .day = daysInMonth(date.year, date.month) };
}

fn startOfWeek(date: CivilDate) CivilDate {
    return addDays(date, -@as(i64, isoWeekday(date)));
}

/// Dates outside years 1..9999 cannot be written as `YYYY-MM-DD`.
fn writable(date: CivilDate) bool {
    return date.year >= 1 and date.year <= 9999;
}

/// `YYYY-MM-DD`.
pub fn writeDate(out: *std.Io.Writer, date: CivilDate) !void {
    try out.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(date.year)), date.month, date.day });
}

/// `YYYY-MM-DD (Ddd)`.
fn writeDayWithWeekday(out: *std.Io.Writer, date: CivilDate) !void {
    try writeDate(out, date);
    try out.print(" ({s})", .{weekdayName(date)[0..3]});
}

/// Distance of `date` from `current` for a session header: `today`, then
/// `N days ago` under 60 days, `~N months (D days) ago` under two years, and
/// `~N years (D days) ago` beyond. Dates after `current` read `in N days`.
pub fn writeOffset(out: *std.Io.Writer, date: CivilDate, current: CivilDate) !void {
    const delta = daysFromCivil(current) - daysFromCivil(date);
    if (delta == 0) return out.writeAll("today");
    const days: u64 = @abs(delta);
    if (delta < 0) try out.writeAll("in ");
    if (days < 60) {
        try out.print("{d} day{s}", .{ days, if (days == 1) "" else "s" });
    } else if (days < 730) {
        // Mean Gregorian month: 365.2425 / 12 days.
        const months: u64 = @intFromFloat(@round(@as(f64, @floatFromInt(days)) / 30.436875));
        try out.print("~{d} months ({d} days)", .{ months, days });
    } else {
        const years: u64 = @intFromFloat(@round(@as(f64, @floatFromInt(days)) / 365.2425));
        try out.print("~{d} years ({d} days)", .{ years, days });
    }
    if (delta > 0) try out.writeAll(" ago");
}

pub const Resolution = union(enum) {
    /// An exact day (`yesterday`, `3 days ago`, `last Friday`).
    day: CivilDate,
    /// An approximate day (`2 weeks ago`, `3 months ago`).
    around: CivilDate,
    /// An inclusive date range (`last month`, `past 2 weeks`).
    range: struct { start: CivilDate, end: CivilDate },

    fn isWritable(self: Resolution) bool {
        return switch (self) {
            .day, .around => |date| writable(date),
            .range => |span| writable(span.start) and writable(span.end),
        };
    }

    fn write(self: Resolution, out: *std.Io.Writer) !void {
        switch (self) {
            .day => |date| try writeDayWithWeekday(out, date),
            .around => |date| {
                try out.writeAll("around ");
                try writeDayWithWeekday(out, date);
            },
            .range => |span| {
                if (span.start.eql(span.end)) return writeDayWithWeekday(out, span.start);
                try writeDate(out, span.start);
                try out.writeAll(" to ");
                try writeDate(out, span.end);
            },
        }
    }
};

const Match = struct {
    len: usize,
    value: Resolution,
};

const Unit = enum { day, week, month, year };

/// Resolves relative time expressions in `query` against `current`. Returns
/// the `Time references:` payload, e.g.
/// `"last month" = 2023-04-01 to 2023-04-30; "yesterday" = 2023-05-29 (Mon)`,
/// in question order with repeats dropped, or null when nothing matches.
///
/// Covered phrases (case-insensitive; N is 1-999 or one..twelve):
/// today, yesterday, day before yesterday, last night; N days/weeks/months/
/// years ago (also `a week ago`); past|last|previous N days/weeks/months/years;
/// last|previous|past|this week/month/year; the last week/month/year (rolling);
/// last|previous|past weekend; last <weekday>; last <Month>; since the
/// start|beginning of the year/month/week; since <Month>; earlier this
/// year/month/week; in|during <Month> [of] [year]; <Month> <year>;
/// in|during <year>. Weeks start on Monday. A bare month is its most recent
/// occurrence not after the current month.
pub fn resolveTimeReferences(allocator: std.mem.Allocator, query: []const u8, current: CivilDate) !?[]u8 {
    if (!writable(current)) return null;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const named = try resolveNamedTimes(arena, query, current);
    if (named.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (named, 0..) |time, position| {
        if (position > 0) try out.writer.writeAll("; ");
        try out.writer.print("\"{s}\" = ", .{time.phrase});
        try time.value.write(&out.writer);
    }
    return try out.toOwnedSlice();
}

/// An inclusive span of days that a time reference in a question points at.
pub const Window = struct { start: CivilDate, end: CivilDate };

/// A window wider than this says too little about when something happened to
/// be worth anchoring retrieval on (`this year`, `in 2023`).
const max_window_days: i64 = 92;

/// A time the question names: the words, what they resolve to, and the days
/// a memory may be dated to count as being from then.
pub const NamedTime = struct {
    phrase: []const u8,
    value: Resolution,
    /// Null for `today` and for spans wider than `max_window_days`, which
    /// say too little to look for a memory by.
    window: ?Window,

    /// How a day inside the window relates to the phrase: it is the day
    /// named, it is near the day named, or it is inside the span named.
    pub fn relation(self: NamedTime, date: CivilDate) enum { is, near, within } {
        return switch (self.value) {
            .day => .is,
            .around => |day| if (day.eql(date)) .is else .near,
            .range => |span| if (span.start.eql(span.end)) .is else .within,
        };
    }
};

/// Words that make the time after them looser: "roughly two weeks ago".
const hedges = [_][]const u8{ "about", "around", "roughly", "approximately", "maybe", "perhaps", "nearly", "almost", "some" };

/// The relative time expressions in `query`, in question order with repeats
/// dropped, resolved against `current` by plain date arithmetic. Everything
/// is allocated in `arena`.
///
/// An exact day (`yesterday`, `10 days ago`, `last Saturday`) is a one-day
/// window. An approximate one (`2 weeks ago`) is widened by a seventh of its
/// distance from `current`, at least a day each way. A hedged count
/// (`roughly two weeks ago`, `10 days ago or so`) is widened by a third of
/// its distance instead. A weekday in front of an approximate time (`the
/// Wednesday two months ago`) picks that weekday nearest to it, exactly.
pub fn resolveNamedTimes(arena: std.mem.Allocator, query: []const u8, current: CivilDate) ![]NamedTime {
    if (!writable(current)) return &.{};
    var tokens = std.ArrayList([]const u8).empty;
    var cursor: usize = 0;
    while (cursor < query.len) {
        while (cursor < query.len and !std.ascii.isAlphanumeric(query[cursor])) : (cursor += 1) {}
        const start = cursor;
        while (cursor < query.len and std.ascii.isAlphanumeric(query[cursor])) : (cursor += 1) {}
        if (cursor > start) try tokens.append(arena, query[start..cursor]);
    }

    var named = std.ArrayList(NamedTime).empty;
    const today = daysFromCivil(current);
    var index: usize = 0;
    var previous_end: usize = 0;
    while (index < tokens.items.len) {
        const found = matchAt(tokens.items, index, current) orelse {
            index += 1;
            continue;
        };
        var first = index;
        const end = index + found.len;
        // Words of the phrase before belong to it, not to this one.
        const taken = previous_end;
        index = end;
        previous_end = end;
        if (!found.value.isWritable()) continue;

        var value = found.value;
        const counted = wordAt(tokens.items, end - 1, "ago");
        const hedged = counted and
            ((first > 0 and anyWordAt(tokens.items, first - 1, &hedges)) or
                (wordAt(tokens.items, end, "or") and wordAt(tokens.items, end + 1, "so")));
        if (value == .around and !hedged and first > taken) {
            if (weekdayAt(tokens.items, first - 1)) |weekday| {
                // The nearest such weekday is at most three days away.
                const target = value.around;
                const ahead = @mod(@as(i64, weekday) - isoWeekday(target), 7);
                value = .{ .day = addDays(target, if (ahead > 3) ahead - 7 else ahead) };
                first -= 1;
            }
        }
        if (hedged) switch (value) {
            .day => |date| value = .{ .around = date },
            else => {},
        };

        const phrase = try std.mem.join(arena, " ", tokens.items[first..end]);
        const repeated = for (named.items) |seen| {
            if (std.ascii.eqlIgnoreCase(seen.phrase, phrase)) break true;
        } else false;
        if (repeated) continue;

        var window: ?Window = switch (value) {
            .day => |date| .{ .start = date, .end = date },
            .around => |date| aroundWindow(date, current, hedged),
            .range => |span| .{ .start = span.start, .end = span.end },
        };
        const from = daysFromCivil(window.?.start);
        const to = daysFromCivil(window.?.end);
        if ((from == today and to == today) or to < from or to - from + 1 > max_window_days) window = null;
        try named.append(arena, .{ .phrase = phrase, .value = value, .window = window });
    }
    return named.items;
}

/// The days an approximate time may mean: `date`, a seventh of its distance
/// from `current` either way, or a third when the count was hedged, and at
/// least a day.
fn aroundWindow(date: CivilDate, current: CivilDate, hedged: bool) Window {
    const distance = @abs(daysFromCivil(current) - daysFromCivil(date));
    const slack: i64 = @intCast(@max(1, distance / @as(u64, if (hedged) 3 else 7)));
    return .{ .start = addDays(date, -slack), .end = addDays(date, slack) };
}

/// The windows the relative time expressions in `query` point at; see
/// `resolveNamedTimes`. `today` and windows wider than `max_window_days` are
/// left out. Caller owns the slice.
pub fn resolveWindows(allocator: std.mem.Allocator, query: []const u8, current: CivilDate) ![]Window {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const named = try resolveNamedTimes(arena_state.allocator(), query, current);

    var windows = std.ArrayList(Window).empty;
    errdefer windows.deinit(allocator);
    for (named) |time| {
        const window = time.window orelse continue;
        const repeated = for (windows.items) |seen| {
            if (seen.start.eql(window.start) and seen.end.eql(window.end)) break true;
        } else false;
        if (!repeated) try windows.append(allocator, window);
    }
    return windows.toOwnedSlice(allocator);
}

/// Whether `date` falls inside `window`, ends included.
pub fn windowContains(window: Window, date: CivilDate) bool {
    const day = daysFromCivil(date);
    return day >= daysFromCivil(window.start) and day <= daysFromCivil(window.end);
}

const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// `May 8, 2023`.
fn writeLongDate(out: *std.Io.Writer, date: CivilDate) !void {
    try out.print("{s} {d}, {d}", .{ month_names[date.month - 1], date.day, @as(u32, @intCast(date.year)) });
}

/// `May 22 to May 28, 2023`; both years are written when they differ.
fn writeLongSpan(out: *std.Io.Writer, start: CivilDate, end: CivilDate) !void {
    if (start.eql(end)) return writeLongDate(out, start);
    if (start.year == end.year) {
        try out.print("{s} {d} to ", .{ month_names[start.month - 1], start.day });
    } else {
        try writeLongDate(out, start);
        try out.writeAll(" to ");
    }
    try writeLongDate(out, end);
}

/// A time a statement names, and the words that replace it.
const Phrase = union(enum) {
    /// `on Monday, May 8, 2023`, or `on the night of Monday, May 8, 2023`.
    day: struct { date: CivilDate, part: ?[]const u8 = null },
    /// `around May 16, 2023`, `around March 2023` or `around 2021`: as fine
    /// as the unit counted in. `hedged` when the count itself was loose
    /// ("about two weeks ago", "a few weeks ago").
    around: struct { date: CivilDate, unit: Unit, hedged: bool = false },
    /// `in the week of May 22 to May 28, 2023`, by its Monday.
    week: CivilDate,
    /// `on the weekend of May 27 to May 28, 2023`, by its Saturday.
    weekend: CivilDate,
    /// `in April 2023`.
    month: CivilDate,
    /// `in 2022`.
    year: i32,
    /// A stretch that ends on the day of speaking ("the past two weeks"). The
    /// words stay and the dates follow in brackets.
    span: struct { start: CivilDate, end: CivilDate },

    fn isWritable(self: Phrase) bool {
        return switch (self) {
            .day => |value| writable(value.date),
            .around => |value| writable(value.date),
            .week, .weekend, .month => |date| writable(date) and writable(addDays(date, 6)),
            .year => |year| year >= 1 and year <= 9999,
            .span => |value| writable(value.start) and writable(value.end),
        };
    }

    /// The days the phrase covers when said on `current`. Null for a stretch
    /// that ends or starts on the day of speaking: the day said dates it.
    fn covers(self: Phrase, current: CivilDate) ?Window {
        const window: Window = switch (self) {
            .day => |value| .{ .start = value.date, .end = value.date },
            .around => |value| aroundWindow(value.date, current, value.hedged),
            .week => |monday| .{ .start = monday, .end = addDays(monday, 6) },
            .weekend => |saturday| .{ .start = saturday, .end = addDays(saturday, 1) },
            .month => |first| .{ .start = first, .end = lastOfMonth(first) },
            .year => |year| .{ .start = .{ .year = year, .month = 1, .day = 1 }, .end = .{ .year = year, .month = 12, .day = 31 } },
            .span => return null,
        };
        return if (writable(window.start) and writable(window.end)) window else null;
    }

    /// The preposition the replacement opens with, unless the statement has
    /// one of its own in front ("since yesterday").
    fn preposition(self: Phrase) []const u8 {
        return switch (self) {
            .day, .weekend => "on",
            .around => "around",
            .week, .month, .year => "in",
            .span => "",
        };
    }

    fn write(self: Phrase, out: *std.Io.Writer) !void {
        switch (self) {
            .day => |value| {
                if (value.part) |part| try out.print("the {s} of ", .{part});
                try out.print("{s}, ", .{weekdayName(value.date)});
                try writeLongDate(out, value.date);
            },
            .around => |value| switch (value.unit) {
                .day, .week => try writeLongDate(out, value.date),
                .month => try out.print("{s} {d}", .{ month_names[value.date.month - 1], @as(u32, @intCast(value.date.year)) }),
                .year => try out.print("{d}", .{@as(u32, @intCast(value.date.year))}),
            },
            .week => |monday| {
                try out.writeAll("the week of ");
                try writeLongSpan(out, monday, addDays(monday, 6));
            },
            .weekend => |saturday| {
                try out.writeAll("the weekend of ");
                try writeLongSpan(out, saturday, addDays(saturday, 1));
            },
            .month => |first| try out.print("{s} {d}", .{ month_names[first.month - 1], @as(u32, @intCast(first.year)) }),
            .year => |year| try out.print("{d}", .{@as(u32, @intCast(year))}),
            .span => |value| try writeLongSpan(out, value.start, value.end),
        }
    }
};

const Stated = struct {
    len: usize,
    phrase: Phrase,
    /// "the day before yesterday": a "the" in front belongs to the phrase.
    takes_article: bool = false,
    /// "a few weeks ago": the count is a reading of the words, so they stay
    /// and the date follows in brackets.
    keeps_words: bool = false,
};

/// `text` with its times written out, and the day it names.
pub const StatedTimes = struct {
    text: []u8,
    /// Set when the text names exactly one time and that time is one day.
    day: ?CivilDate = null,
    /// Set when the text names exactly one time that can be placed: the days
    /// it covers. One day for a day, the week, weekend, month or year for a
    /// period, and the days around a counted time ("two weeks ago") as a
    /// question's would be (`resolveNamedTimes`).
    when: ?Window = null,
    /// `when` was counted back from the day of speaking, so it is a point
    /// with slack, not a calendar period.
    counted: bool = false,
};

/// Rewrites the relative times in a statement made on `current` as calendar
/// dates, so the statement reads the same on any later day:
/// "went to the dentist yesterday" becomes "went to the dentist on Monday,
/// May 8, 2023". Returns null when the text names no such time.
///
/// Replaced (case-insensitive; N as in `resolveTimeReferences`):
/// today, yesterday, tomorrow, each with an optional morning|afternoon|
/// evening|night; tonight; this morning|afternoon|evening; last night; the
/// day before yesterday; N days ago; last|previous|this <weekday>;
/// last|this weekend; last|previous|this|next week|month|year; last <Month>;
/// N weeks|months|years ago (as `around ...`, no finer than the unit).
/// Kept, with the dates after them in brackets: stretches that end or start
/// on the day of speaking (past|last|previous N <units>, the last|past <unit>,
/// earlier this <unit>, [the] next N <units>, the next <unit>), any phrase
/// in the possessive or behind an article ("yesterday's meeting", "the
/// previous week"), and a loose count: a few|several|a couple [of] <units>
/// ago, read as three, five and two ("a few weeks ago (around April 18,
/// 2023)").
/// Times that cannot be placed ("recently", "a while ago", "next Friday",
/// "next weekend") are left alone and ` (said on May 9, 2023)` is added at
/// the end. Explicit dates, bare month names and a weekday followed by its
/// date ("last Saturday, March 17th") are left as they are.
pub fn resolveStatedTimes(allocator: std.mem.Allocator, text: []const u8, current: CivilDate) !?StatedTimes {
    if (!writable(current)) return null;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tokens = std.ArrayList([]const u8).empty;
    var scan: usize = 0;
    while (scan < text.len) {
        while (scan < text.len and !std.ascii.isAlphanumeric(text[scan])) : (scan += 1) {}
        const start = scan;
        while (scan < text.len and std.ascii.isAlphanumeric(text[scan])) : (scan += 1) {}
        if (scan > start) try tokens.append(arena, text[start..scan]);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var cursor: usize = 0;
    var replaced: usize = 0;
    var day: ?CivilDate = null;
    var when: ?Window = null;
    var counted = false;
    var index: usize = 0;
    while (index < tokens.items.len) {
        const found = matchStatedAt(tokens.items, index, current) orelse {
            index += 1;
            continue;
        };
        const first = index;
        index += found.len;
        if (!found.phrase.isWritable()) continue;
        var start = tokenOffset(text, tokens.items[first]);
        const last = tokens.items[index - 1];
        const end = tokenOffset(text, last) + last.len;
        if (looksLikeName(text, start) or isQuoteAt(text, end)) continue;
        const possessive = possessiveLength(text[end..]);
        // Already followed by its dates.
        if (std.mem.startsWith(u8, text[end + possessive ..], " (")) continue;

        replaced += 1;
        var before: ?[]const u8 = adjacentWordBefore(text, tokens.items, first);
        var before_index = first;
        if (found.takes_article and before != null and std.ascii.eqlIgnoreCase(before.?, "the")) {
            start = tokenOffset(text, before.?);
            before_index = first - 1;
            before = adjacentWordBefore(text, tokens.items, before_index);
        }
        var phrase = found.phrase;
        switch (phrase) {
            // "about two weeks ago", "two weeks ago or so".
            .around => |*value| if ((before != null and anyWordAt(&.{before.?}, 0, &hedges)) or
                (wordAt(tokens.items, index, "or") and wordAt(tokens.items, index + 1, "so"))) {
                value.hedged = true;
            },
            else => {},
        }
        day = switch (phrase) {
            .day => |value| value.date,
            else => null,
        };
        when = phrase.covers(current);
        counted = phrase == .around;
        const bracketed = found.keeps_words or phrase == .span or possessive > 0 or (before != null and isDeterminer(before.?));
        if (bracketed) {
            try out.writer.writeAll(text[cursor .. end + possessive]);
            try out.writer.writeAll(" (");
            if (phrase == .around) try out.writer.writeAll("around ");
            try found.phrase.write(&out.writer);
            try out.writer.writeByte(')');
            cursor = end + possessive;
            continue;
        }
        try out.writer.writeAll(text[cursor..start]);
        const preposition = found.phrase.preposition();
        const has_own = before != null and isPreposition(before.?) and
            (found.phrase != .around or anyWordAt(tokens.items, before_index - 1, &.{ "around", "about" }));
        if (!has_own) {
            if (start == 0) {
                try out.writer.writeByte(std.ascii.toUpper(preposition[0]));
                try out.writer.writeAll(preposition[1..]);
            } else {
                try out.writer.writeAll(preposition);
            }
            try out.writer.writeByte(' ');
        }
        try found.phrase.write(&out.writer);
        cursor = end;
    }

    const unplaced = hasUnplacedTime(tokens.items) and std.mem.indexOf(u8, text, "(said on ") == null;
    if (replaced == 0 and !unplaced) {
        out.deinit();
        return null;
    }
    var rest = text[cursor..];
    if (unplaced) {
        const trimmed = std.mem.trimEnd(u8, rest, " \t\r\n");
        const body = if (std.mem.endsWith(u8, trimmed, ".")) trimmed[0 .. trimmed.len - 1] else trimmed;
        try out.writer.writeAll(body);
        try out.writer.writeAll(" (said on ");
        try writeLongDate(&out.writer, current);
        try out.writer.writeByte(')');
        rest = rest[body.len..];
    }
    try out.writer.writeAll(rest);
    const one = replaced == 1;
    return .{
        .text = try out.toOwnedSlice(),
        .day = if (one) day else null,
        .when = if (one) when else null,
        .counted = one and counted and when != null,
    };
}

fn tokenOffset(text: []const u8, token: []const u8) usize {
    return @intFromPtr(token.ptr) - @intFromPtr(text.ptr);
}

/// The word before token `i`, when only spaces separate the two.
fn adjacentWordBefore(text: []const u8, tokens: []const []const u8, i: usize) ?[]const u8 {
    if (i == 0) return null;
    const word = tokens[i - 1];
    const gap = text[tokenOffset(text, word) + word.len .. tokenOffset(text, tokens[i])];
    for (gap) |char| {
        if (char != ' ') return null;
    }
    return word;
}

fn isPreposition(word: []const u8) bool {
    const words = [_][]const u8{ "since", "until", "till", "by", "from", "before", "after", "for", "of", "on", "in", "at", "through", "during", "around", "about" };
    for (words) |candidate| {
        if (std.ascii.eqlIgnoreCase(word, candidate)) return true;
    }
    return false;
}

fn isDeterminer(word: []const u8) bool {
    const words = [_][]const u8{ "the", "a", "an", "that", "my", "their", "his", "her", "our", "its" };
    for (words) |candidate| {
        if (std.ascii.eqlIgnoreCase(word, candidate)) return true;
    }
    return false;
}

/// A capitalised word in the middle of a sentence, or one inside quotation
/// marks, is a title or a name ("the song Yesterday"), not a time.
fn looksLikeName(text: []const u8, start: usize) bool {
    if (start == 0) return false;
    if (isQuoteAt(text[0..start], start)) return true;
    if (!std.ascii.isUpper(text[start])) return false;
    const before = std.mem.trimEnd(u8, text[0..start], " ");
    return before.len > 0 and before[before.len - 1] != '.' and before[before.len - 1] != ':';
}

/// Whether a quotation mark sits at `at`, looking forward from a phrase end
/// or (when `at == text.len`) backward from a phrase start.
fn isQuoteAt(text: []const u8, at: usize) bool {
    const marks = [_][]const u8{ "\"", "\u{201c}", "\u{201d}", "\u{2018}" };
    if (at == text.len) {
        for (marks) |mark| {
            if (std.mem.endsWith(u8, text, mark)) return true;
        }
        return std.mem.endsWith(u8, text, "'");
    }
    for (marks) |mark| {
        if (std.mem.startsWith(u8, text[at..], mark)) return true;
    }
    return false;
}

/// Bytes of a possessive ending (`'s`, with either apostrophe) at the start.
fn possessiveLength(rest: []const u8) usize {
    if (std.mem.startsWith(u8, rest, "'s")) return 2;
    if (std.mem.startsWith(u8, rest, "\u{2019}s")) return 4;
    return 0;
}

/// Times the grammar cannot place on the calendar.
fn hasUnplacedTime(tokens: []const []const u8) bool {
    for (tokens, 0..) |token, i| {
        if (anyWordAt(tokens, i, &.{ "recently", "lately" })) return true;
        if (wordAt(tokens, i, "the") and wordAt(tokens, i + 1, "other") and wordAt(tokens, i + 2, "day")) return true;
        if (wordAt(tokens, i, "while") and anyWordAt(tokens, i + 1, &.{ "ago", "back" })) return true;
        if (wordAt(tokens, i, "next") and (weekdayAt(tokens, i + 1) != null or wordAt(tokens, i + 1, "weekend"))) return true;
        _ = token;
    }
    return false;
}

fn matchStatedAt(tokens: []const []const u8, i: usize, current: CivilDate) ?Stated {
    if (matchDayBeforeYesterday(tokens, i, current)) |found| {
        return .{ .len = found.len, .phrase = .{ .day = .{ .date = addDays(current, -2) } }, .takes_article = true };
    }
    if (statedDay(tokens, i, current)) |found| return found;
    if (statedAgo(tokens, i, current)) |found| return found;
    const stretch = matchRollingCount(tokens, i, current) orelse
        matchTheLastUnit(tokens, i, current) orelse
        matchEarlierThis(tokens, i, current) orelse
        matchComing(tokens, i, current);
    if (stretch) |found| {
        const range = found.value.range;
        return .{ .len = found.len, .phrase = .{ .span = .{ .start = range.start, .end = range.end } } };
    }
    if (statedPeriod(tokens, i, current)) |found| return found;
    if (statedWeekday(tokens, i, current)) |found| return found;
    if (matchLastMonthName(tokens, i, current)) |found| {
        return .{ .len = found.len, .phrase = .{ .month = found.value.range.start } };
    }
    return null;
}

/// [the] next N days|weeks|months|years; the next week|month|year: a
/// stretch that starts on the day of speaking.
fn matchComing(tokens: []const []const u8, i: usize, current: CivilDate) ?Match {
    const article = wordAt(tokens, i, "the");
    const j = if (article) i + 1 else i;
    if (!wordAt(tokens, j, "next")) return null;
    if (countAt(tokens, j + 1, false)) |count| {
        const unit = unitAt(tokens, j + 2) orelse return null;
        return .{ .len = j + 3 - i, .value = between(current, shiftForward(current, unit, count)) };
    }
    if (!article) return null;
    const unit = unitAt(tokens, j + 1) orelse return null;
    if (unit == .day or !std.ascii.eqlIgnoreCase(tokens[j + 1], @tagName(unit))) return null;
    if (anyWordAt(tokens, j + 2, &.{ "of", "in" })) return null;
    return .{ .len = 3, .value = between(current, shiftForward(current, unit, 1)) };
}

fn shiftForward(current: CivilDate, unit: Unit, count: u32) CivilDate {
    return switch (unit) {
        .day => addDays(current, @as(i64, count)),
        .week => addDays(current, 7 * @as(i64, count)),
        .month => addMonths(current, @as(i64, count)),
        .year => addMonths(current, 12 * @as(i64, count)),
    };
}

fn partOfDayAt(tokens: []const []const u8, i: usize) ?[]const u8 {
    const parts = [_][]const u8{ "morning", "afternoon", "evening", "night" };
    for (parts) |part| {
        if (wordAt(tokens, i, part)) return part;
    }
    return null;
}

/// today|yesterday|tomorrow [morning|afternoon|evening|night]; tonight;
/// this morning|afternoon|evening; last night.
fn statedDay(tokens: []const []const u8, i: usize, current: CivilDate) ?Stated {
    const offset: ?i64 = if (wordAt(tokens, i, "today")) 0 else if (wordAt(tokens, i, "yesterday")) -1 else if (wordAt(tokens, i, "tomorrow")) 1 else null;
    if (offset) |days| {
        const part = partOfDayAt(tokens, i + 1);
        return .{ .len = if (part == null) 1 else 2, .phrase = .{ .day = .{ .date = addDays(current, days), .part = part } } };
    }
    if (wordAt(tokens, i, "tonight")) return .{ .len = 1, .phrase = .{ .day = .{ .date = current, .part = "evening" } } };
    if (wordAt(tokens, i, "this")) {
        const part = partOfDayAt(tokens, i + 1) orelse return null;
        if (std.mem.eql(u8, part, "night")) return null;
        return .{ .len = 2, .phrase = .{ .day = .{ .date = current, .part = part } } };
    }
    if (wordAt(tokens, i, "last") and wordAt(tokens, i + 1, "night")) {
        return .{ .len = 2, .phrase = .{ .day = .{ .date = addDays(current, -1), .part = "night" } } };
    }
    return null;
}

/// N days|weeks|months|years ago. Days are exact; a longer unit is only as
/// fine as itself. few|several|couple [of] <units> ago are read as three,
/// five and two, loosely.
fn statedAgo(tokens: []const []const u8, i: usize, current: CivilDate) ?Stated {
    const loose: ?u32 = if (wordAt(tokens, i, "few")) 3 else if (wordAt(tokens, i, "several")) 5 else if (wordAt(tokens, i, "couple")) 2 else null;
    if (loose) |count| {
        const j = if (wordAt(tokens, i, "couple") and wordAt(tokens, i + 1, "of")) i + 2 else i + 1;
        const unit = unitAt(tokens, j) orelse return null;
        if (!wordAt(tokens, j + 1, "ago")) return null;
        return .{
            .len = j + 2 - i,
            .phrase = .{ .around = .{ .date = shiftBack(current, unit, count), .unit = unit, .hedged = true } },
            .keeps_words = true,
        };
    }
    const count = countAt(tokens, i, true) orelse return null;
    const unit = unitAt(tokens, i + 1) orelse return null;
    if (!wordAt(tokens, i + 2, "ago")) return null;
    const date = shiftBack(current, unit, count);
    return .{ .len = 3, .phrase = if (unit == .day) .{ .day = .{ .date = date } } else .{ .around = .{ .date = date, .unit = unit } } };
}

/// last|previous|this|next week|month|year (not before "of"), as the whole
/// calendar period; past week|month|year, as a stretch; last|this weekend.
fn statedPeriod(tokens: []const []const u8, i: usize, current: CivilDate) ?Stated {
    const shift: i64 = if (anyWordAt(tokens, i, &.{ "last", "previous" }))
        -1
    else if (wordAt(tokens, i, "this"))
        0
    else if (wordAt(tokens, i, "next"))
        1
    else if (wordAt(tokens, i, "past")) {
        const found = matchNamedPeriod(tokens, i, current) orelse return null;
        const range = found.value.range;
        return .{ .len = found.len, .phrase = .{ .span = .{ .start = range.start, .end = range.end } } };
    } else return null;

    const monday = startOfWeek(current);
    if (wordAt(tokens, i + 1, "weekend")) {
        if (shift > 0) return null;
        return .{ .len = 2, .phrase = .{ .weekend = addDays(monday, 5 + 7 * shift) } };
    }
    const unit = unitAt(tokens, i + 1) orelse return null;
    if (unit == .day or !std.ascii.eqlIgnoreCase(tokens[i + 1], @tagName(unit))) return null;
    if (wordAt(tokens, i + 2, "of")) return null;
    return .{ .len = 2, .phrase = switch (unit) {
        .week => .{ .week = addDays(monday, 7 * shift) },
        .month => .{ .month = addMonths(firstOfMonth(current), shift) },
        .year => .{ .year = current.year + @as(i32, @intCast(shift)) },
        .day => unreachable,
    } };
}

/// last|previous <weekday>: the most recent such day before the day of
/// speaking. this <weekday>: the next such day, the day of speaking included.
fn statedWeekday(tokens: []const []const u8, i: usize, current: CivilDate) ?Stated {
    // "last Saturday, March 17th" already says which day.
    if (monthAt(tokens, i + 2, true) != null) return null;
    if (matchLastWeekday(tokens, i, current)) |found| {
        return .{ .len = found.len, .phrase = .{ .day = .{ .date = found.value.day } } };
    }
    if (!wordAt(tokens, i, "this")) return null;
    const weekday = weekdayAt(tokens, i + 1) orelse return null;
    const ahead = @mod(@as(i64, weekday) - isoWeekday(current), 7);
    return .{ .len = 2, .phrase = .{ .day = .{ .date = addDays(current, ahead) } } };
}

fn matchAt(tokens: []const []const u8, i: usize, current: CivilDate) ?Match {
    return matchSince(tokens, i, current) orelse
        matchEarlierThis(tokens, i, current) orelse
        matchDayBeforeYesterday(tokens, i, current) orelse
        matchSingleWord(tokens, i, current) orelse
        matchAgo(tokens, i, current) orelse
        matchRollingCount(tokens, i, current) orelse
        matchTheLastUnit(tokens, i, current) orelse
        matchNamedPeriod(tokens, i, current) orelse
        matchLastWeekday(tokens, i, current) orelse
        matchLastMonthName(tokens, i, current) orelse
        matchInMonthOrYear(tokens, i, current) orelse
        matchMonthYear(tokens, i);
}

fn wordAt(tokens: []const []const u8, i: usize, expected: []const u8) bool {
    return i < tokens.len and std.ascii.eqlIgnoreCase(tokens[i], expected);
}

fn anyWordAt(tokens: []const []const u8, i: usize, expected: []const []const u8) bool {
    for (expected) |word| {
        if (wordAt(tokens, i, word)) return true;
    }
    return false;
}

fn unitAt(tokens: []const []const u8, i: usize) ?Unit {
    if (i >= tokens.len) return null;
    const word = tokens[i];
    const units = [_]struct { []const u8, Unit }{
        .{ "day", .day },     .{ "days", .day },
        .{ "week", .week },   .{ "weeks", .week },
        .{ "month", .month }, .{ "months", .month },
        .{ "year", .year },   .{ "years", .year },
    };
    for (units) |entry| {
        if (std.ascii.eqlIgnoreCase(word, entry[0])) return entry[1];
    }
    return null;
}

/// 1-999 in digits, one..twelve in words, and `a`/`an` when `article` is set.
fn countAt(tokens: []const []const u8, i: usize, article: bool) ?u32 {
    if (i >= tokens.len) return null;
    const word = tokens[i];
    if (word.len <= 3 and std.ascii.isDigit(word[0])) {
        const value = std.fmt.parseInt(u32, word, 10) catch return null;
        return if (value >= 1) value else null;
    }
    const words = [_][]const u8{ "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve" };
    for (words, 1..) |name, value| {
        if (std.ascii.eqlIgnoreCase(word, name)) return @intCast(value);
    }
    if (article and (std.ascii.eqlIgnoreCase(word, "a") or std.ascii.eqlIgnoreCase(word, "an"))) return 1;
    return null;
}

/// 0 = Monday ... 6 = Sunday; full names only.
fn weekdayAt(tokens: []const []const u8, i: usize) ?u8 {
    if (i >= tokens.len) return null;
    for (weekday_names, 0..) |name, index| {
        if (std.ascii.eqlIgnoreCase(tokens[i], name)) return @intCast(index);
    }
    return null;
}

/// 1..12; full names, plus common abbreviations when `abbreviations` is set.
fn monthAt(tokens: []const []const u8, i: usize, abbreviations: bool) ?u8 {
    if (i >= tokens.len) return null;
    const names = [_][]const u8{ "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december" };
    for (names, 1..) |name, month| {
        if (std.ascii.eqlIgnoreCase(tokens[i], name)) return @intCast(month);
    }
    if (!abbreviations) return null;
    const short = [_]struct { []const u8, u8 }{
        .{ "jan", 1 }, .{ "feb", 2 }, .{ "mar", 3 },  .{ "apr", 4 },  .{ "jun", 6 },  .{ "jul", 7 },
        .{ "aug", 8 }, .{ "sep", 9 }, .{ "sept", 9 }, .{ "oct", 10 }, .{ "nov", 11 }, .{ "dec", 12 },
    };
    for (short) |entry| {
        if (std.ascii.eqlIgnoreCase(tokens[i], entry[0])) return entry[1];
    }
    return null;
}

/// A four-digit year from 1900 to 2199.
fn yearAt(tokens: []const []const u8, i: usize) ?i32 {
    if (i >= tokens.len or tokens[i].len != 4) return null;
    const year = std.fmt.parseInt(i32, tokens[i], 10) catch return null;
    return if (year >= 1900 and year <= 2199) year else null;
}

fn shiftBack(current: CivilDate, unit: Unit, count: u32) CivilDate {
    return switch (unit) {
        .day => addDays(current, -@as(i64, count)),
        .week => addDays(current, -7 * @as(i64, count)),
        .month => addMonths(current, -@as(i64, count)),
        .year => addMonths(current, -12 * @as(i64, count)),
    };
}

fn startOf(current: CivilDate, unit: Unit) CivilDate {
    return switch (unit) {
        .day => current,
        .week => startOfWeek(current),
        .month => firstOfMonth(current),
        .year => .{ .year = current.year, .month = 1, .day = 1 },
    };
}

fn monthRange(year: i32, month: u8) Resolution {
    const first = CivilDate{ .year = year, .month = month, .day = 1 };
    return .{ .range = .{ .start = first, .end = lastOfMonth(first) } };
}

/// Most recent `month` not after the current month (`strictly_before`
/// excludes the current month itself).
fn recentMonthYear(current: CivilDate, month: u8, strictly_before: bool) i32 {
    if (month < current.month or (month == current.month and !strictly_before)) return current.year;
    return current.year - 1;
}

fn between(start: CivilDate, end: CivilDate) Resolution {
    return .{ .range = .{ .start = start, .end = end } };
}

/// since the start|beginning of [the|this] year|month|week; since <Month>.
fn matchSince(tokens: []const []const u8, i: usize, current: CivilDate) ?Match {
    if (!wordAt(tokens, i, "since")) return null;
    if (monthAt(tokens, i + 1, false)) |month| {
        const year = recentMonthYear(current, month, false);
        return .{ .len = 2, .value = between(.{ .year = year, .month = month, .day = 1 }, current) };
    }
    var j = i + 1;
    if (wordAt(tokens, j, "the")) j += 1;
    if (!anyWordAt(tokens, j, &.{ "start", "beginning" }) or !wordAt(tokens, j + 1, "of")) return null;
    j += 2;
    if (anyWordAt(tokens, j, &.{ "the", "this" })) j += 1;
    const unit = unitAt(tokens, j) orelse return null;
    if (unit == .day or !std.ascii.eqlIgnoreCase(tokens[j], @tagName(unit))) return null;
    return .{ .len = j + 1 - i, .value = between(startOf(current, unit), current) };
}

/// earlier this year|month|week: from the period start to the day before.
fn matchEarlierThis(tokens: []const []const u8, i: usize, current: CivilDate) ?Match {
    if (!wordAt(tokens, i, "earlier") or !wordAt(tokens, i + 1, "this")) return null;
    const unit = unitAt(tokens, i + 2) orelse return null;
    if (unit == .day or !std.ascii.eqlIgnoreCase(tokens[i + 2], @tagName(unit))) return null;
    const start = startOf(current, unit);
    const before = addDays(current, -1);
    const end = if (daysFromCivil(before) < daysFromCivil(start)) start else before;
    return .{ .len = 3, .value = between(start, end) };
}

fn matchDayBeforeYesterday(tokens: []const []const u8, i: usize, current: CivilDate) ?Match {
    if (!wordAt(tokens, i, "day") or !wordAt(tokens, i + 1, "before") or !wordAt(tokens, i + 2, "yesterday")) return null;
    return .{ .len = 3, .value = .{ .day = addDays(current, -2) } };
}

fn matchSingleWord(tokens: []const []const u8, i: usize, current: CivilDate) ?Match {
    if (wordAt(tokens, i, "today")) return .{ .len = 1, .value = .{ .day = current } };
    if (wordAt(tokens, i, "yesterday")) return .{ .len = 1, .value = .{ .day = addDays(current, -1) } };
    return null;
}

/// N days|weeks|months|years ago. Days are exact; longer units approximate.
fn matchAgo(tokens: []const []const u8, i: usize, current: CivilDate) ?Match {
    const count = countAt(tokens, i, true) orelse return null;
    const unit = unitAt(tokens, i + 1) orelse return null;
    if (!wordAt(tokens, i + 2, "ago")) return null;
    const date = shiftBack(current, unit, count);
    return .{ .len = 3, .value = if (unit == .day) .{ .day = date } else .{ .around = date } };
}

/// past|last|previous N days|weeks|months|years: a window ending today.
fn matchRollingCount(tokens: []const []const u8, i: usize, current: CivilDate) ?Match {
    if (!anyWordAt(tokens, i, &.{ "past", "last", "previous" })) return null;
    const count = countAt(tokens, i + 1, false) orelse return null;
    const unit = unitAt(tokens, i + 2) orelse return null;
    return .{ .len = 3, .value = between(shiftBack(current, unit, count), current) };
}

/// the last week|month|year (as in "in the last month"): a window ending
/// today, unlike the calendar period "last month". Not before "of"/"in"
/// ("the last week of March").
fn matchTheLastUnit(tokens: []const []const u8, i: usize, current: CivilDate) ?Match {
    if (!wordAt(tokens, i, "the") or !wordAt(tokens, i + 1, "last")) return null;
    const unit = unitAt(tokens, i + 2) orelse return null;
    if (unit == .day or !std.ascii.eqlIgnoreCase(tokens[i + 2], @tagName(unit))) return null;
    if (anyWordAt(tokens, i + 3, &.{ "of", "in" })) return null;
    return .{ .len = 3, .value = between(shiftBack(current, unit, 1), current) };
}

/// last|previous|past|this week|month|year (not before "of"),
/// last|previous|past weekend, last night.
fn matchNamedPeriod(tokens: []const []const u8, i: usize, current: CivilDate) ?Match {
    const Kind = enum { last, this, past };
    const kind: Kind = if (anyWordAt(tokens, i, &.{ "last", "previous" }))
        .last
    else if (wordAt(tokens, i, "this"))
        .this
    else if (wordAt(tokens, i, "past"))
        .past
    else
        return null;

    if (wordAt(tokens, i + 1, "night")) {
        return if (kind == .last) .{ .len = 2, .value = .{ .day = addDays(current, -1) } } else null;
    }
    if (wordAt(tokens, i + 1, "weekend")) {
        if (kind == .this) return null;
        const monday = startOfWeek(current);
        return .{ .len = 2, .value = between(addDays(monday, -2), addDays(monday, -1)) };
    }
    const unit = unitAt(tokens, i + 1) orelse return null;
    if (unit == .day or !std.ascii.eqlIgnoreCase(tokens[i + 1], @tagName(unit))) return null;
    // "last week of June" and "last year of college" name a part, not a period.
    if (wordAt(tokens, i + 2, "of")) return null;
    const value: Resolution = switch (kind) {
        .this => between(startOf(current, unit), current),
        .past => between(shiftBack(current, unit, 1), current),
        .last => switch (unit) {
            .week => blk: {
                const monday = startOfWeek(current);
                break :blk between(addDays(monday, -7), addDays(monday, -1));
            },
            .month => blk: {
                const previous = addMonths(firstOfMonth(current), -1);
                break :blk between(previous, lastOfMonth(previous));
            },
            .year => between(
                .{ .year = current.year - 1, .month = 1, .day = 1 },
                .{ .year = current.year - 1, .month = 12, .day = 31 },
            ),
            .day => unreachable,
        },
    };
    return .{ .len = 2, .value = value };
}

/// last|previous <weekday>: the most recent such day strictly before today.
fn matchLastWeekday(tokens: []const []const u8, i: usize, current: CivilDate) ?Match {
    if (!anyWordAt(tokens, i, &.{ "last", "previous" })) return null;
    const weekday = weekdayAt(tokens, i + 1) orelse return null;
    const back = @mod(@as(i64, isoWeekday(current)) - weekday, 7);
    return .{ .len = 2, .value = .{ .day = addDays(current, -(if (back == 0) 7 else back)) } };
}

/// last <Month>: the most recent such month before the current month.
fn matchLastMonthName(tokens: []const []const u8, i: usize, current: CivilDate) ?Match {
    if (!wordAt(tokens, i, "last")) return null;
    const month = monthAt(tokens, i + 1, false) orelse return null;
    return .{ .len = 2, .value = monthRange(recentMonthYear(current, month, true), month) };
}

/// in|during <Month> [of] [year]; in|during <year>.
fn matchInMonthOrYear(tokens: []const []const u8, i: usize, current: CivilDate) ?Match {
    if (!anyWordAt(tokens, i, &.{ "in", "during" })) return null;
    if (yearAt(tokens, i + 1)) |year| {
        return .{ .len = 2, .value = between(.{ .year = year, .month = 1, .day = 1 }, .{ .year = year, .month = 12, .day = 31 }) };
    }
    const month = monthAt(tokens, i + 1, true) orelse return null;
    if (yearAt(tokens, i + 2)) |year| return .{ .len = 3, .value = monthRange(year, month) };
    if (wordAt(tokens, i + 2, "of")) {
        if (yearAt(tokens, i + 3)) |year| return .{ .len = 4, .value = monthRange(year, month) };
    }
    return .{ .len = 2, .value = monthRange(recentMonthYear(current, month, false), month) };
}

/// <Month> <year> anywhere ("March 2023").
fn matchMonthYear(tokens: []const []const u8, i: usize) ?Match {
    const month = monthAt(tokens, i, true) orelse return null;
    const year = yearAt(tokens, i + 1) orelse return null;
    return .{ .len = 2, .value = monthRange(year, month) };
}

fn testDate(text: []const u8) CivilDate {
    return parseIsoDate(text) catch unreachable;
}

fn expectReferences(query: []const u8, current: []const u8, expected: ?[]const u8) !void {
    const resolved = try resolveTimeReferences(std.testing.allocator, query, testDate(current));
    defer if (resolved) |text| std.testing.allocator.free(text);
    if (expected) |text| {
        if (resolved == null) {
            std.debug.print("no references for {s}\n", .{query});
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqualStrings(text, resolved.?);
    } else if (resolved) |text| {
        std.debug.print("unexpected references for {s}: {s}\n", .{ query, text });
        return error.TestUnexpectedResult;
    }
}

fn expectOffset(date: []const u8, current: []const u8, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeOffset(&out.writer, testDate(date), testDate(current));
    try std.testing.expectEqualStrings(expected, out.written());
}

test "civil date arithmetic round-trips and clamps month ends" {
    for ([_][]const u8{ "1970-01-01", "2000-02-29", "2023-12-31", "2024-02-29", "2100-03-01", "1969-12-31" }) |text| {
        const date = testDate(text);
        try std.testing.expect(civilFromDays(daysFromCivil(date)).eql(date));
    }
    try std.testing.expectEqualStrings("Tuesday", weekdayName(testDate("2023-05-30")));
    try std.testing.expectEqualStrings("Thursday", weekdayName(testDate("1970-01-01")));
    try std.testing.expect(addDays(testDate("2024-03-01"), -1).eql(testDate("2024-02-29")));
    try std.testing.expect(addDays(testDate("2023-03-01"), -1).eql(testDate("2023-02-28")));
    try std.testing.expect(addMonths(testDate("2024-03-31"), -1).eql(testDate("2024-02-29")));
    try std.testing.expect(addMonths(testDate("2023-03-31"), -1).eql(testDate("2023-02-28")));
    try std.testing.expect(addMonths(testDate("2024-02-29"), -12).eql(testDate("2023-02-28")));
    try std.testing.expect(addMonths(testDate("2023-01-15"), -1).eql(testDate("2022-12-15")));
    try std.testing.expect(addMonths(testDate("2023-05-31"), -3).eql(testDate("2023-02-28")));
    try std.testing.expectError(error.InvalidDate, parseIsoDate("2023-02-29"));
    try std.testing.expectError(error.InvalidDate, parseIsoDate("-123-05-01"));
    try std.testing.expectError(error.InvalidDate, parseIsoDate("2023-13-01"));
}

test "session offsets use days, then months, then years" {
    try expectOffset("2023-05-30", "2023-05-30", "today");
    try expectOffset("2023-05-29", "2023-05-30", "1 day ago");
    try expectOffset("2023-05-20", "2023-05-30", "10 days ago");
    try expectOffset("2023-04-01", "2023-05-30", "59 days ago");
    try expectOffset("2023-03-31", "2023-05-30", "~2 months (60 days) ago");
    try expectOffset("2023-02-21", "2023-05-30", "~3 months (98 days) ago");
    try expectOffset("2022-05-30", "2023-05-30", "~12 months (365 days) ago");
    try expectOffset("2021-05-31", "2023-05-30", "~24 months (729 days) ago");
    try expectOffset("2021-05-30", "2023-05-30", "~2 years (730 days) ago");
    // 2024 is a leap year: Feb 28 to Mar 1 is two days.
    try expectOffset("2024-02-28", "2024-03-01", "2 days ago");
    try expectOffset("2023-06-02", "2023-05-30", "in 3 days");
}

test "time references resolve days, weeks and calendar periods" {
    // 2023-05-30 is a Tuesday.
    try expectReferences("What did I do yesterday and today?", "2023-05-30T23:40:00Z", "\"yesterday\" = 2023-05-29 (Mon); \"today\" = 2023-05-30 (Tue)");
    try expectReferences("What did I buy the day before yesterday?", "2023-05-30", "\"day before yesterday\" = 2023-05-28 (Sun)");
    try expectReferences("Where did I go 3 days ago?", "2023-05-30", "\"3 days ago\" = 2023-05-27 (Sat)");
    try expectReferences("Who did I meet two weeks ago?", "2023-05-30", "\"two weeks ago\" = around 2023-05-16 (Tue)");
    try expectReferences("What did I start a month ago?", "2023-03-31", "\"a month ago\" = around 2023-02-28 (Tue)");
    try expectReferences("What happened Twelve years ago?", "2024-02-29", "\"Twelve years ago\" = around 2012-02-29 (Wed)");
    try expectReferences("What did I read last week?", "2023-05-30", "\"last week\" = 2023-05-22 to 2023-05-28");
    try expectReferences("Plans this week?", "2023-05-30", "\"this week\" = 2023-05-29 to 2023-05-30");
    try expectReferences("Plans this week?", "2023-05-29", "\"this week\" = 2023-05-29 (Mon)");
    try expectReferences("Workouts in the past week?", "2023-05-30", "\"past week\" = 2023-05-23 to 2023-05-30");
    try expectReferences("What did I cook last month?", "2023-05-30", "\"last month\" = 2023-04-01 to 2023-04-30");
    try expectReferences("What did I cook last month?", "2024-03-01", "\"last month\" = 2024-02-01 to 2024-02-29");
    try expectReferences("What did I cook last month?", "2023-03-31", "\"last month\" = 2023-02-01 to 2023-02-28");
    try expectReferences("What did I cook last month?", "2023-01-10", "\"last month\" = 2022-12-01 to 2022-12-31");
    try expectReferences("Spending this month?", "2023-05-30", "\"this month\" = 2023-05-01 to 2023-05-30");
    try expectReferences("Spending over the past month?", "2024-03-31", "\"past month\" = 2024-02-29 to 2024-03-31");
    try expectReferences("Trips in the last month?", "2023-05-30", "\"the last month\" = 2023-04-30 to 2023-05-30");
    try expectReferences("Books read last year?", "2023-05-30", "\"last year\" = 2022-01-01 to 2022-12-31");
    try expectReferences("Books read this year?", "2023-05-30", "\"this year\" = 2023-01-01 to 2023-05-30");
    try expectReferences("Books read in the past year?", "2024-02-29", "\"past year\" = 2023-02-28 to 2024-02-29");
}

test "time references resolve windows, weekdays and named months" {
    try expectReferences("How many runs in the past 3 months?", "2023-05-31", "\"past 3 months\" = 2023-02-28 to 2023-05-31");
    try expectReferences("Meals in the last two weeks?", "2023-05-30", "\"last two weeks\" = 2023-05-16 to 2023-05-30");
    try expectReferences("Steps over the past 10 days?", "2024-03-05", "\"past 10 days\" = 2024-02-24 to 2024-03-05");
    try expectReferences("What did I eat last Saturday?", "2023-05-30", "\"last Saturday\" = 2023-05-27 (Sat)");
    try expectReferences("What did I eat last Tuesday?", "2023-05-30", "\"last Tuesday\" = 2023-05-23 (Tue)");
    try expectReferences("Where was I last weekend?", "2023-05-30", "\"last weekend\" = 2023-05-27 to 2023-05-28");
    try expectReferences("What did I watch last night?", "2023-05-30", "\"last night\" = 2023-05-29 (Mon)");
    try expectReferences("Purchases since the start of the year?", "2023-05-30", "\"since the start of the year\" = 2023-01-01 to 2023-05-30");
    try expectReferences("Purchases since the beginning of this month?", "2023-05-30", "\"since the beginning of this month\" = 2023-05-01 to 2023-05-30");
    try expectReferences("Purchases since March?", "2023-05-30", "\"since March\" = 2023-03-01 to 2023-05-30");
    try expectReferences("Trips earlier this year?", "2023-05-30", "\"earlier this year\" = 2023-01-01 to 2023-05-29");
    try expectReferences("Trips earlier this month?", "2023-05-01", "\"earlier this month\" = 2023-05-01 (Mon)");
    try expectReferences("What did I do in March?", "2023-05-30", "\"in March\" = 2023-03-01 to 2023-03-31");
    try expectReferences("What did I do in July?", "2023-05-30", "\"in July\" = 2022-07-01 to 2022-07-31");
    try expectReferences("What did I do in February?", "2024-03-10", "\"in February\" = 2024-02-01 to 2024-02-29");
    try expectReferences("What did I do in Feb 2023 and during March of 2022?", "2024-03-10", "\"in Feb 2023\" = 2023-02-01 to 2023-02-28; \"during March of 2022\" = 2022-03-01 to 2022-03-31");
    try expectReferences("What did I buy last February?", "2024-02-10", "\"last February\" = 2023-02-01 to 2023-02-28");
    try expectReferences("What happened December 2022?", "2023-05-30", "\"December 2022\" = 2022-12-01 to 2022-12-31");
    try expectReferences("What happened in 2022?", "2023-05-30", "\"in 2022\" = 2022-01-01 to 2022-12-31");
}

test "time references skip non-temporal wording and repeats" {
    try expectReferences("How many days ago did I buy the lamp?", "2023-05-30", null);
    try expectReferences("What was the last thing I may have said?", "2023-05-30", null);
    try expectReferences("What did the assistant recommend for the last day of the trip?", "2023-05-30", null);
    try expectReferences("Which is the 27th item in the list?", "2023-05-30", null);
    try expectReferences("Plans for the last week of June or my last year of college?", "2023-05-30", null);
    try expectReferences("Did I go last month, or was it LAST MONTH?", "2023-05-30", "\"last month\" = 2023-04-01 to 2023-04-30");
    try expectReferences("What did I do 0 days ago or 1000 days ago?", "2023-05-30", null);
}

fn expectStated(text: []const u8, current: []const u8, expected: ?[]const u8, day: ?[]const u8) !void {
    const stated = try resolveStatedTimes(std.testing.allocator, text, testDate(current));
    defer if (stated) |value| std.testing.allocator.free(value.text);
    if (expected) |want| {
        try std.testing.expectEqualStrings(want, stated.?.text);
        if (day) |want_day| {
            try std.testing.expect(stated.?.day.?.eql(testDate(want_day)));
        } else {
            try std.testing.expectEqual(@as(?CivilDate, null), stated.?.day);
        }
    } else {
        try std.testing.expectEqual(@as(?StatedTimes, null), stated);
    }
}

test "stated times become calendar dates" {
    // 2023-05-09 is a Tuesday.
    const now = "2023-05-09T10:00:00Z";
    try expectStated("The user went to the dentist yesterday.", now, "The user went to the dentist on Monday, May 8, 2023.", "2023-05-08");
    try expectStated("The user built a raised bed garden today.", now, "The user built a raised bed garden on Tuesday, May 9, 2023.", "2023-05-09");
    try expectStated("The user's flight is tomorrow morning.", now, "The user's flight is on the morning of Wednesday, May 10, 2023.", "2023-05-10");
    try expectStated("The user is seeing a play tonight.", now, "The user is seeing a play on the evening of Tuesday, May 9, 2023.", "2023-05-09");
    try expectStated("The user stayed up late last night.", now, "The user stayed up late on the night of Monday, May 8, 2023.", "2023-05-08");
    try expectStated("The user ran 5 km this morning.", now, "The user ran 5 km on the morning of Tuesday, May 9, 2023.", "2023-05-09");
    try expectStated("The user returned the day before yesterday.", now, "The user returned on Sunday, May 7, 2023.", "2023-05-07");
    try expectStated("The user bought a smoker 10 days ago.", now, "The user bought a smoker on Saturday, April 29, 2023.", "2023-04-29");
    try expectStated("The user stayed up late last Friday.", now, "The user stayed up late on Friday, May 5, 2023.", "2023-05-05");
    try expectStated("The user plans to visit the cobbler this Saturday.", now, "The user plans to visit the cobbler on Saturday, May 13, 2023.", "2023-05-13");
    try expectStated("The user has a call this Tuesday.", now, "The user has a call on Tuesday, May 9, 2023.", "2023-05-09");
    try expectStated("Yesterday the user adopted a beagle.", now, "On Monday, May 8, 2023 the user adopted a beagle.", "2023-05-08");
}

test "stated periods are written as weeks, months and years" {
    const now = "2023-05-09T10:00:00Z";
    try expectStated("The user ate a bag of chips last week.", now, "The user ate a bag of chips in the week of May 1 to May 7, 2023.", null);
    try expectStated("The user is hosting a brunch this week.", now, "The user is hosting a brunch in the week of May 8 to May 14, 2023.", null);
    try expectStated("The user starts a new job next week.", now, "The user starts a new job in the week of May 15 to May 21, 2023.", null);
    try expectStated("The user went camping last weekend.", now, "The user went camping on the weekend of May 6 to May 7, 2023.", null);
    try expectStated("The user plans a bike ride this weekend.", now, "The user plans a bike ride on the weekend of May 13 to May 14, 2023.", null);
    try expectStated("The user moved last month.", now, "The user moved in April 2023.", null);
    try expectStated("The user moves next month.", "2023-12-09", "The user moves in January 2024.", null);
    try expectStated("The user has read 12 books this year.", now, "The user has read 12 books in 2023.", null);
    try expectStated("The user ran a marathon last year.", now, "The user ran a marathon in 2022.", null);
    try expectStated("The user visited Kyoto last February.", now, "The user visited Kyoto in February 2023.", null);
    try expectStated("The user watched Evita two weeks ago.", now, "The user watched Evita around April 25, 2023.", null);
    try expectStated("The user started the job 3 months ago.", now, "The user started the job around February 2023.", null);
    try expectStated("The user moved to Austin two years ago.", now, "The user moved to Austin around 2021.", null);
    try expectStated("The week spans a new year last week.", "2023-01-03", "The week spans a new year in the week of December 26, 2022 to January 1, 2023.", null);
}

test "stated times keep their words where replacing them would not read" {
    const now = "2023-05-09T10:00:00Z";
    try expectStated("The user has gone to bed at 11:30 PM for the past two weeks.", now, "The user has gone to bed at 11:30 PM for the past two weeks (April 25 to May 9, 2023).", null);
    try expectStated("The user has run 40 km in the last month.", now, "The user has run 40 km in the last month (April 9 to May 9, 2023).", null);
    try expectStated("The user missed yesterday's meeting.", now, "The user missed yesterday's (Monday, May 8, 2023) meeting.", "2023-05-08");
    try expectStated("The user was ill the previous week.", now, "The user was ill the previous week (the week of May 1 to May 7, 2023).", null);
    try expectStated("The user has been unwell since yesterday.", now, "The user has been unwell since Monday, May 8, 2023.", "2023-05-08");
    try expectStated("The user has a deadline for next week.", now, "The user has a deadline for the week of May 15 to May 21, 2023.", null);
    try expectStated("The user left around two weeks ago.", now, "The user left around April 25, 2023.", null);
    try expectStated("The user met Dana yesterday and leaves tomorrow.", now, "The user met Dana on Monday, May 8, 2023 and leaves on Wednesday, May 10, 2023.", null);
    // A second pass adds nothing.
    try expectStated("The user has gone to bed late for the past two weeks (April 25 to May 9, 2023).", now, null, null);
    try expectStated("The user went to the dentist on Monday, May 8, 2023.", now, null, null);
}

test "times that cannot be placed get the day they were said" {
    const now = "2023-05-13T10:00:00Z";
    try expectStated("The user moved a while ago.", now, "The user moved a while ago (said on May 13, 2023).", null);
    try expectStated("The user recently adopted a beagle", now, "The user recently adopted a beagle (said on May 13, 2023)", null);
    try expectStated("The user is seeing the dentist next Friday.", now, "The user is seeing the dentist next Friday (said on May 13, 2023).", null);
    try expectStated("The user hosts a brunch next weekend.", now, "The user hosts a brunch next weekend (said on May 13, 2023).", null);
    try expectStated("The user moved a couple of months ago (said on May 13, 2023).", now, null, null);
    try expectStated("The user wants to start a family within the next year or two.", now, "The user wants to start a family within the next year (May 13, 2023 to May 13, 2024) or two.", null);
    try expectStated("The user is travelling for the next 3 weeks.", now, "The user is travelling for the next 3 weeks (May 13 to June 3, 2023).", null);
}

test "stated times leave names, dates and other wording alone" {
    const now = "2023-05-09T10:00:00Z";
    try expectStated("The user likes the song Yesterday by the Beatles.", now, null, null);
    try expectStated("The user watched \"Tomorrow Never Dies\" twice.", now, null, null);
    try expectStated("The user is in their last year of college.", now, null, null);
    try expectStated("The user moved in on March 3, 2023.", now, null, null);
    try expectStated("The user spent 3 hours at the museum last Saturday, March 17th.", now, null, null);
    try expectStated("The user goes to the gym at 7:00 pm every day.", now, null, null);
    try expectStated("The user visited Rome in July.", now, null, null);
    try expectStated("The user owns 37 coins.", now, null, null);
}

fn expectWhen(text: []const u8, current: []const u8, expected: ?[2][]const u8, counted: bool) !void {
    const stated = (try resolveStatedTimes(std.testing.allocator, text, testDate(current))).?;
    defer std.testing.allocator.free(stated.text);
    try std.testing.expectEqual(counted, stated.counted);
    const want = expected orelse return std.testing.expectEqual(@as(?Window, null), stated.when);
    try std.testing.expect(testDate(want[0]).eql(stated.when.?.start));
    try std.testing.expect(testDate(want[1]).eql(stated.when.?.end));
}

test "a loose count keeps its words and gains a date" {
    // 2023-05-09 is a Tuesday.
    const now = "2023-05-09T10:00:00Z";
    try expectStated("The user watched Evita a few weeks ago.", now, "The user watched Evita a few weeks ago (around April 18, 2023).", null);
    try expectStated("The user moved a couple of months ago.", now, "The user moved a couple of months ago (around March 2023).", null);
    try expectStated("The user called a plumber a couple days ago.", now, "The user called a plumber a couple days ago (around May 7, 2023).", null);
    try expectStated("The user visited the Grand Canyon several years ago.", now, "The user visited the Grand Canyon several years ago (around 2018).", null);
    // A second pass adds nothing, and other counts of things are not times.
    try expectStated("The user watched Evita a few weeks ago (around April 18, 2023).", now, null, null);
    try expectStated("The user took a few weeks off and a couple of days to rest.", now, null, null);
}

test "one stated time gives the days the event covers" {
    const now = "2023-05-09T10:00:00Z";
    try expectWhen("The user went to the dentist yesterday.", now, .{ "2023-05-08", "2023-05-08" }, false);
    try expectWhen("The user ate a bag of chips last week.", now, .{ "2023-05-01", "2023-05-07" }, false);
    try expectWhen("The user plans a bike ride this weekend.", now, .{ "2023-05-13", "2023-05-14" }, false);
    try expectWhen("The user moved last month.", now, .{ "2023-04-01", "2023-04-30" }, false);
    try expectWhen("The user ran a marathon last year.", now, .{ "2022-01-01", "2022-12-31" }, false);
    // Counted back: a seventh of the distance either way, a third when loose.
    try expectWhen("The user watched Evita two weeks ago.", now, .{ "2023-04-23", "2023-04-27" }, true);
    try expectWhen("The user watched Evita about two weeks ago.", now, .{ "2023-04-21", "2023-04-29" }, true);
    try expectWhen("The user watched Evita two weeks ago or so.", now, .{ "2023-04-21", "2023-04-29" }, true);
    try expectWhen("The user watched Evita a few weeks ago.", now, .{ "2023-04-11", "2023-04-25" }, true);
    try expectWhen("The user called a plumber a few days ago.", now, .{ "2023-05-05", "2023-05-07" }, true);
    // A stretch up to today, two times, or a time that cannot be placed: none.
    try expectWhen("The user has run 40 km in the last month.", now, null, false);
    try expectWhen("The user met Dana yesterday and leaves tomorrow.", now, null, false);
    try expectWhen("The user recently adopted a beagle.", now, null, false);
}

fn expectWindows(query: []const u8, current: []const u8, expected: []const [2][]const u8) !void {
    const windows = try resolveWindows(std.testing.allocator, query, testDate(current));
    defer std.testing.allocator.free(windows);
    try std.testing.expectEqual(expected.len, windows.len);
    for (expected, windows) |want, got| {
        try std.testing.expect(testDate(want[0]).eql(got.start));
        try std.testing.expect(testDate(want[1]).eql(got.end));
    }
}

test "a hedge widens a counted time and a weekday pins an approximate one" {
    // Two weeks back is 2023-04-21: two days either way, four when hedged.
    try expectWindows("What did I plant two weeks ago?", "2023-05-05", &.{.{ "2023-04-19", "2023-04-23" }});
    try expectWindows("What did I plant roughly two weeks ago?", "2023-05-05", &.{.{ "2023-04-17", "2023-04-25" }});
    try expectWindows("What did I plant two weeks ago or so?", "2023-05-05", &.{.{ "2023-04-17", "2023-04-25" }});
    // A counted day is exact until it is hedged.
    try expectWindows("Who called me 10 days ago?", "2023-05-11", &.{.{ "2023-05-01", "2023-05-01" }});
    try expectWindows("Who called me about 10 days ago?", "2023-05-11", &.{.{ "2023-04-28", "2023-05-04" }});
    try expectReferences("Who called me about 10 days ago?", "2023-05-11", "\"10 days ago\" = around 2023-05-01 (Mon)");
    // "about" belongs to the trip, and "last Saturday" is a day whatever precedes it.
    try expectWindows("What did I say about the trip 10 days ago?", "2023-05-11", &.{.{ "2023-05-01", "2023-05-01" }});
    try expectWindows("What happened around last Saturday?", "2023-03-09", &.{.{ "2023-03-04", "2023-03-04" }});

    // The weekday nearest the approximate time, named as one day.
    try expectWindows("What did I do with Rachel on the Wednesday two months ago?", "2023-04-01", &.{.{ "2023-02-01", "2023-02-01" }});
    try expectReferences("What did I do with Rachel on the Wednesday two months ago?", "2023-04-01", "\"Wednesday two months ago\" = 2023-02-01 (Wed)");
    try expectWindows("Where was I on the Friday three weeks ago?", "2023-05-09", &.{.{ "2023-04-21", "2023-04-21" }});
    try expectWindows("Where was I on the Sunday three weeks ago?", "2023-05-09", &.{.{ "2023-04-16", "2023-04-16" }});
}

test "named times say how a day relates to them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const named = try resolveNamedTimes(arena_state.allocator(), "What did I do last Saturday, two weeks ago, over the past weekend, and today?", testDate("2023-03-09"));
    try std.testing.expectEqual(@as(usize, 4), named.len);
    try std.testing.expectEqualStrings("last Saturday", named[0].phrase);
    try std.testing.expect(named[0].relation(testDate("2023-03-04")) == .is);
    try std.testing.expectEqualStrings("two weeks ago", named[1].phrase);
    try std.testing.expect(named[1].relation(testDate("2023-02-23")) == .is);
    try std.testing.expect(named[1].relation(testDate("2023-02-24")) == .near);
    try std.testing.expect(named[2].relation(testDate("2023-03-05")) == .within);
    // Today is a time reference but not somewhere to look for a memory.
    try std.testing.expectEqualStrings("today", named[3].phrase);
    try std.testing.expect(named[3].window == null);
}

test "time windows cover the day meant, with slack for approximate ones" {
    // An exact day is one day wide; "N weeks ago" gets a seventh of its distance each way.
    try expectWindows("What kitchen appliance did I buy 10 days ago?", "2023-03-25", &.{.{ "2023-03-15", "2023-03-15" }});
    try expectWindows("Who did I go with to the music event last Saturday?", "2023-04-22", &.{.{ "2023-04-15", "2023-04-15" }});
    try expectWindows("What gardening-related activity did I do two weeks ago?", "2023-05-05", &.{.{ "2023-04-19", "2023-04-23" }});
    try expectWindows("Which bike did I fix the past weekend?", "2023-03-21", &.{.{ "2023-03-18", "2023-03-19" }});
    try expectWindows("What did I watch in January?", "2023-01-30", &.{.{ "2023-01-01", "2023-01-31" }});

    // Today, spans too wide to anchor on, and questions with no time reference give nothing.
    try expectWindows("What is the order of airlines I flew with before today?", "2023-03-02", &.{});
    try expectWindows("Where did I travel this year?", "2023-08-20", &.{});
    try expectWindows("How many weeks ago did I attend the sale at Nordstrom?", "2022-12-01", &.{});
    try expectWindows("Did I go running last Friday or was it last Friday evening?", "2023-06-07", &.{.{ "2023-06-02", "2023-06-02" }});

    const window: Window = .{ .start = testDate("2023-04-19"), .end = testDate("2023-04-23") };
    try std.testing.expect(windowContains(window, testDate("2023-04-19")));
    try std.testing.expect(windowContains(window, testDate("2023-04-23")));
    try std.testing.expect(!windowContains(window, testDate("2023-04-24")));
}
