//! Diagram canvas: replays a `scene.Scene` with CoreGraphics, inside the text view.
//!
//! A diagram is embedded in the text as an attachment whose cell draws the scene directly into
//! the text view's context. There is no intermediate image: diagrams stay sharp at every scale,
//! and they follow the appearance and the accent color because semantic colors are resolved at
//! draw time.

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc.zig");
const cocoa = @import("cocoa.zig");
const scene = @import("scene.zig");
const Id = objc.Id;
const Context = cocoa.Context;

pub const Diagram = struct {
    scene: scene.Scene,
    /// Points on screen per scene point, before the diagram is fitted to the text width.
    zoom: f64,
};

const font_size_regular = 13;
const font_size_small = 11;

/// Text attributes for each scene font. They are created once, and they live forever.
var font_attributes: [std.enums.values(scene.Font).len]?Id = @splat(null);

fn font_create(font: scene.Font) Id {
    const weight_regular: f64 = 0;
    const weight_semibold: f64 = 0.3;
    return objc.send(Id, objc.class("NSFont"), "systemFontOfSize:weight:", switch (font) {
        .regular => .{ @as(f64, font_size_regular), weight_regular },
        .bold => .{ @as(f64, font_size_regular), weight_semibold },
        .small => .{ @as(f64, font_size_small), weight_regular },
    });
}

/// A mutable dictionary with the font. Drawing sets the color in it before each use.
fn attributes_for(font: scene.Font) Id {
    const index = @backingInt(font);
    if (font_attributes[index]) |attributes| return attributes;
    const attributes = objc.retain(objc.new("NSMutableDictionary"));
    objc.send(void, attributes, "setObject:forKey:", .{
        font_create(font),
        cocoa.NSFontAttributeName,
    });
    font_attributes[index] = attributes;
    return attributes;
}

fn text_size(bytes: []const u8, font: scene.Font) cocoa.Size {
    const size = objc.send(
        cocoa.Size,
        cocoa.string(bytes),
        "sizeWithAttributes:",
        .{attributes_for(font)},
    );
    assert(size.width >= 0);
    assert(size.height >= 0);
    return size;
}

fn measure(context: ?*anyopaque, bytes: []const u8, font: scene.Font) scene.Size {
    assert(context == null);
    const size = text_size(bytes, font);
    const line_height: f64 = if (font == .small) font_size_small + 3 else font_size_regular + 3;
    return .{
        .width = @floatCast(@ceil(size.width)),
        .height = @floatCast(@ceil(@max(size.height, line_height))),
    };
}

/// Measures diagram text with the fonts that `draw` uses.
pub const measurer: scene.Measurer = .{ .context = null, .measure_fn = measure };

fn color_resolve(color: scene.Color) Id {
    const accent = cocoa.color("controlAccentColor");
    return switch (color) {
        .none => cocoa.color("clearColor"),
        .text => cocoa.color("labelColor"),
        .text_muted => cocoa.color("secondaryLabelColor"),
        .line => cocoa.color("secondaryLabelColor"),
        .node_fill => cocoa.color_alpha(accent, 0.12),
        .node_stroke => accent,
        .group_fill => cocoa.color_alpha(cocoa.color("labelColor"), 0.04),
        .group_stroke => cocoa.color("tertiaryLabelColor"),
        .note_fill => cocoa.color_alpha(cocoa.color("systemYellowColor"), 0.2),
        .note_stroke => cocoa.color_alpha(cocoa.color("systemYellowColor"), 0.8),
        .accent => accent,
        .accent_fill => cocoa.color_alpha(accent, 0.3),
        .series_0 => cocoa.color("systemBlueColor"),
        .series_1 => cocoa.color("systemGreenColor"),
        .series_2 => cocoa.color("systemOrangeColor"),
        .series_3 => cocoa.color("systemPurpleColor"),
        .series_4 => cocoa.color("systemPinkColor"),
        .series_5 => cocoa.color("systemTealColor"),
        .series_6 => cocoa.color("systemYellowColor"),
        .series_7 => cocoa.color("systemBrownColor"),
    };
}

const Paint = struct {
    fill: scene.Color = .none,
    stroke: scene.Color = .none,
    stroke_width: f32 = 1,
    dash: scene.Dash = .solid,
};

