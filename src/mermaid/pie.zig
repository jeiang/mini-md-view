//! Mermaid pie charts: `pie [showData] [title Text]` followed by `"Label" : value` rows.
//!
//! Wedges start at 12 o'clock and run clockwise. Percentages sit inside the wedges that have room
//! for them, and a legend with color swatches sits to the right of the pie.

const std = @import("std");
const assert = std.debug.assert;
const scene = @import("../scene.zig");

const slices_max = 64;
const source_length_max = 1 << 24;

const padding = 16;
const radius = 120;
const title_gap = 16;
const legend_gap = 36;
const legend_row_height = 24;
const legend_swatch_size = 14;
const legend_swatch_gap = 10;
/// Percentage labels sit at this fraction of the radius, where wedges are wide enough for text.
const label_radius_ratio = 0.66;
const label_clearance = 6;

comptime {
    assert(legend_swatch_size < legend_row_height);
    assert(label_radius_ratio > 0.5);
    assert(label_radius_ratio < 1);
}

const Slice = struct { label: []const u8, value: f64 };

const Pie = struct {
    title: []const u8 = "",
    show_data: bool = false,
    slices: [slices_max]Slice = undefined,
    slice_count: u32 = 0,
    total: f64 = 0,
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
    const pie = allocator_state.allocator().create(Pie) catch return error.Overflow;
    pie.* = .{};
    try parse(source, pie);
    try layout(pie, measurer, out);
    assert(out.size.width > 0);
    assert(out.size.height > 0);
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

fn parse(source: []const u8, pie: *Pie) scene.Error!void {
    assert(pie.slice_count == 0);
    var lines: Lines = .{ .source = source };
    const header = lines.next() orelse return error.Syntax;
    var rest = word_strip(header, "pie") orelse return error.Syntax;
    if (word_strip(rest, "showData")) |after| {
        pie.show_data = true;
        rest = after;
    }
    if (word_strip(rest, "title")) |title| {
        pie.title = title;
    } else if (rest.len > 0) return error.Syntax;

    while (lines.next()) |line| {
        if (word_strip(line, "title")) |title| {
            pie.title = title;
        } else if (word_strip(line, "showData") != null) {
            pie.show_data = true;
        } else {
            try parse_slice(line, pie);
        }
    }
    if (pie.slice_count == 0) return error.Syntax;
    if (!(pie.total > 0)) return error.Syntax;
    if (!std.math.isFinite(pie.total)) return error.Overflow;
    assert(pie.slice_count <= slices_max);
}

fn parse_slice(line: []const u8, pie: *Pie) scene.Error!void {
    assert(line.len > 0);
    assert(pie.slice_count <= slices_max);
    if (line[0] != '"') return error.Syntax;
    const quote_end = std.mem.findScalarPos(u8, line, 1, '"') orelse return error.Syntax;
    const label = std.mem.trim(u8, line[1..quote_end], " \t");
    const rest = std.mem.trim(u8, line[quote_end + 1 ..], " \t");
    if (rest.len == 0 or rest[0] != ':') return error.Syntax;
    const number = std.mem.trim(u8, rest[1..], " \t");
    const value = std.fmt.parseFloat(f64, number) catch return error.Syntax;
    if (!std.math.isFinite(value)) return error.Syntax;
    if (value < 0) return error.Syntax;
    if (pie.slice_count == slices_max) return error.Overflow;
    pie.slices[pie.slice_count] = .{ .label = label, .value = value };
    pie.slice_count += 1;
    pie.total += value;
}

fn layout(pie: *const Pie, measurer: scene.Measurer, out: *scene.Scene) scene.Error!void {
    assert(pie.slice_count > 0);
    assert(pie.total > 0);
    // Legend entries are generated first, because their widths decide the scene width.
    var entries: [slices_max][]const u8 = undefined;
    var legend_text_width: f32 = 0;
    for (pie.slices[0..pie.slice_count], 0..) |slice, index| {
        entries[index] = if (pie.show_data)
            try out.text_print("{s} [{d}]", .{ slice.label, slice.value })
        else
            slice.label;
        const entry_width = measurer.measure(entries[index], .regular).width;
        legend_text_width = @max(legend_text_width, entry_width);
    }
    const legend_width = legend_swatch_size + legend_swatch_gap + legend_text_width;
    const count: f32 = @floatFromInt(pie.slice_count);
    const legend_height = count * legend_row_height;
    const content_width = 2 * radius + legend_gap + legend_width;
    const content_height = @max(2 * radius, legend_height);

    var top: f32 = padding;
    var width = content_width + 2 * padding;
    if (pie.title.len > 0) {
        const title_size = measurer.measure(pie.title, .bold);
        width = @max(width, title_size.width + 2 * padding);
        try out.command_add(.{ .text = .{
            .origin = .{ .x = width / 2, .y = top + title_size.height / 2 },
            .font = .bold,
            .bytes = pie.title,
        } });
        top += title_size.height + title_gap;
    }
    const left = (width - content_width) / 2;
    const center: scene.Point = .{ .x = left + radius, .y = top + content_height / 2 };
    try wedges_emit(pie, measurer, center, out);
    try legend_emit(pie, entries[0..pie.slice_count], .{
        .x = left + 2 * radius + legend_gap,
        .y = center.y - legend_height / 2,
    }, out);
    out.size = .{ .width = width, .height = top + content_height + padding };
    assert(out.size.width >= content_width);
}

/// Series colors wrap around, so the last wedge skips a color when it would otherwise touch a
/// wedge of the same color: the first one.
fn slice_color(index: u32, count: u32) scene.Color {
    assert(index < count);
    assert(count <= slices_max);
    const wraps = count > scene.Color.series_count and index % scene.Color.series_count == 0;
    if (wraps and index == count - 1) return scene.Color.series(index + 1);
    return scene.Color.series(index);
}

fn wedges_emit(
    pie: *const Pie,
    measurer: scene.Measurer,
    center: scene.Point,
    out: *scene.Scene,
) scene.Error!void {
    assert(pie.total > 0);
    assert(center.x >= radius);
    const turn: f64 = 2 * std.math.pi;
    const twelve_o_clock: f64 = -std.math.pi / 2.0;
    var cumulative: f64 = 0;
    for (pie.slices[0..pie.slice_count], 0..) |slice, index| {
        const fraction = slice.value / pie.total;
        const angle_start = twelve_o_clock + cumulative / pie.total * turn;
        cumulative += slice.value;
        const angle_end = twelve_o_clock + cumulative / pie.total * turn;
        assert(angle_end >= angle_start);
        if (fraction == 0) continue;
        const fill = slice_color(@intCast(index), pie.slice_count);
        if (fraction > 0.9999) {
            // A full turn has identical end points, which renderers draw as an empty arc.
            try out.command_add(.{ .ellipse = .{
                .rect = .{
                    .x = center.x - radius,
                    .y = center.y - radius,
                    .width = 2 * radius,
                    .height = 2 * radius,
                },
                .fill = fill,
            } });
        } else {
            try out.command_add(.{ .wedge = .{
                .center = center,
                .radius = radius,
                .angle_start = @floatCast(angle_start),
                .angle_end = @floatCast(angle_end),
                .fill = fill,
            } });
        }
        try percentage_emit(fraction, (angle_start + angle_end) / 2, measurer, center, out);
    }
}

fn percentage_emit(
    fraction: f64,
    angle_middle: f64,
    measurer: scene.Measurer,
    center: scene.Point,
    out: *scene.Scene,
) scene.Error!void {
    assert(fraction > 0);
    assert(fraction <= 1.0001);
    const text = try out.text_print("{d}%", .{@round(fraction * 100)});
    const size = measurer.measure(text, .small);
    const label_radius: f64 = radius * label_radius_ratio;
    // The label must fit across the wedge (arc length) and along it (wedge height).
    const arc_length = label_radius * fraction * 2 * std.math.pi;
    const fits_across = arc_length >= size.width + label_clearance;
    const fits_along = fraction >= 0.5 or arc_length >= size.height + label_clearance;
    if (!fits_across or !fits_along) {
        out.text_count -= @intCast(text.len);
        return;
    }
    try out.command_add(.{ .text = .{
        .origin = .{
            .x = center.x + @as(f32, @floatCast(label_radius * @cos(angle_middle))),
            .y = center.y + @as(f32, @floatCast(label_radius * @sin(angle_middle))),
        },
        .font = .small,
        .bytes = text,
    } });
}

fn legend_emit(
    pie: *const Pie,
    entries: []const []const u8,
    origin: scene.Point,
    out: *scene.Scene,
) scene.Error!void {
    assert(entries.len == pie.slice_count);
    assert(origin.y >= 0);
    for (entries, 0..) |entry, index| {
        const row: f32 = @floatFromInt(index);
        const middle = origin.y + (row + 0.5) * legend_row_height;
        try out.command_add(.{ .rect = .{
            .rect = .{
                .x = origin.x,
                .y = middle - legend_swatch_size / 2,
                .width = legend_swatch_size,
                .height = legend_swatch_size,
            },
            .radius = 3,
            .fill = slice_color(@intCast(index), pie.slice_count),
        } });
        try out.command_add(.{ .text = .{
            .origin = .{ .x = origin.x + legend_swatch_size + legend_swatch_gap, .y = middle },
            .anchor = .start,
            .bytes = entry,
        } });
    }
}

const testing = std.testing;

const Fixture = struct {
    commands: [512]scene.Command = undefined,
    points: [512]scene.Point = undefined,
    text: [4096]u8 = undefined,
    scratch: [64 * 1024]u8 = undefined,
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
            .line, .polygon => {},
        }
    }
}

