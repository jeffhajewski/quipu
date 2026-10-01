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

const Resolution = union(enum) {
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

    var tokens = std.ArrayList([]const u8).empty;
    var cursor: usize = 0;
    while (cursor < query.len) {
        while (cursor < query.len and !std.ascii.isAlphanumeric(query[cursor])) : (cursor += 1) {}
        const start = cursor;
        while (cursor < query.len and std.ascii.isAlphanumeric(query[cursor])) : (cursor += 1) {}
        if (cursor > start) try tokens.append(arena, query[start..cursor]);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var phrases = std.ArrayList([]const u8).empty;
    var index: usize = 0;
    while (index < tokens.items.len) {
        const found = matchAt(tokens.items, index, current) orelse {
            index += 1;
            continue;
        };
        const phrase = try std.mem.join(arena, " ", tokens.items[index .. index + found.len]);
        index += found.len;
        if (!found.value.isWritable()) continue;
        const repeated = for (phrases.items) |seen| {
            if (std.ascii.eqlIgnoreCase(seen, phrase)) break true;
        } else false;
        if (repeated) continue;
        if (phrases.items.len > 0) try out.writer.writeAll("; ");
        try phrases.append(arena, phrase);
        try out.writer.print("\"{s}\" = ", .{phrase});
        try found.value.write(&out.writer);
    }
    if (phrases.items.len == 0) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
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