/// Fills and strokes the current path, then clears it.
fn path_paint(context: Context, paint: Paint) void {
    assert(paint.stroke_width >= 0);
    const mode_fill: c_int = 0;
    const mode_stroke: c_int = 2;
    const mode_fill_stroke: c_int = 3;
    const filled = paint.fill != .none;
    const stroked = paint.stroke != .none and paint.stroke_width > 0;
    if (filled) objc.send(void, color_resolve(paint.fill), "setFill", .{});
    if (stroked) {
        objc.send(void, color_resolve(paint.stroke), "setStroke", .{});
        cocoa.CGContextSetLineWidth(context, paint.stroke_width);
        const width: f64 = @max(1, paint.stroke_width);
        const dashed = [_]f64{ 5 * width, 4 * width };
        const dotted = [_]f64{ 1.5 * width, 3 * width };
        switch (paint.dash) {
            .solid => cocoa.CGContextSetLineDash(context, 0, null, 0),
            .dashed => cocoa.CGContextSetLineDash(context, 0, &dashed, dashed.len),
            .dotted => cocoa.CGContextSetLineDash(context, 0, &dotted, dotted.len),
        }
    }
    if (filled and stroked) {
        CGContextDrawPath(context, mode_fill_stroke);
    } else if (filled) {
        CGContextDrawPath(context, mode_fill);
    } else if (stroked) {
        CGContextDrawPath(context, mode_stroke);
    } else {
        cocoa.CGContextBeginPath(context);
    }
}

extern "c" fn CGContextDrawPath(context: Context, mode: c_int) void;

fn rect_convert(rect: scene.Rect) cocoa.Rect {
    return cocoa.Rect.init(rect.x, rect.y, @max(0, rect.width), @max(0, rect.height));
}

/// Draws the scene with its origin at the origin of the current coordinate system.
fn scene_draw(context: Context, drawn: *const scene.Scene) void {
    const cap_round: c_int = 1;
    const join_round: c_int = 1;
    cocoa.CGContextSetLineCap(context, cap_round);
    cocoa.CGContextSetLineJoin(context, join_round);
    for (drawn.commands_slice()) |command| switch (command) {
        .rect => |c| {
            cocoa.path_add_rounded(context, rect_convert(c.rect), c.radius);
            path_paint(context, .{
                .fill = c.fill,
                .stroke = c.stroke,
                .stroke_width = c.stroke_width,
                .dash = c.dash,
            });
        },
        .ellipse => |c| {
            cocoa.CGContextAddEllipseInRect(context, rect_convert(c.rect));
            path_paint(context, .{
                .fill = c.fill,
                .stroke = c.stroke,
                .stroke_width = c.stroke_width,
            });
        },
        .polygon => |c| {
            const points = drawn.points_slice(c.points);
            if (points.len < 2) continue;
            cocoa.CGContextMoveToPoint(context, points[0].x, points[0].y);
            for (points[1..]) |point| cocoa.CGContextAddLineToPoint(context, point.x, point.y);
            cocoa.CGContextClosePath(context);
            path_paint(context, .{
                .fill = c.fill,
                .stroke = c.stroke,
                .stroke_width = c.stroke_width,
            });
        },
        .line => |c| {
            const points = drawn.points_slice(c.points);
            if (points.len < 2) continue;
            line_draw(context, points, c.smooth, c.head_start, c.head_end);
            path_paint(context, .{
                .stroke = c.stroke,
                .stroke_width = c.stroke_width,
                .dash = c.dash,
            });
            const last = points.len - 1;
            head_draw(context, c.head_start, points[0], points[1], c.stroke, c.stroke_width);
            head_draw(
                context,
                c.head_end,
                points[last],
                points[last - 1],
                c.stroke,
                c.stroke_width,
            );
        },
        .wedge => |c| wedge_draw(context, c),
        .text => |c| text_draw(c),
    };
}

/// Draws one wedge command. It is separate from `scene_draw` to keep that function short.
fn wedge_draw(context: Context, c: anytype) void {
    cocoa.CGContextMoveToPoint(context, c.center.x, c.center.y);
    cocoa.CGContextAddArc(
        context,
        c.center.x,
        c.center.y,
        c.radius,
        c.angle_start,
        c.angle_end,
        0,
    );
    cocoa.CGContextClosePath(context);
    path_paint(context, .{ .fill = c.fill, .stroke = c.stroke });
}

/// Draws one text command. It is separate from `scene_draw` to keep that function short.
fn text_draw(c: anytype) void {
    const size = text_size(c.bytes, c.font);
    const x: f64 = switch (c.anchor) {
        .start => c.origin.x,
        .middle => c.origin.x - size.width / 2,
        .end => c.origin.x - size.width,
    };
    const origin: cocoa.Point = .{ .x = x, .y = c.origin.y - size.height / 2 };
    const attributes = attributes_for(c.font);
    objc.send(void, attributes, "setObject:forKey:", .{
        color_resolve(c.color),
        cocoa.NSForegroundColorAttributeName,
    });
    objc.send(void, cocoa.string(c.bytes), "drawAtPoint:withAttributes:", .{
        origin,
        attributes,
    });
}