fn expect_rect_inside(out: *const scene.Scene, rect: scene.Rect) !void {
    try testing.expect(rect.x >= 0);
    try testing.expect(rect.y >= 0);
    try testing.expect(rect.x + rect.width <= out.size.width);
    try testing.expect(rect.y + rect.height <= out.size.height);
}

test "pie: parse header, title, and slices" {
    var pie: Pie = .{};
    try parse(
        \\pie showData title Pets adopted
        \\    %% comment
        \\    "Dogs" : 386
        \\    "Cats" : 85.5;
        \\    "Rats" : 0
    , &pie);
    try testing.expect(pie.show_data);
    try testing.expectEqualStrings("Pets adopted", pie.title);
    try testing.expectEqual(@as(u32, 3), pie.slice_count);
    try testing.expectEqualStrings("Cats", pie.slices[1].label);
    try testing.expectEqual(@as(f64, 85.5), pie.slices[1].value);

    var pie_title_line: Pie = .{};
    try parse("pie\r\n  title Key elements\r\n  \"A\" : 1\r\n", &pie_title_line);
    try testing.expectEqualStrings("Key elements", pie_title_line.title);
    try testing.expect(!pie_title_line.show_data);
}

test "pie: malformed input" {
    var fixture: Fixture = .{};
    try testing.expectError(error.Syntax, fixture.run("pie\n\"A\" : -1\n"));
    try testing.expectError(error.Syntax, fixture.run("pie\n\"A\" : 0\n\"B\" : 0\n"));
    try testing.expectError(error.Syntax, fixture.run("pie\n"));
    try testing.expectError(error.Syntax, fixture.run("pie\nA : 1\n"));
    try testing.expectError(error.Syntax, fixture.run("pie\n\"A\" 1\n"));
    try testing.expectError(error.Syntax, fixture.run("pie\n\"A\" : x\n"));
    try testing.expectError(error.Syntax, fixture.run("pie\n\"A\" : nan\n"));
    try testing.expectError(error.Syntax, fixture.run("pie bogus\n\"A\" : 1\n"));
}

