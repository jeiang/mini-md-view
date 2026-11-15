//! Development aid: dumps a `Scene` as SVG, so that layout code can be inspected without the app.
//! Colors are fixed approximations of the light appearance. The app never calls this.

const std = @import("std");
const assert = std.debug.assert;
const scene_module = @import("scene.zig");
const Scene = scene_module.Scene;
const Color = scene_module.Color;

const Output = struct {
    buffer: []u8,
    count: usize = 0,

    fn print(output: *Output, comptime fmt: []const u8, args: anytype) error{Overflow}!void {
        const printed = std.fmt.bufPrint(output.buffer[output.count..], fmt, args) catch {
            return error.Overflow;
        };
        output.count += printed.len;
    }
};

fn color_css(color: Color) []const u8 {
    return switch (color) {
        .none => "none",
        .text => "#1d1d1f",
        .text_muted => "#6e6e73",
        .line => "#48484a",
        .node_fill => "#e8f0fe",
        .node_stroke => "#0a84ff",
        .group_fill => "#f5f5f7",
        .group_stroke => "#c7c7cc",
        .note_fill => "#fff8d6",
        .note_stroke => "#d9b600",
        .accent => "#0a84ff",
        .accent_fill => "#b5d6ff",
        .series_0 => "#0a84ff",
        .series_1 => "#30d158",
        .series_2 => "#ff9f0a",
        .series_3 => "#bf5af2",
        .series_4 => "#ff375f",
        .series_5 => "#64d2ff",
        .series_6 => "#ffd60a",
        .series_7 => "#ac8e68",
    };
}

fn dash_css(dash: scene_module.Dash) []const u8 {
    return switch (dash) {
        .solid => "",
        .dashed => " stroke-dasharray=\"6 4\"",
        .dotted => " stroke-dasharray=\"2 3\"",
    };
}

/// Writes the scene into `buffer`, and returns the SVG bytes. Arrow heads are drawn as dots.
pub fn write(scene: *const Scene, buffer: []u8) error{Overflow}![]const u8 {
    assert(scene.size.width >= 0);
    assert(scene.size.height >= 0);
    var output: Output = .{ .buffer = buffer };
    try output.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {d:.1} {d:.1}\" " ++
            "font-family=\"sans-serif\" font-size=\"13\">\n",
        .{ scene.size.width, scene.size.height },
    );
    for (scene.commands_slice()) |command| try write_command(scene, &output, command);
    try output.print("</svg>\n", .{});
    return output.buffer[0..output.count];
}

fn write_command(
    scene: *const Scene,
    output: *Output,
    command: scene_module.Command,
) error{Overflow}!void {
    switch (command) {
        .rect => |c| try output.print(
            "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"{d:.1}\" " ++
                "fill=\"{s}\" stroke=\"{s}\" stroke-width=\"{d:.1}\"{s}/>\n",
            .{
                c.rect.x,         c.rect.y,          c.rect.width,        c.rect.height,
                c.radius,         color_css(c.fill), color_css(c.stroke), c.stroke_width,
                dash_css(c.dash),
            },
        ),
        .ellipse => |c| try output.print(
            "<ellipse cx=\"{d:.1}\" cy=\"{d:.1}\" rx=\"{d:.1}\" ry=\"{d:.1}\" " ++
                "fill=\"{s}\" stroke=\"{s}\" stroke-width=\"{d:.1}\"/>\n",
            .{
                c.rect.x + c.rect.width / 2, c.rect.y + c.rect.height / 2,
                c.rect.width / 2,            c.rect.height / 2,
                color_css(c.fill),           color_css(c.stroke),
                c.stroke_width,
            },
        ),
        .polygon => |c| {
            try output.print("<polygon points=\"", .{});
            for (scene.points_slice(c.points)) |p| {
                try output.print("{d:.1},{d:.1} ", .{ p.x, p.y });
            }
            try output.print(
                "\" fill=\"{s}\" stroke=\"{s}\" stroke-width=\"{d:.1}\"/>\n",
                .{ color_css(c.fill), color_css(c.stroke), c.stroke_width },
            );
        },
        .line => |c| {
            const points = scene.points_slice(c.points);
            try output.print("<polyline points=\"", .{});
            for (points) |p| try output.print("{d:.1},{d:.1} ", .{ p.x, p.y });
            try output.print(
                "\" fill=\"none\" stroke=\"{s}\" stroke-width=\"{d:.1}\"{s}/>\n",
                .{ color_css(c.stroke), c.stroke_width, dash_css(c.dash) },
            );
            if (c.head_start != .none) try write_head(output, points[0], c.stroke);
            if (c.head_end != .none) try write_head(output, points[points.len - 1], c.stroke);
        },
        .wedge => |c| try output.print(
            "<path d=\"M{d:.1},{d:.1} L{d:.1},{d:.1} A{d:.1},{d:.1} 0 {d} 1 {d:.1},{d:.1} Z\" " ++
                "fill=\"{s}\" stroke=\"{s}\"/>\n",
            .{
                c.center.x,
                c.center.y,
                c.center.x + c.radius * @cos(c.angle_start),
                c.center.y + c.radius * @sin(c.angle_start),
                c.radius,
                c.radius,
                @intFromBool(c.angle_end - c.angle_start > std.math.pi),
                c.center.x + c.radius * @cos(c.angle_end),
                c.center.y + c.radius * @sin(c.angle_end),
                color_css(c.fill),
                color_css(c.stroke),
            },
        ),
        .text => |c| try write_text(output, c),
    }
}

fn write_head(output: *Output, point: scene_module.Point, color: Color) error{Overflow}!void {
    try output.print(
        "<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"3\" fill=\"{s}\"/>\n",
        .{ point.x, point.y, color_css(color) },
    );
}

fn write_text(output: *Output, text: anytype) error{Overflow}!void {
    const anchor = switch (text.anchor) {
        .start => "start",
        .middle => "middle",
        .end => "end",
    };
    try output.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"{s}\" dominant-baseline=\"central\" " ++
            "fill=\"{s}\"{s}{s}>",
        .{
            text.origin.x,
            text.origin.y,
            anchor,
            color_css(text.color),
            if (text.font == .bold) " font-weight=\"bold\"" else "",
            if (text.font == .small) " font-size=\"11\"" else "",
        },
    );
    for (text.bytes) |byte| switch (byte) {
        '<' => try output.print("&lt;", .{}),
        '>' => try output.print("&gt;", .{}),
        '&' => try output.print("&amp;", .{}),
        else => try output.print("{c}", .{byte}),
    };
    try output.print("</text>\n", .{});
}

test "scene_svg: writes every command kind" {
    var commands: [8]scene_module.Command = undefined;
    var points: [8]scene_module.Point = undefined;
    var text: [16]u8 = undefined;
    var scene = Scene.init(&commands, &points, &text);
    scene.size = .{ .width = 100, .height = 50 };
    const range = try scene.points_add(&.{ .{ .x = 0, .y = 0 }, .{ .x = 9, .y = 9 } });
    try scene.command_add(.{ .rect = .{ .rect = .{ .x = 1, .y = 2, .width = 3, .height = 4 } } });
    try scene.command_add(.{ .line = .{ .points = range, .head_end = .arrow } });
    try scene.command_add(.{ .text = .{ .origin = .{ .x = 5, .y = 5 }, .bytes = "a<b" } });

    var buffer: [2048]u8 = undefined;
    const svg = try write(&scene, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect ") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<polyline ") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "a&lt;b") != null);
}
