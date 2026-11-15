//! Mermaid gantt charts: sections of tasks on a shared time axis.
//!
//! Times are seconds since 1970-01-01 in a proleptic Gregorian calendar without time zones.
//! Task starts may refer to other tasks (`after a b`) in any order, so they are resolved in
//! bounded passes after parsing.

const std = @import("std");
const assert = std.debug.assert;
const scene = @import("../scene.zig");

const tasks_max = 256;
const sections_max = 64;
const ticks_max = 256;
const data_tokens_max = 3;
const source_length_max = 1 << 24;

const seconds_per_day = 86400;
const seconds_per_hour = 3600;
/// Dates outside these years are rejected, which keeps all arithmetic far from overflow.
const year_min = 1;
const year_max = 9999;

const padding = 16;
const chart_width = 720;
const gutter_padding = 12;
const gutter_width_min = 64;
const title_gap = 16;
const row_height = 30;
const bar_height = 20;
const bar_radius = 3;
const label_inset = 8;
const label_gap = 6;
const tick_length = 5;
const tick_label_gap = 12;
const tick_label_spacing = 18;

comptime {
    assert(bar_height < row_height);
    assert(chart_width > 0);
    assert(tasks_max <= std.math.maxInt(u16));
}

const Start = union(enum) {
    /// The task starts when the previous task ends.
    previous,
    time: i64,
    /// Space-separated task ids: the task starts when the last of them ends.
    after: []const u8,
};

const End = union(enum) {
    time: i64,
    duration: Duration,
    /// Space-separated task ids: the task ends when the first of them starts.
    until: []const u8,
};

/// Months and years have no fixed length in seconds, so they are kept apart.
const Duration = struct { seconds: i64 = 0, months: i64 = 0 };

const Task = struct {
    name: []const u8,
    id: []const u8,
    section: u32,
    crit: bool = false,
    active: bool = false,
    done: bool = false,
    milestone: bool = false,
    start_spec: Start,
    end_spec: End,
    start: i64 = 0,
    end: i64 = 0,
    resolved: bool = false,
};

const Gantt = struct {
    title: []const u8 = "",
    inclusive_end_dates: bool = false,
    sections: [sections_max][]const u8 = undefined,
    section_count: u32 = 0,
    tasks: [tasks_max]Task = undefined,
    task_count: u32 = 0,
    time_min: i64 = 0,
    time_max: i64 = 0,
};

pub fn render(
    source: []const u8,
    measurer: scene.Measurer,
    scratch: []u8,
    out: *scene.Scene,
) scene.Error!void {
    assert(out.command_count == 0);
    if (source.len > source_length_max) return error.Overflow;
    var allocator_state = std.heap.FixedBufferAllocator.init(scratch);
    const gantt = allocator_state.allocator().create(Gantt) catch return error.Overflow;
    gantt.* = .{};
    try parse(source, gantt);
    try resolve(gantt);
    var canvas = Canvas.init(out, measurer);
    try layout(gantt, &canvas);
    canvas.finish();
    assert(out.size.width > 0);
    assert(out.size.height > 0);
}

// Calendar arithmetic, after Howard Hinnant's `days_from_civil` and `civil_from_days`.

const Civil = struct { year: i64, month: u32, day: u32 };

fn days_from_civil(civil: Civil) i64 {
    assert(civil.month >= 1 and civil.month <= 12);
    assert(civil.day >= 1 and civil.day <= 31);
    const year = if (civil.month <= 2) civil.year - 1 else civil.year;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const month_from_march: i64 = (civil.month + 9) % 12;
    const day_of_year = @divFloor(153 * month_from_march + 2, 5) + civil.day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    assert(day_of_era >= 0 and day_of_era < 146097);
    return era * 146097 + day_of_era - 719468;
}

fn civil_from_days(days: i64) Civil {
    const shifted = days + 719468;
    const era = @divFloor(shifted, 146097);
    const day_of_era = shifted - era * 146097;
    assert(day_of_era >= 0 and day_of_era < 146097);
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) +
        @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    const day_of_year = day_of_era -
        (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_from_march = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_from_march + 2, 5) + 1;
    const month = if (month_from_march < 10) month_from_march + 3 else month_from_march - 9;
    const year = year_of_era + era * 400 + @intFromBool(month <= 2);
    assert(day >= 1 and day <= 31);
    return .{ .year = year, .month = @intCast(month), .day = @intCast(day) };
}

fn is_leap_year(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn days_in_month(year: i64, month: u32) u32 {
    assert(month >= 1 and month <= 12);
    const lengths = [12]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and is_leap_year(year)) return 29;
    return lengths[month - 1];
}

/// Adds calendar months to a time, clamping the day to the end of a shorter month.
fn months_add(time: i64, months: i64) scene.Error!i64 {
    assert(months >= 0);
    const days = @divFloor(time, seconds_per_day);
    const civil = civil_from_days(days);
    const month_index = civil.year * 12 + (civil.month - 1) + months;
    const year = @divFloor(month_index, 12);
    if (year > year_max) return error.Overflow;
    const month: u32 = @intCast(@mod(month_index, 12) + 1);
    const day = @min(civil.day, days_in_month(year, month));
    const result = days_from_civil(.{ .year = year, .month = month, .day = day }) *
        seconds_per_day + (time - days * seconds_per_day);
    assert(result >= time);
    return result;
}