test "pie: too many slices overflow" {
    var source: [slices_max * 16 + 16]u8 = undefined;
    var length: usize = 0;
    length += (try std.fmt.bufPrint(source[length..], "pie\n", .{})).len;
    for (0..slices_max + 1) |_| {
        length += (try std.fmt.bufPrint(source[length..], "\"x\" : 1\n", .{})).len;
    }
    var fixture: Fixture = .{};
    try testing.expectError(error.Overflow, fixture.run(source[0..length]));
}

test "pie: layout geometry" {
    var fixture: Fixture = .{};
    try fixture.run(
        \\pie showData
        \\    title Where time goes
        \\    "Meetings" : 40
        \\    "Code" : 35
        \\    "Email" : 20
        \\    "Coffee" : 5
        \\    "Nothing" : 0
    );
    try expect_inside(&fixture.out);
    var wedge_count: u32 = 0;
    var angle_previous: f32 = -std.math.pi / 2.0;
    for (fixture.out.commands_slice()) |command| {
        if (command != .wedge) continue;
        wedge_count += 1;
        try testing.expectApproxEqAbs(angle_previous, command.wedge.angle_start, 0.0001);
        angle_previous = command.wedge.angle_end;
    }
    try testing.expectEqual(@as(u32, 4), wedge_count);
    try testing.expectApproxEqAbs(@as(f32, 1.5 * std.math.pi), angle_previous, 0.0001);

    try fixture.run("pie\n\"Everything\" : 3\n");
    try expect_inside(&fixture.out);
    try testing.expect(fixture.out.commands[0] == .ellipse);
}

test "pie: truncated prefixes never crash" {
    const sample =
        \\pie showData title Pets
        \\    accDescr {
        \\      multi line }
        \\    "Dogs" : 386
        \\    "Cats" : 85
        \\    "Rats" : 15.5
    ;
    var fixture: Fixture = .{};
    for (0..sample.len + 1) |length| {
        fixture.run(sample[0..length]) catch continue;
        try expect_inside(&fixture.out);
    }
}
