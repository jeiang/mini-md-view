//! Display list shared by diagram layout (pure Zig) and the AppKit canvas.
//!
//! Layout code appends commands and the canvas replays them in order. Coordinates are in points,
//! the origin is the top-left corner, and y grows downward. Every command lies inside
//! `Scene.size`. A scene owns no memory: the caller supplies the backing buffers, so that all
//! diagrams of a document share pools that are allocated once at startup.

const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{
    /// The diagram source is malformed or uses a construct that is not supported.
    Syntax,
    /// The diagram exceeds a static limit: commands, points, text, or scratch memory.
    Overflow,
};

pub const Point = struct { x: f32, y: f32 };
pub const Size = struct { width: f32, height: f32 };
pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };

/// Semantic colors. The canvas resolves them against the system appearance and accent color,
/// so layout code never chooses a concrete color.
pub const Color = enum(u8) {
    none,
    text,
    text_muted,
    /// Edges, lifelines, axes.
    line,
    node_fill,
    node_stroke,
    /// Subgraphs, composite states, loop frames, gantt sections.
    group_fill,
    group_stroke,
    note_fill,
    note_stroke,
    /// The system accent color, and a translucent variant for large filled areas.
    accent,
    accent_fill,
    series_0,
    series_1,
    series_2,
    series_3,
    series_4,
    series_5,
    series_6,
    series_7,

    pub const series_count = 8;

    /// Categorical color for the given index. Indexes wrap around.
    pub fn series(index: u32) Color {
        const first: u32 = @backingInt(Color.series_0);
        return @fromBackingInt(@intCast(first + index % series_count));
    }
};

pub const Font = enum(u8) { regular, bold, small };
pub const Anchor = enum(u8) { start, middle, end };
pub const Dash = enum(u8) { solid, dashed, dotted };

/// Line endings. The head sits at the line's end point and points along its last segment.
pub const Head = enum(u8) {
    none,
    /// Filled triangle.
    arrow,
    /// Two strokes, not filled.
    arrow_open,
    cross,
    circle,
    circle_filled,
    diamond,
    diamond_filled,
    /// Hollow triangle, as in UML inheritance.
    triangle,
};

/// A run of points in `Scene.points`.
pub const PointRange = struct { start: u32, count: u32 };

pub const Command = union(enum) {
    rect: struct {
        rect: Rect,
        radius: f32 = 0,
        fill: Color = .none,
        stroke: Color = .none,
        stroke_width: f32 = 1,
        dash: Dash = .solid,
    },
    ellipse: struct {
        rect: Rect,
        fill: Color = .none,
        stroke: Color = .none,
        stroke_width: f32 = 1,
    },
    /// Closed polygon through the points.
    polygon: struct {
        points: PointRange,
        fill: Color = .none,
        stroke: Color = .none,
        stroke_width: f32 = 1,
    },
    /// Open polyline through the points. When `smooth`, the canvas draws a curve that passes
    /// through every point instead of straight segments.
    line: struct {
        points: PointRange,
        stroke: Color = .line,
        stroke_width: f32 = 1,
        dash: Dash = .solid,
        smooth: bool = false,
        head_start: Head = .none,
        head_end: Head = .none,
    },
    /// Pie slice. Angles are radians, 0 points along +x, and angles grow clockwise on screen.
    wedge: struct {
        center: Point,
        radius: f32,
        angle_start: f32,
        angle_end: f32,
        fill: Color = .none,
        stroke: Color = .none,
    },
    /// One line of text. `origin.x` is the anchor position and `origin.y` is the vertical center
    /// of the line box. `bytes` must point into the diagram source or into `Scene.text`.
    text: struct {
        origin: Point,
        anchor: Anchor = .middle,
        font: Font = .regular,
        color: Color = .text,
        bytes: []const u8,
    },
};