/// Parses `YYYY-MM-DD` into seconds.
fn date_parse(text: []const u8) ?i64 {
    if (text.len != 10) return null;
    if (text[4] != '-' or text[7] != '-') return null;
    const year = std.fmt.parseInt(u32, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u32, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u32, text[8..10], 10) catch return null;
    for (text, 0..) |byte, index| {
        if (index != 4 and index != 7 and !std.ascii.isDigit(byte)) return null;
    }
    if (year < year_min or year > year_max) return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > days_in_month(year, month)) return null;
    const days = days_from_civil(.{ .year = year, .month = month, .day = day });
    assert(civil_from_days(days).day == day);
    return days * seconds_per_day;
}

/// Parses durations such as `3d`, `2w`, `12h`, `1.5d`, `30m`, `1M`, or `1y`.
fn duration_parse(text: []const u8) ?Duration {
    if (text.len < 2) return null;
    const unit_length: usize = if (std.mem.endsWith(u8, text, "ms")) 2 else 1;
    const unit = text[text.len - unit_length ..];
    const number_text = text[0 .. text.len - unit_length];
    if (number_text.len == 0 or !std.ascii.isDigit(number_text[0])) return null;
    const number = std.fmt.parseFloat(f64, number_text) catch return null;
    if (!std.math.isFinite(number) or number < 0 or number > 1e6) return null;
    if (unit[0] == 'M' or unit[0] == 'y') {
        if (number != @floor(number)) return null;
        const months: i64 = @intFromFloat(number);
        return .{ .months = if (unit[0] == 'y') months * 12 else months };
    }
    const unit_seconds: f64 = switch (unit[0]) {
        'w' => 7 * seconds_per_day,
        'd' => seconds_per_day,
        'h' => seconds_per_hour,
        'm' => if (unit_length == 2) 0.001 else 60,
        's' => 1,
        else => return null,
    };
    const seconds: i64 = @intFromFloat(@round(number * unit_seconds));
    assert(seconds >= 0);
    return .{ .seconds = seconds };
}

/// Iterates over statements: one per line, trimmed, without blank lines, `%%` comments, or
/// accessibility statements, which do not affect the drawing.
const Lines = struct {
    source: []const u8,
    cursor: u32 = 0,

    fn next(lines: *Lines) ?[]const u8 {
        assert(lines.source.len <= source_length_max);
        // Every iteration consumes at least one byte, so the loop is bounded by the source length.
        while (lines.cursor < lines.source.len) {
            const start = lines.cursor;
            const end = std.mem.findScalarPos(u8, lines.source, start, '\n') orelse
                lines.source.len;
            assert(end >= start);
            lines.cursor = @intCast(end + 1);
            var line = std.mem.trim(u8, lines.source[start..end], " \t\r");
            if (std.mem.endsWith(u8, line, ";")) {
                line = std.mem.trimEnd(u8, line[0 .. line.len - 1], " \t");
            }
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "%%")) continue;
            if (std.mem.startsWith(u8, line, "accTitle")) continue;
            if (std.mem.startsWith(u8, line, "accDescr")) {
                const is_block = std.mem.findScalar(u8, line, '{') != null and
                    std.mem.findScalar(u8, line, '}') == null;
                if (is_block) lines.skip_past('}');
                continue;
            }
            return line;
        }
        return null;
    }

    fn skip_past(lines: *Lines, byte: u8) void {
        assert(lines.cursor <= lines.source.len + 1);
        if (lines.cursor >= lines.source.len) return;
        const index = std.mem.findScalarPos(u8, lines.source, lines.cursor, byte) orelse
            lines.source.len;
        lines.cursor = @intCast(index + 1);
        assert(lines.cursor > 0);
    }
};

/// Returns the rest of `line` when it starts with `word` followed by whitespace or the end.
fn word_strip(line: []const u8, word: []const u8) ?[]const u8 {
    assert(word.len > 0);
    if (!std.mem.startsWith(u8, line, word)) return null;
    const rest = line[word.len..];
    if (rest.len > 0 and rest[0] != ' ' and rest[0] != '\t') return null;
    return std.mem.trim(u8, rest, " \t");
}

/// Statements that configure rendering details this layout does not implement.
const ignored_keywords = [_][]const u8{
    "axisFormat", "tickInterval", "excludes", "includes", "todayMarker", "weekday",
    "weekend",    "displayMode",  "topAxis",  "click",
};

fn parse(source: []const u8, gantt: *Gantt) scene.Error!void {
    assert(gantt.task_count == 0);
    var lines: Lines = .{ .source = source };
    const header = lines.next() orelse return error.Syntax;
    const header_rest = word_strip(header, "gantt") orelse return error.Syntax;
    if (header_rest.len > 0) return error.Syntax;
    statements: while (lines.next()) |line| {
        for (ignored_keywords) |keyword| {
            if (word_strip(line, keyword) != null) continue :statements;
        }
        if (word_strip(line, "title")) |title| {
            gantt.title = title;
        } else if (word_strip(line, "dateFormat")) |format| {
            if (!std.mem.eql(u8, format, "YYYY-MM-DD")) return error.Syntax;
        } else if (word_strip(line, "inclusiveEndDates") != null) {
            gantt.inclusive_end_dates = true;
        } else if (word_strip(line, "section")) |name| {
            if (gantt.section_count == sections_max) return error.Overflow;
            gantt.sections[gantt.section_count] = name;
            gantt.section_count += 1;
        } else {
            try parse_task(line, gantt);
        }
    }
    if (gantt.task_count == 0) return error.Syntax;
    assert(gantt.section_count <= sections_max);
}