/// How far a line is cut back at an end, so that it does not poke through the head's tip.
fn head_inset(head: scene.Head) f32 {
    return switch (head) {
        .none, .arrow_open, .cross => 0,
        .arrow => 6,
        .circle, .circle_filled => 8,
        .diamond, .diamond_filled => 14,
        .triangle => 12,
    };
}

/// Moves `point` toward `toward` by `distance`, but not past it.
fn point_toward(point: scene.Point, toward: scene.Point, distance: f32) scene.Point {
    const delta_x = toward.x - point.x;
    const delta_y = toward.y - point.y;
    const length = @sqrt(delta_x * delta_x + delta_y * delta_y);
    if (length < 0.001) return point;
    const fraction = @min(1, distance / length);
    return .{ .x = point.x + delta_x * fraction, .y = point.y + delta_y * fraction };
}

/// Adds the line to the current path. A smooth line is a Catmull-Rom spline through the points,
/// converted to cubic Bezier segments.
fn line_draw(
    context: Context,
    points: []const scene.Point,
    smooth: bool,
    head_start: scene.Head,
    head_end: scene.Head,
) void {
    assert(points.len >= 2);
    const last = points.len - 1;
    const first_point = point_toward(points[0], points[1], head_inset(head_start));
    const last_point = point_toward(points[last], points[last - 1], head_inset(head_end));
    cocoa.CGContextMoveToPoint(context, first_point.x, first_point.y);
    for (1..points.len) |index| {
        const to = if (index == last) last_point else points[index];
        if (!smooth or points.len == 2) {
            cocoa.CGContextAddLineToPoint(context, to.x, to.y);
            continue;
        }
        const from = if (index == 1) first_point else points[index - 1];
        const before = if (index >= 2) points[index - 2] else from;
        const after = if (index < last) points[index + 1] else to;
        cocoa.CGContextAddCurveToPoint(
            context,
            from.x + (to.x - before.x) / 6,
            from.y + (to.y - before.y) / 6,
            to.x - (after.x - from.x) / 6,
            to.y - (after.y - from.y) / 6,
            to.x,
            to.y,
        );
    }
}

/// Draws a line ending at `tip`, for a line that arrives from `from`.
fn head_draw(
    context: Context,
    head: scene.Head,
    tip: scene.Point,
    from: scene.Point,
    color: scene.Color,
    stroke_width: f32,
) void {
    if (head == .none) return;
    const delta_x: f64 = tip.x - from.x;
    const delta_y: f64 = tip.y - from.y;
    const length = @sqrt(delta_x * delta_x + delta_y * delta_y);
    if (length < 0.001) return;
    // `along` points from the tip back along the line, and `across` is perpendicular to it.
    const along: cocoa.Point = .{ .x = -delta_x / length, .y = -delta_y / length };
    const across: cocoa.Point = .{ .x = -along.y, .y = along.x };
    const hollow: Paint = .{ .fill = .none, .stroke = color, .stroke_width = stroke_width };
    const solid: Paint = .{ .fill = color, .stroke = color, .stroke_width = stroke_width };
    switch (head) {
        .none => unreachable,
        .arrow => {
            head_polygon(context, tip, along, across, &.{ .{ 0, 0 }, .{ 9, 4 }, .{ 9, -4 } }, true);
            path_paint(context, .{ .fill = color });
        },
        .arrow_open => {
            const arrow_points: []const [2]f64 = &.{ .{ 9, 4.5 }, .{ 0, 0 }, .{ 9, -4.5 } };
            head_polygon(context, tip, along, across, arrow_points, false);
            path_paint(context, hollow);
        },
        .cross => {
            head_polygon(context, tip, along, across, &.{ .{ 2, 4.5 }, .{ 11, -4.5 } }, false);
            head_polygon(context, tip, along, across, &.{ .{ 2, -4.5 }, .{ 11, 4.5 } }, false);
            path_paint(context, hollow);
        },
        .circle, .circle_filled => {
            const center_x = tip.x + along.x * 4;
            const center_y = tip.y + along.y * 4;
            const circle_rect = cocoa.Rect.init(center_x - 4, center_y - 4, 8, 8);
            cocoa.CGContextAddEllipseInRect(context, circle_rect);
            path_paint(context, if (head == .circle) hollow else solid);
        },
        .diamond, .diamond_filled => {
            const shape = [_][2]f64{ .{ 0, 0 }, .{ 7, 4.5 }, .{ 14, 0 }, .{ 7, -4.5 } };
            head_polygon(context, tip, along, across, &shape, true);
            path_paint(context, if (head == .diamond) hollow else solid);
        },
        .triangle => {
            const triangle_points: []const [2]f64 = &.{ .{ 0, 0 }, .{ 12, 6.5 }, .{ 12, -6.5 } };
            head_polygon(context, tip, along, across, triangle_points, true);
            path_paint(context, hollow);
        },
    }
}