/// Measures one line of text. The canvas implements this with the native text system.
pub const Measurer = struct {
    context: ?*anyopaque,
    measure_fn: *const fn (context: ?*anyopaque, bytes: []const u8, font: Font) Size,

    pub fn measure(measurer: Measurer, bytes: []const u8, font: Font) Size {
        const size = measurer.measure_fn(measurer.context, bytes, font);
        assert(size.width >= 0);
        assert(size.height > 0);
        return size;
    }

    /// Deterministic measurer for tests: every byte is 7 points wide, every line 16 points high.
    pub const fixed: Measurer = .{ .context = null, .measure_fn = measure_fixed };

    fn measure_fixed(context: ?*anyopaque, bytes: []const u8, font: Font) Size {
        assert(context == null);
        const advance: f32 = if (font == .small) 6 else 7;
        const count: f32 = @floatFromInt(bytes.len);
        return .{ .width = count * advance, .height = if (font == .small) 14 else 16 };
    }
};

pub const Scene = struct {
    commands: []Command,
    command_count: u32 = 0,
    points: []Point,
    point_count: u32 = 0,
    text: []u8,
    text_count: u32 = 0,
    size: Size = .{ .width = 0, .height = 0 },

    pub fn init(commands: []Command, points: []Point, text: []u8) Scene {
        assert(commands.len <= std.math.maxInt(u32));
        assert(points.len <= std.math.maxInt(u32));
        assert(text.len <= std.math.maxInt(u32));
        return .{ .commands = commands, .points = points, .text = text };
    }

    pub fn command_add(scene: *Scene, command: Command) Error!void {
        assert(scene.command_count <= scene.commands.len);
        if (scene.command_count == scene.commands.len) return error.Overflow;
        scene.commands[scene.command_count] = command;
        scene.command_count += 1;
    }

    pub fn points_add(scene: *Scene, points: []const Point) Error!PointRange {
        assert(scene.point_count <= scene.points.len);
        assert(points.len > 0);
        if (points.len > scene.points.len - scene.point_count) return error.Overflow;
        const range: PointRange = .{ .start = scene.point_count, .count = @intCast(points.len) };
        @memcpy(scene.points[range.start..][0..range.count], points);
        scene.point_count += range.count;
        return range;
    }

    /// Copies generated text into the scene, and returns a slice that lives as long as the scene.
    pub fn text_add(scene: *Scene, bytes: []const u8) Error![]const u8 {
        assert(scene.text_count <= scene.text.len);
        if (bytes.len > scene.text.len - scene.text_count) return error.Overflow;
        const target = scene.text[scene.text_count..][0..bytes.len];
        @memcpy(target, bytes);
        scene.text_count += @intCast(bytes.len);
        return target;
    }

    pub fn text_print(scene: *Scene, comptime fmt: []const u8, args: anytype) Error![]const u8 {
        assert(scene.text_count <= scene.text.len);
        const target = scene.text[scene.text_count..];
        const printed = std.fmt.bufPrint(target, fmt, args) catch return error.Overflow;
        scene.text_count += @intCast(printed.len);
        return printed;
    }

    pub fn commands_slice(scene: *const Scene) []const Command {
        assert(scene.command_count <= scene.commands.len);
        return scene.commands[0..scene.command_count];
    }

    pub fn points_slice(scene: *const Scene, range: PointRange) []const Point {
        assert(range.start + range.count <= scene.point_count);
        return scene.points[range.start..][0..range.count];
    }
};

test "scene: append and overflow" {
    var commands: [1]Command = undefined;
    var points: [3]Point = undefined;
    var text: [4]u8 = undefined;
    var scene = Scene.init(&commands, &points, &text);

    const range = try scene.points_add(&.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 } });
    try std.testing.expectEqual(@as(u32, 2), range.count);
    try std.testing.expectError(error.Overflow, scene.points_add(&.{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 1 },
    }));

    try scene.command_add(.{ .line = .{ .points = range } });
    try std.testing.expectError(
        error.Overflow,
        scene.command_add(.{ .line = .{ .points = range } }),
    );

    try std.testing.expectEqualStrings("42%", try scene.text_print("{d}%", .{42}));
    try std.testing.expectError(error.Overflow, scene.text_add("ab"));
    try std.testing.expectEqual(Color.series_1, Color.series(9));
}