fn parse_task(line: []const u8, gantt: *Gantt) scene.Error!void {
    assert(line.len > 0);
    assert(gantt.task_count <= tasks_max);
    const colon = std.mem.findScalar(u8, line, ':') orelse return error.Syntax;
    const name = std.mem.trim(u8, line[0..colon], " \t");
    if (name.len == 0) return error.Syntax;
    var task: Task = .{
        .name = name,
        .id = "",
        // Tasks before the first section belong to an unnamed section.
        .section = gantt.section_count,
        .start_spec = .previous,
        .end_spec = .{ .duration = .{} },
    };
    var data: [data_tokens_max][]const u8 = undefined;
    var data_count: u32 = 0;
    var tokens = std.mem.splitScalar(u8, line[colon + 1 ..], ',');
    while (tokens.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t");
        if (std.mem.eql(u8, token, "crit")) {
            task.crit = true;
        } else if (std.mem.eql(u8, token, "active")) {
            task.active = true;
        } else if (std.mem.eql(u8, token, "done")) {
            task.done = true;
        } else if (std.mem.eql(u8, token, "milestone")) {
            task.milestone = true;
        } else {
            if (data_count == data_tokens_max) return error.Syntax;
            data[data_count] = token;
            data_count += 1;
        }
    }
    if (data_count == 0) return error.Syntax;
    if (data_count == 3) task.id = data[0];
    if (data_count >= 2) task.start_spec = try start_parse(data[data_count - 2]);
    task.end_spec = try end_parse(data[data_count - 1], gantt.inclusive_end_dates);
    if (task.id.len > 0 and std.mem.findAny(u8, task.id, " \t") != null) return error.Syntax;
    if (gantt.task_count == tasks_max) return error.Overflow;
    gantt.tasks[gantt.task_count] = task;
    gantt.task_count += 1;
}

fn start_parse(text: []const u8) scene.Error!Start {
    if (word_strip(text, "after")) |ids| {
        if (ids.len == 0) return error.Syntax;
        return .{ .after = ids };
    }
    const time = date_parse(text) orelse return error.Syntax;
    assert(@mod(time, seconds_per_day) == 0);
    return .{ .time = time };
}

fn end_parse(text: []const u8, inclusive: bool) scene.Error!End {
    if (word_strip(text, "until")) |ids| {
        if (ids.len == 0) return error.Syntax;
        return .{ .until = ids };
    }
    if (date_parse(text)) |time| {
        return .{ .time = if (inclusive) time + seconds_per_day else time };
    }
    const duration = duration_parse(text) orelse return error.Syntax;
    assert(duration.seconds >= 0);
    return .{ .duration = duration };
}

/// Resolves start and end times. Each pass resolves at least one task or stops, so the number of
/// passes is bounded by the task count; tasks left over depend on each other in a cycle.
fn resolve(gantt: *Gantt) scene.Error!void {
    assert(gantt.task_count > 0);
    var resolved_count: u32 = 0;
    for (0..gantt.task_count) |_| {
        const resolved_before = resolved_count;
        for (gantt.tasks[0..gantt.task_count], 0..) |*task, index| {
            if (task.resolved) continue;
            if (try task_resolve(gantt, @intCast(index))) resolved_count += 1;
        }
        if (resolved_count == gantt.task_count) break;
        if (resolved_count == resolved_before) return error.Syntax;
    }
    assert(resolved_count == gantt.task_count);
    gantt.time_min = gantt.tasks[0].start;
    gantt.time_max = gantt.tasks[0].end;
    for (gantt.tasks[0..gantt.task_count]) |task| {
        assert(task.end >= task.start);
        gantt.time_min = @min(gantt.time_min, task.start);
        gantt.time_max = @max(gantt.time_max, task.end);
    }
    // A chart of milestones only still needs a time span to draw an axis.
    if (gantt.time_max == gantt.time_min) gantt.time_max += seconds_per_day;
    assert(gantt.time_max > gantt.time_min);
}

/// Returns whether the task could be resolved, which needs every task it refers to resolved.
fn task_resolve(gantt: *Gantt, index: u32) scene.Error!bool {
    const task = &gantt.tasks[index];
    assert(!task.resolved);
    const start: i64 = switch (task.start_spec) {
        .time => |time| time,
        .previous => start: {
            if (index == 0) return error.Syntax;
            const previous = gantt.tasks[index - 1];
            if (!previous.resolved) return false;
            break :start previous.end;
        },
        .after => |ids| (try ids_time(gantt, ids, .end_latest)) orelse return false,
    };
    const end: i64 = switch (task.end_spec) {
        .time => |time| time,
        .duration => |duration| try months_add(start + duration.seconds, duration.months),
        .until => |ids| (try ids_time(gantt, ids, .start_earliest)) orelse return false,
    };
    if (end < start) return error.Syntax;
    if (end > (date_parse("9999-12-31") orelse unreachable)) return error.Overflow;
    task.start = start;
    task.end = end;
    task.resolved = true;
    return true;
}

/// Combines the times of the tasks named in `ids`, or returns null when one is unresolved.
fn ids_time(
    gantt: *const Gantt,
    ids: []const u8,
    mode: enum { end_latest, start_earliest },
) scene.Error!?i64 {
    assert(ids.len > 0);
    var result: ?i64 = null;
    var words = std.mem.tokenizeAny(u8, ids, " \t");
    while (words.next()) |word| {
        const task = task_find(gantt, word) orelse return error.Syntax;
        if (!task.resolved) return null;
        result = switch (mode) {
            .end_latest => @max(result orelse task.end, task.end),
            .start_earliest => @min(result orelse task.start, task.start),
        };
    }
    assert(result != null);
    return result;
}