/// Adds a shape to the current path. Each vertex is given as a distance back along the line and
/// a distance across it.
fn head_polygon(
    context: Context,
    tip: scene.Point,
    along: cocoa.Point,
    across: cocoa.Point,
    vertices: []const [2]f64,
    closed: bool,
) void {
    assert(vertices.len >= 2);
    for (vertices, 0..) |vertex, index| {
        const x = tip.x + along.x * vertex[0] + across.x * vertex[1];
        const y = tip.y + along.y * vertex[0] + across.y * vertex[1];
        if (index == 0) {
            cocoa.CGContextMoveToPoint(context, x, y);
        } else {
            cocoa.CGContextAddLineToPoint(context, x, y);
        }
    }
    if (closed) cocoa.CGContextClosePath(context);
}

fn cell_diagram(cell: Id) *const Diagram {
    const diagram: *const Diagram = @ptrCast(@alignCast(objc.payload_get(cell).?));
    assert(diagram.scene.size.width > 0);
    assert(diagram.scene.size.height > 0);
    assert(diagram.zoom > 0);
    return diagram;
}

fn cell_size(cell: Id, _: objc.Selector) callconv(.c) cocoa.Size {
    const diagram = cell_diagram(cell);
    return .{
        .width = diagram.scene.size.width * diagram.zoom,
        .height = diagram.scene.size.height * diagram.zoom,
    };
}

/// Fits the diagram to the line: it shrinks when the text column is narrower than the diagram.
fn cell_frame(
    cell: Id,
    _: objc.Selector,
    _: ?Id,
    line_fragment: cocoa.Rect,
    _: cocoa.Point,
    _: usize,
) callconv(.c) cocoa.Rect {
    const diagram = cell_diagram(cell);
    const width_natural = diagram.scene.size.width * diagram.zoom;
    const width_available = @max(64, line_fragment.size.width - 2);
    const width = @min(width_natural, width_available);
    const height = diagram.scene.size.height * diagram.zoom * (width / width_natural);
    return cocoa.Rect.init(0, 0, @floor(width), @ceil(height));
}

fn cell_draw(cell: Id, _: objc.Selector, frame: cocoa.Rect, _: ?Id) callconv(.c) void {
    const diagram = cell_diagram(cell);
    if (frame.size.width < 1) return;
    const context = cocoa.context_current();
    const scale = frame.size.width / diagram.scene.size.width;
    cocoa.CGContextSaveGState(context);
    defer cocoa.CGContextRestoreGState(context);
    cocoa.CGContextTranslateCTM(context, frame.origin.x, frame.origin.y);
    cocoa.CGContextScaleCTM(context, scale, scale);
    scene_draw(context, &diagram.scene);
}

fn cell_tracks_mouse(_: Id, _: objc.Selector) callconv(.c) bool {
    return false;
}

var cell_class: ?Id = null;

fn cell_class_get() Id {
    if (cell_class) |defined| return defined;
    const frame_name =
        "cellFrameForTextContainer:proposedLineFragment:glyphPosition:characterIndex:";
    cell_class = objc.class_define("MiniedDiagramCell", "NSTextAttachmentCell", &.{
        .{ .name = "cellSize", .types = cocoa.type_size ++ "@:", .implementation = &cell_size },
        .{
            .name = frame_name,
            .types = cocoa.type_rect ++ "@:@" ++ cocoa.type_rect ++ cocoa.type_point ++ "Q",
            .implementation = &cell_frame,
        },
        .{
            .name = "drawWithFrame:inView:",
            .types = "v@:" ++ cocoa.type_rect ++ "@",
            .implementation = &cell_draw,
        },
        .{ .name = "wantsToTrackMouse", .types = "B@:", .implementation = &cell_tracks_mouse },
    }, true);
    return cell_class.?;
}

/// An autoreleased attributed string that holds the diagram as a text attachment. The diagram
/// must stay valid and unchanged for as long as any text storage holds the attachment.
pub fn attachment_string(diagram: *const Diagram) Id {
    assert(diagram.scene.size.width > 0);
    assert(diagram.scene.size.height > 0);
    const cell_allocated = objc.send(Id, cell_class_get(), "alloc", .{});
    const cell = objc.autorelease(objc.send(Id, cell_allocated, "init", .{}));
    objc.payload_set(cell, @constCast(diagram));
    const attachment = objc.new("NSTextAttachment");
    objc.send(void, attachment, "setAttachmentCell:", .{cell});
    return objc.send(
        Id,
        objc.class("NSAttributedString"),
        "attributedStringWithAttachment:",
        .{attachment},
    );
}