fn task_find(gantt: *const Gantt, id: []const u8) ?*const Task {
    assert(id.len > 0);
    for (gantt.tasks[0..gantt.task_count]) |*task| {
        if (std.mem.eql(u8, task.id, id)) return task;
    }
    return null;
}

/// Appends commands while tracking their bounds, then moves them so that the bounds start at the
/// padding and sizes the scene to fit. Text may hang past the chart, so bounds are measured.
const Canvas = struct {
    out: *scene.Scene,
    measurer: scene.Measurer,
    command_start: u32,
    point_start: u32,
    min: scene.Point = .{ .x = std.math.inf(f32), .y = std.math.inf(f32) },
    max: scene.Point = .{ .x = -std.math.inf(f32), .y = -std.math.inf(f32) },

    fn init(out: *scene.Scene, measurer: scene.Measurer) Canvas {
        assert(out.command_count <= out.commands.len);
        assert(out.point_count <= out.points.len);
        return .{
            .out = out,
            .measurer = measurer,
            .command_start = out.command_count,
            .point_start = out.point_count,
        };
    }

    fn include(canvas: *Canvas, x: f32, y: f32) void {
        assert(std.math.isFinite(x));
        assert(std.math.isFinite(y));
        canvas.min = .{ .x = @min(canvas.min.x, x), .y = @min(canvas.min.y, y) };
        canvas.max = .{ .x = @max(canvas.max.x, x), .y = @max(canvas.max.y, y) };
    }

    fn include_rect(canvas: *Canvas, rect: scene.Rect) void {
        assert(rect.width >= 0);
        assert(rect.height >= 0);
        canvas.include(rect.x, rect.y);
        canvas.include(rect.x + rect.width, rect.y + rect.height);
    }

    fn add(canvas: *Canvas, command: scene.Command) scene.Error!void {
        switch (command) {
            .rect => |c| canvas.include_rect(c.rect),
            .ellipse => |c| canvas.include_rect(c.rect),
            .wedge => |c| canvas.include_rect(.{
                .x = c.center.x - c.radius,
                .y = c.center.y - c.radius,
                .width = 2 * c.radius,
                .height = 2 * c.radius,
            }),
            .line => |c| for (canvas.out.points_slice(c.points)) |p| canvas.include(p.x, p.y),
            .polygon => |c| for (canvas.out.points_slice(c.points)) |p| canvas.include(p.x, p.y),
            .text => |c| {
                const size = canvas.measurer.measure(c.bytes, c.font);
                const left = switch (c.anchor) {
                    .start => c.origin.x,
                    .middle => c.origin.x - size.width / 2,
                    .end => c.origin.x - size.width,
                };
                canvas.include_rect(.{
                    .x = left,
                    .y = c.origin.y - size.height / 2,
                    .width = size.width,
                    .height = size.height,
                });
            },
        }
        try canvas.out.command_add(command);
    }

    fn line(canvas: *Canvas, points: []const scene.Point, dash: scene.Dash) scene.Error!void {
        assert(points.len >= 2);
        const range = try canvas.out.points_add(points);
        try canvas.add(.{ .line = .{ .points = range, .dash = dash } });
    }

    fn finish(canvas: *Canvas) void {
        assert(canvas.out.command_count > canvas.command_start);
        assert(canvas.max.x >= canvas.min.x);
        const dx = padding - canvas.min.x;
        const dy = padding - canvas.min.y;
        const out = canvas.out;
        for (out.points[canvas.point_start..out.point_count]) |*point| {
            point.* = .{ .x = point.x + dx, .y = point.y + dy };
        }
        for (out.commands[canvas.command_start..out.command_count]) |*command| {
            switch (command.*) {
                .rect => |*c| c.rect = rect_translate(c.rect, dx, dy),
                .ellipse => |*c| c.rect = rect_translate(c.rect, dx, dy),
                .wedge => |*c| c.center = .{ .x = c.center.x + dx, .y = c.center.y + dy },
                .text => |*c| c.origin = .{ .x = c.origin.x + dx, .y = c.origin.y + dy },
                .line, .polygon => {},
            }
        }
        out.size = .{
            .width = @ceil(canvas.max.x - canvas.min.x + 2 * padding),
            .height = @ceil(canvas.max.y - canvas.min.y + 2 * padding),
        };
        assert(out.size.width > 0);
    }
};

fn rect_translate(rect: scene.Rect, dx: f32, dy: f32) scene.Rect {
    assert(std.math.isFinite(dx));
    assert(std.math.isFinite(dy));
    return .{ .x = rect.x + dx, .y = rect.y + dy, .width = rect.width, .height = rect.height };
}

const Geometry = struct {
    gutter_width: f32,
    rows_top: f32,
    rows_bottom: f32,
    time_min: i64,
    /// Points per second.
    scale: f64,

    fn x(geometry: Geometry, time: i64) f32 {
        assert(time >= geometry.time_min);
        const offset: f64 = @floatFromInt(time - geometry.time_min);
        return geometry.gutter_width + @as(f32, @floatCast(offset * geometry.scale));
    }

    fn chart_right(geometry: Geometry) f32 {
        return geometry.gutter_width + chart_width;
    }
};

fn layout(gantt: *const Gantt, canvas: *Canvas) scene.Error!void {
    assert(gantt.task_count > 0);
    assert(gantt.time_max > gantt.time_min);
    var gutter_width: f32 = gutter_width_min;
    for (gantt.sections[0..gantt.section_count]) |name| {
        const width = canvas.measurer.measure(name, .bold).width;
        gutter_width = @max(gutter_width, width + 2 * gutter_padding);
    }
    var rows_top: f32 = 0;
    if (gantt.title.len > 0) {
        const size = canvas.measurer.measure(gantt.title, .bold);
        try canvas.add(.{ .text = .{
            .origin = .{ .x = (gutter_width + chart_width) / 2, .y = size.height / 2 },
            .font = .bold,
            .bytes = gantt.title,
        } });
        rows_top = size.height + title_gap;
    }
    const rows: f32 = @floatFromInt(gantt.task_count);
    const span: f64 = @floatFromInt(gantt.time_max - gantt.time_min);
    const geometry: Geometry = .{
        .gutter_width = gutter_width,
        .rows_top = rows_top,
        .rows_bottom = rows_top + rows * row_height,
        .time_min = gantt.time_min,
        .scale = chart_width / span,
    };
    try sections_emit(gantt, geometry, canvas);
    try axis_emit(gantt, geometry, canvas);
    for (gantt.tasks[0..gantt.task_count], 0..) |task, index| {
        const row: f32 = @floatFromInt(index);
        try task_emit(task, geometry, rows_top + (row + 0.5) * row_height, canvas);
    }
}

fn sections_emit(gantt: *const Gantt, geometry: Geometry, canvas: *Canvas) scene.Error!void {
    assert(gantt.task_count > 0);
    assert(geometry.rows_bottom > geometry.rows_top);
    var row_first: u32 = 0;
    var band: u32 = 0;
    // Each iteration emits the band of the run of tasks that share a section.
    while (row_first < gantt.task_count) : (band += 1) {
        assert(band < tasks_max);
        const section = gantt.tasks[row_first].section;
        var row_end = row_first + 1;
        while (row_end < gantt.task_count and gantt.tasks[row_end].section == section) {
            row_end += 1;
        }
        const first: f32 = @floatFromInt(row_first);
        const count: f32 = @floatFromInt(row_end - row_first);
        const top = geometry.rows_top + first * row_height;
        try canvas.add(.{ .rect = .{
            .rect = .{
                .x = 0,
                .y = top,
                .width = geometry.chart_right(),
                .height = count * row_height,
            },
            .fill = if (band % 2 == 0) .group_fill else .none,
        } });
        if (section > 0) {
            try canvas.add(.{ .text = .{
                .origin = .{ .x = gutter_padding, .y = top + count * row_height / 2 },
                .anchor = .start,
                .font = .bold,
                .bytes = gantt.sections[section - 1],
            } });
        }
        row_first = row_end;
    }
}

const TickUnit = enum { hour, day, month, year };
const TickStep = struct { unit: TickUnit, count: u32 };

/// Tick steps from fine to coarse. Weeks are days counted from a Monday.
const tick_steps = [_]TickStep{
    .{ .unit = .hour, .count = 1 },   .{ .unit = .hour, .count = 3 },
    .{ .unit = .hour, .count = 6 },   .{ .unit = .hour, .count = 12 },
    .{ .unit = .day, .count = 1 },    .{ .unit = .day, .count = 2 },
    .{ .unit = .day, .count = 7 },    .{ .unit = .day, .count = 14 },
    .{ .unit = .month, .count = 1 },  .{ .unit = .month, .count = 3 },
    .{ .unit = .month, .count = 6 },  .{ .unit = .year, .count = 1 },
    .{ .unit = .year, .count = 2 },   .{ .unit = .year, .count = 5 },
    .{ .unit = .year, .count = 10 },  .{ .unit = .year, .count = 50 },
    .{ .unit = .year, .count = 100 }, .{ .unit = .year, .count = 1000 },
};

fn tick_step_seconds(step: TickStep) i64 {
    assert(step.count > 0);
    const unit: i64 = switch (step.unit) {
        .hour => seconds_per_hour,
        .day => seconds_per_day,
        .month => 30 * seconds_per_day,
        .year => 365 * seconds_per_day,
    };
    return unit * step.count;
}

/// Picks the finest step whose labels do not crowd each other.
fn tick_step_choose(span: i64, measurer: scene.Measurer) TickStep {
    assert(span > 0);
    for (tick_steps) |step| {
        const label_width = measurer.measure(tick_sample(step.unit), .small).width;
        const spacing_seconds: f64 = @floatFromInt(tick_step_seconds(step));
        const spacing = spacing_seconds * chart_width / @as(f64, @floatFromInt(span));
        if (spacing >= label_width + tick_label_spacing) return step;
    }
    return tick_steps[tick_steps.len - 1];
}

fn tick_sample(unit: TickUnit) []const u8 {
    return switch (unit) {
        .hour => "12-31 23:00",
        .day => "2000-12-31",
        .month => "2000-12",
        .year => "2000",
    };
}

fn div_ceil(numerator: i64, denominator: i64) i64 {
    assert(denominator > 0);
    const result = @divFloor(numerator + denominator - 1, denominator);
    assert(result * denominator >= numerator);
    return result;
}

/// Returns the first tick at or after `time` that lies on the step's grid.
fn tick_first(time: i64, step: TickStep) scene.Error!i64 {
    assert(step.count > 0);
    switch (step.unit) {
        .hour, .day => {
            const size = tick_step_seconds(step);
            // 1970-01-01 was a Thursday, so weekly grids are shifted to start on Mondays.
            const shift: i64 = if (step.unit == .day and step.count % 7 == 0)
                4 * seconds_per_day
            else
                0;
            return div_ceil(time - shift, size) * size + shift;
        },
        .month, .year => {
            const civil = civil_from_days(@divFloor(time, seconds_per_day));
            const months_per_step: i64 = if (step.unit == .year) 12 * step.count else step.count;
            var month_index = civil.year * 12 + (civil.month - 1);
            const at_month_start = civil.day == 1 and @mod(time, seconds_per_day) == 0;
            if (!at_month_start) month_index += 1;
            month_index = div_ceil(month_index, months_per_step) * months_per_step;
            const year = @divFloor(month_index, 12);
            if (year > year_max + 1000) return error.Overflow;
            const month: u32 = @intCast(@mod(month_index, 12) + 1);
            return days_from_civil(.{ .year = year, .month = month, .day = 1 }) * seconds_per_day;
        },
    }
}

fn tick_next(time: i64, step: TickStep) scene.Error!i64 {
    assert(step.count > 0);
    const result = switch (step.unit) {
        .hour, .day => time + tick_step_seconds(step),
        .month => try months_add(time, step.count),
        .year => try months_add(time, 12 * @as(i64, step.count)),
    };
    assert(result > time);
    return result;
}

fn tick_label(out: *scene.Scene, time: i64, unit: TickUnit) scene.Error![]const u8 {
    const civil = civil_from_days(@divFloor(time, seconds_per_day));
    assert(civil.year >= 0);
    const year: u32 = @intCast(civil.year);
    return switch (unit) {
        .hour => out.text_print("{d:0>2}-{d:0>2} {d:0>2}:00", .{
            civil.month,
            civil.day,
            @as(u32, @intCast(@divFloor(@mod(time, seconds_per_day), seconds_per_hour))),
        }),
        .day => out.text_print("{d:0>4}-{d:0>2}-{d:0>2}", .{ year, civil.month, civil.day }),
        .month => out.text_print("{d:0>4}-{d:0>2}", .{ year, civil.month }),
        .year => out.text_print("{d:0>4}", .{year}),
    };
}

fn axis_emit(gantt: *const Gantt, geometry: Geometry, canvas: *Canvas) scene.Error!void {
    assert(gantt.time_max > gantt.time_min);
    const axis_y = geometry.rows_bottom;
    const step = tick_step_choose(gantt.time_max - gantt.time_min, canvas.measurer);
    var time = try tick_first(gantt.time_min, step);
    var tick_count: u32 = 0;
    while (time <= gantt.time_max) : (time = try tick_next(time, step)) {
        if (tick_count == ticks_max) break;
        tick_count += 1;
        const x = geometry.x(time);
        try canvas.line(&.{
            .{ .x = x, .y = geometry.rows_top },
            .{ .x = x, .y = axis_y + tick_length },
        }, .dotted);
        try canvas.add(.{ .text = .{
            .origin = .{ .x = x, .y = axis_y + tick_length + tick_label_gap },
            .font = .small,
            .color = .text_muted,
            .bytes = try tick_label(canvas.out, time, step.unit),
        } });
    }
    try canvas.line(&.{
        .{ .x = geometry.gutter_width, .y = axis_y },
        .{ .x = geometry.chart_right(), .y = axis_y },
    }, .solid);
}

const BarStyle = struct { fill: scene.Color, stroke: scene.Color };

fn bar_style(task: Task) BarStyle {
    assert(task.resolved);
    if (task.crit) {
        return .{ .fill = if (task.done) .group_stroke else .series_4, .stroke = .series_4 };
    }
    if (task.done) return .{ .fill = .group_stroke, .stroke = .text_muted };
    if (task.active) return .{ .fill = .accent_fill, .stroke = .accent };
    return .{ .fill = .node_fill, .stroke = .node_stroke };
}

fn task_emit(task: Task, geometry: Geometry, middle: f32, canvas: *Canvas) scene.Error!void {
    assert(task.resolved);
    assert(middle > geometry.rows_top);
    const style = bar_style(task);
    var left = geometry.x(task.start);
    var right = @max(geometry.x(task.end), left + 2);
    if (task.milestone) {
        const half = bar_height / 2;
        left -= half;
        right = left + bar_height;
        const range = try canvas.out.points_add(&.{
            .{ .x = left + half, .y = middle - half },
            .{ .x = right, .y = middle },
            .{ .x = left + half, .y = middle + half },
            .{ .x = left, .y = middle },
        });
        try canvas.add(.{ .polygon = .{
            .points = range,
            .fill = if (task.crit) .series_4 else .accent,
            .stroke = style.stroke,
        } });
    } else {
        try canvas.add(.{ .rect = .{
            .rect = .{
                .x = left,
                .y = middle - bar_height / 2,
                .width = right - left,
                .height = bar_height,
            },
            .radius = bar_radius,
            .fill = style.fill,
            .stroke = style.stroke,
        } });
    }
    try task_label_emit(task, geometry, .{ .x = left, .y = middle }, right, canvas);
}

/// Places the label inside the bar when it fits, otherwise beside it where the chart has room.
fn task_label_emit(
    task: Task,
    geometry: Geometry,
    bar_start: scene.Point,
    bar_end_x: f32,
    canvas: *Canvas,
) scene.Error!void {
    assert(bar_end_x > bar_start.x);
    const width = canvas.measurer.measure(task.name, .regular).width;
    const fits_inside = !task.milestone and width + 2 * label_inset <= bar_end_x - bar_start.x;
    const fits_right = bar_end_x + label_gap + width <= geometry.chart_right();
    const fits_left = bar_start.x - label_gap - width >= geometry.gutter_width;
    var origin: scene.Point = .{ .x = bar_end_x + label_gap, .y = bar_start.y };
    var anchor: scene.Anchor = .start;
    if (fits_inside) {
        origin.x = (bar_start.x + bar_end_x) / 2;
        anchor = .middle;
    } else if (!fits_right and fits_left) {
        origin.x = bar_start.x - label_gap;
        anchor = .end;
    }
    try canvas.add(.{ .text = .{ .origin = origin, .anchor = anchor, .bytes = task.name } });
}

const testing = std.testing;

const Fixture = struct {
    commands: [2048]scene.Command = undefined,
    points: [4096]scene.Point = undefined,
    text: [8192]u8 = undefined,
    scratch: [256 * 1024]u8 = undefined,
    out: scene.Scene = undefined,

    fn run(fixture: *Fixture, source: []const u8) scene.Error!void {
        fixture.out = scene.Scene.init(&fixture.commands, &fixture.points, &fixture.text);
        try render(source, scene.Measurer.fixed, &fixture.scratch, &fixture.out);
    }
};

/// Checks that every command lies inside the scene, measuring text with the fixed measurer.
fn expect_inside(out: *const scene.Scene) !void {
    const measurer = scene.Measurer.fixed;
    for (out.commands_slice()) |command| {
        switch (command) {
            .rect => |c| try expect_rect_inside(out, c.rect),
            .ellipse => |c| try expect_rect_inside(out, c.rect),
            .wedge => |c| try expect_rect_inside(out, .{
                .x = c.center.x - c.radius,
                .y = c.center.y - c.radius,
                .width = 2 * c.radius,
                .height = 2 * c.radius,
            }),
            .text => |c| {
                const size = measurer.measure(c.bytes, c.font);
                const x = switch (c.anchor) {
                    .start => c.origin.x,
                    .middle => c.origin.x - size.width / 2,
                    .end => c.origin.x - size.width,
                };
                try expect_rect_inside(out, .{
                    .x = x,
                    .y = c.origin.y - size.height / 2,
                    .width = size.width,
                    .height = size.height,
                });
            },
            .line => |c| for (out.points_slice(c.points)) |p| try expect_point_inside(out, p),
            .polygon => |c| for (out.points_slice(c.points)) |p| try expect_point_inside(out, p),
        }
    }
}

fn expect_point_inside(out: *const scene.Scene, point: scene.Point) !void {
    try expect_rect_inside(out, .{ .x = point.x, .y = point.y, .width = 0, .height = 0 });
}

fn expect_rect_inside(out: *const scene.Scene, rect: scene.Rect) !void {
    try testing.expect(rect.x >= 0);
    try testing.expect(rect.y >= 0);
    try testing.expect(rect.x + rect.width <= out.size.width);
    try testing.expect(rect.y + rect.height <= out.size.height);
}

test "gantt: calendar arithmetic" {
    const expect_days = struct {
        fn check(days: i64, year: i64, month: u32, day: u32) !void {
            const civil: Civil = .{ .year = year, .month = month, .day = day };
            try testing.expectEqual(days, days_from_civil(civil));
            try testing.expectEqual(civil, civil_from_days(days));
        }
    }.check;
    try expect_days(0, 1970, 1, 1);
    try expect_days(10957, 2000, 1, 1);
    try expect_days(11017, 2000, 3, 1);
    try expect_days(-719468, 0, 3, 1);
    try expect_days(-25508, 1900, 3, 1);
    try testing.expect(is_leap_year(2000));
    try testing.expect(is_leap_year(2024));
    try testing.expect(!is_leap_year(1900));
    try testing.expect(!is_leap_year(2023));
    try testing.expectEqual(@as(u32, 29), days_in_month(2024, 2));
    try testing.expectEqual(@as(u32, 28), days_in_month(2100, 2));
    // Round trip across leap days and century boundaries.
    var days: i64 = days_from_civil(.{ .year = 1899, .month = 12, .day = 25 });
    const days_end = days_from_civil(.{ .year = 2101, .month = 1, .day = 5 });
    while (days <= days_end) : (days += 1) {
        const civil = civil_from_days(days);
        try testing.expectEqual(days, days_from_civil(civil));
        try testing.expect(civil.day <= days_in_month(civil.year, civil.month));
    }
    const leap_day = date_parse("2024-02-29").?;
    try testing.expectEqual(date_parse("2024-03-01").?, leap_day + seconds_per_day);
    try testing.expect(date_parse("2023-02-29") == null);
    try testing.expect(date_parse("1900-02-29") == null);
    try testing.expect(date_parse("2000-02-29") != null);
    try testing.expect(date_parse("2024-13-01") == null);
    try testing.expect(date_parse("2024-1-011") == null);
    const january_end = date_parse("2024-01-31").?;
    try testing.expectEqual(date_parse("2024-02-29").?, try months_add(january_end, 1));
    try testing.expectEqual(date_parse("2025-02-28").?, try months_add(leap_day, 12));
}

test "gantt: durations" {
    try testing.expectEqual(@as(i64, 3 * seconds_per_day), duration_parse("3d").?.seconds);
    try testing.expectEqual(@as(i64, 14 * seconds_per_day), duration_parse("2w").?.seconds);
    try testing.expectEqual(@as(i64, 12 * seconds_per_hour), duration_parse("12h").?.seconds);
    try testing.expectEqual(@as(i64, 36 * seconds_per_hour), duration_parse("1.5d").?.seconds);
    try testing.expectEqual(@as(i64, 24), duration_parse("2y").?.months);
    try testing.expect(duration_parse("d") == null);
    try testing.expect(duration_parse("-3d") == null);
    try testing.expect(duration_parse("3q") == null);
    try testing.expect(duration_parse("1.5M") == null);
}

test "gantt: parse and resolve tasks" {
    var gantt: Gantt = .{};
    try parse(
        \\gantt
        \\    title Plan
        \\    dateFormat YYYY-MM-DD
        \\    axisFormat %m/%d
        \\    excludes weekends
        \\    section Design
        \\    Research      :done, research, 2024-01-01, 5d
        \\    Mockups       :active, mockups, after research, 1w
        \\    section Build
        \\    Backend       :crit, backend, after mockups, 10d
        \\    Frontend      :frontend, after review, 3d
        \\    Review        :milestone, review, after backend, 0d
        \\    Polish        :2d
        \\    Freeze        :2024-02-20, until polish2
        \\    Polish two    :polish2, 2024-03-01, 2024-03-04
    , &gantt);
    try resolve(&gantt);
    try testing.expectEqualStrings("Plan", gantt.title);
    try testing.expectEqual(@as(u32, 2), gantt.section_count);
    try testing.expectEqual(@as(u32, 8), gantt.task_count);
    const day = seconds_per_day;
    const first = date_parse("2024-01-01").?;
    const tasks = gantt.tasks[0..gantt.task_count];
    try testing.expect(tasks[0].done);
    try testing.expectEqual(first + 5 * day, tasks[0].end);
    try testing.expectEqual(first + 5 * day, tasks[1].start);
    try testing.expect(tasks[2].crit);
    try testing.expectEqual(first + 22 * day, tasks[2].end);
    try testing.expectEqual(first + 22 * day, tasks[4].start);
    try testing.expect(tasks[4].milestone);
    try testing.expectEqual(first + 25 * day, tasks[3].end);
    try testing.expectEqual(tasks[4].end, tasks[5].start);
    try testing.expectEqual(date_parse("2024-03-01").?, tasks[6].end);
    try testing.expectEqual(@as(u32, 2), tasks[3].section);
}

test "gantt: malformed input" {
    var fixture: Fixture = .{};
    try testing.expectError(error.Syntax, fixture.run("gantt\n"));
    try testing.expectError(error.Syntax, fixture.run("gantt\nTask : 3d\n"));
    try testing.expectError(
        error.Syntax,
        fixture.run("gantt\ndateFormat DD-MM\nA : 2024-01-01, 1d"),
    );
    try testing.expectError(
        error.Syntax,
        fixture.run("gantt\nA : a, after b, 1d\nB : b, after a, 1d"),
    );
    try testing.expectError(error.Syntax, fixture.run("gantt\nA : a, after zz, 1d\n"));
    try testing.expectError(error.Syntax, fixture.run("gantt\nA : 2024-01-05, 2024-01-01\n"));
    try testing.expectError(error.Syntax, fixture.run("gantt\nA : 2024-01-01, 1d, 2d, 3d\n"));
    try testing.expectError(error.Syntax, fixture.run("gantt\nA without colon\n"));
    try testing.expectError(error.Syntax, fixture.run("gantt\nA : 2024-02-30, 1d\n"));
    try testing.expectError(error.Overflow, fixture.run("gantt\nA : 9999-12-01, 2M\n"));
}

test "gantt: layout geometry" {
    var fixture: Fixture = .{};
    try fixture.run(
        \\gantt
        \\    title A rather long title for a small chart
        \\    section Section one
        \\    A task with a very long label that cannot fit :a1, 2024-01-01, 1d
        \\    Another task :after a1, 20d
        \\    section Two
        \\    Ship :milestone, crit, 2024-01-21, 0d
    );
    try expect_inside(&fixture.out);
    var bar_count: u32 = 0;
    var diamond_count: u32 = 0;
    for (fixture.out.commands_slice()) |command| {
        switch (command) {
            .rect => |c| bar_count += @intFromBool(c.stroke != .none),
            .polygon => diamond_count += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(u32, 2), bar_count);
    try testing.expectEqual(@as(u32, 1), diamond_count);

    try fixture.run("gantt\nOnly hours : 2024-01-01, 7h\nNext : 30m");
    try expect_inside(&fixture.out);
    try fixture.run("gantt\nCentury : 1900-01-01, 2000-01-01");
    try expect_inside(&fixture.out);
}

test "gantt: truncated prefixes never crash" {
    const sample =
        \\gantt
        \\    title Plan
        \\    dateFormat YYYY-MM-DD
        \\    section Design
        \\    Research      :done, research, 2024-01-01, 5d
        \\    Mockups       :active, mockups, after research, 1w
        \\    section Build
        \\    Backend       :crit, backend, after mockups, 10d
        \\    Review        :milestone, review, after backend, 0d
        \\    Polish        :2d
    ;
    var fixture: Fixture = .{};
    for (0..sample.len + 1) |length| {
        fixture.run(sample[0..length]) catch continue;
        try expect_inside(&fixture.out);
    }
}
