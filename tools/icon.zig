//! `zig build icon`: the icon of mini-md-view, a sheet of paper that shows a rendered document:
//! a heading behind its `#` mark, and three lines of text. The colors are flat. The sheet is the
//! tile of Apple's macOS icon grid (824 pixels in 1024), with a soft shadow under it.
//!
//! Every shape is a signed distance, so its edge is anti-aliased. The tool draws
//! assets/icon.png, and then `sips` and `iconutil`, which are part of macOS, make
//! assets/AppIcon.icns from it. Run it from the root of the repository, as build.zig does.

const std = @import("std");
const assert = std.debug.assert;
const flate = std.compress.flate;
const Io = std.Io;

const size = 1024;
const channels = 4;
const center = 512.0;

const Rgb = [3]f64;
const paper_color: Rgb = .{ 0xF7, 0xF4, 0xEC };
const mark_color: Rgb = .{ 0x2F, 0x7F, 0xD0 };
const heading_color: Rgb = .{ 0x2B, 0x2F, 0x36 };
const text_color: Rgb = .{ 0xC4, 0xBD, 0xAE };
const shadow_color: Rgb = .{ 0, 0, 0 };

const tile: Box = .{ .half = 412.0, .radius = 185.0 };
const shadow_y = 10.0;
const shadow_sigma = 14.0;
const shadow_alpha = 0.30;

const mark_radius = 17.0;
const strokes = [_]Stroke{
    // The `#` mark: two leaning uprights, then two bars across them.
    .{ .from = .{ 322, 268 }, .to = .{ 286, 452 }, .radius = mark_radius, .color = mark_color },
    .{ .from = .{ 400, 268 }, .to = .{ 364, 452 }, .radius = mark_radius, .color = mark_color },
    .{ .from = .{ 258, 326 }, .to = .{ 434, 326 }, .radius = mark_radius, .color = mark_color },
    .{ .from = .{ 252, 394 }, .to = .{ 428, 394 }, .radius = mark_radius, .color = mark_color },
    .{ .from = .{ 526, 360 }, .to = .{ 754, 360 }, .radius = 34, .color = heading_color },
    .{ .from = .{ 268, 560 }, .to = .{ 756, 560 }, .radius = 22, .color = text_color },
    .{ .from = .{ 268, 656 }, .to = .{ 756, 656 }, .radius = 22, .color = text_color },
    .{ .from = .{ 268, 752 }, .to = .{ 560, 752 }, .radius = 22, .color = text_color },
};

comptime {
    // The tile and the reach of its shadow fit the canvas.
    assert(center + tile.half + shadow_y + 4 * shadow_sigma < size);
    assert(center - tile.half > 0);
}

extern "c" fn erfc(x: f64) f64;

const icon_path = "assets/icon.png";
const icns_path = "assets/AppIcon.icns";
const iconset = "/tmp/mini-md-view-icon/AppIcon.iconset";
/// The sizes of the icon set. Each size is also there at twice the size (`@2x`).
const iconset_sides = [_]u32{ 16, 32, 128, 256, 512 };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const pixels = try arena.alloc(u8, size * size * channels);
    draw(pixels);
    var out: Io.Writer.Allocating = .init(arena);
    try png_write(arena, &out.writer, pixels);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = icon_path, .data = out.written() });

    try Io.Dir.cwd().createDirPath(io, iconset);
    for (iconset_sides) |side| {
        const one = try std.fmt.allocPrint(arena, "{s}/icon_{d}x{d}.png", .{
            iconset, side, side,
        });
        try resize(io, arena, side, one);
        const two = try std.fmt.allocPrint(arena, "{s}/icon_{d}x{d}@2x.png", .{
            iconset, side, side,
        });
        try resize(io, arena, side * 2, two);
    }
    try run(io, arena, &.{ "iconutil", "-c", "icns", "-o", icns_path, iconset });
}

/// Writes the icon to `to`, made `side` pixels square by `sips`.
fn resize(io: Io, arena: std.mem.Allocator, side: u32, to: []const u8) !void {
    assert(side > 0);
    assert(side <= size);
    const side_text = try std.fmt.allocPrint(arena, "{d}", .{side});
    try run(io, arena, &.{ "sips", "-z", side_text, side_text, icon_path, "--out", to });
}

/// Runs `argv`. Unless it exits with 0, prints what it said and fails.
fn run(io: Io, arena: std.mem.Allocator, argv: []const []const u8) !void {
    assert(argv.len > 0);
    const result = try std.process.run(arena, io, .{ .argv = argv });
    if (result.term.success()) return;
    std.debug.print("{s}: {s}{s}\n", .{ argv[0], result.stdout, result.stderr });
    return error.CommandFailed;
}

/// Writes `pixels` (rows of straight-alpha RGBA, top row first) as one PNG. No row is filtered.
fn png_write(gpa: std.mem.Allocator, writer: *Io.Writer, pixels: []const u8) !void {
    const row_bytes = size * channels;
    assert(pixels.len == row_bytes * size);
    // The compressor asserts that its output already has room.
    var data: Io.Writer.Allocating = try .initCapacity(gpa, pixels.len / 2);
    defer data.deinit();
    const compressor = try gpa.create(flate.Compress);
    defer gpa.destroy(compressor);
    const history = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(history);
    compressor.* = try .init(&data.writer, history, .zlib, .best);
    for (0..size) |row| {
        try compressor.writer.writeByte(0); // Filter type: none.
        try compressor.writer.writeAll(pixels[row * row_bytes ..][0..row_bytes]);
    }
    try compressor.finish();

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], size, .big);
    std.mem.writeInt(u32, header[4..8], size, .big);
    header[8..].* = .{ 8, 6, 0, 0, 0 }; // 8 bits for each channel, RGBA.
    try writer.writeAll("\x89PNG\r\n\x1a\n");
    try chunk_write(writer, "IHDR", &header);
    try chunk_write(writer, "IDAT", data.written());
    try chunk_write(writer, "IEND", "");
}

fn chunk_write(writer: *Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try writer.writeInt(u32, @intCast(data.len), .big);
    try writer.writeAll(kind);
    try writer.writeAll(data);
    try writer.writeInt(u32, crc.final(), .big);
}

/// Draws the whole icon, row by row. Each pixel is sampled at its center.
fn draw(pixels: []u8) void {
    assert(pixels.len == size * size * channels);
    for (0..size) |row| {
        for (0..size) |column| {
            const x = @as(f64, @floatFromInt(column)) + 0.5;
            const y = @as(f64, @floatFromInt(row)) + 0.5;
            const at = (row * size + column) * channels;
            pixels[at..][0..4].* = straight(pixel(x, y));
        }
    }
}

/// Premultiplied red, green, blue and alpha.
const Premultiplied = [4]f64;

/// Converts to straight alpha, which is what PNG keeps.
fn straight(px: Premultiplied) [4]u8 {
    const alpha = px[3];
    if (!(alpha > 0.0)) return .{ 0, 0, 0, 0 };
    return .{
        byte_of(px[0] / alpha),
        byte_of(px[1] / alpha),
        byte_of(px[2] / alpha),
        byte_of(alpha * 255),
    };
}

fn byte_of(value: f64) u8 {
    assert(value >= 0);
    assert(value < 255.5);
    return @intFromFloat(@round(value));
}

fn pixel(x: f64, y: f64) Premultiplied {
    var px: Premultiplied = .{ 0, 0, 0, 0 };
    const shadow_distance = tile.distance(x, y - shadow_y);
    if (shadow_distance < 4 * shadow_sigma) {
        const spread = shadow_distance / (shadow_sigma * @sqrt(2.0));
        px = over(px, shadow_color, shadow_alpha * 0.5 * erfc(spread));
    }
    px = over(px, paper_color, cover(tile.distance(x, y)));
    for (strokes) |stroke| px = over(px, stroke.color, cover(stroke.distance(x, y)));
    return px;
}

/// A rounded square about the center of the canvas.
const Box = struct {
    half: f64,
    radius: f64,

    fn distance(box: Box, x: f64, y: f64) f64 {
        const qx = @abs(x - center) - (box.half - box.radius);
        const qy = @abs(y - center) - (box.half - box.radius);
        const outside = std.math.hypot(@max(qx, 0.0), @max(qy, 0.0));
        return outside + @min(@max(qx, qy), 0.0) - box.radius;
    }
};

/// A line with round ends.
const Stroke = struct {
    from: [2]f64,
    to: [2]f64,
    radius: f64,
    color: Rgb,

    fn distance(stroke: Stroke, x: f64, y: f64) f64 {
        const along_x = stroke.to[0] - stroke.from[0];
        const along_y = stroke.to[1] - stroke.from[1];
        const length_squared = along_x * along_x + along_y * along_y;
        assert(length_squared > 0);
        const dot = (x - stroke.from[0]) * along_x + (y - stroke.from[1]) * along_y;
        const t = @min(1.0, @max(0.0, dot / length_squared));
        const nearest_x = stroke.from[0] + t * along_x;
        const nearest_y = stroke.from[1] + t * along_y;
        return std.math.hypot(x - nearest_x, y - nearest_y) - stroke.radius;
    }
};

/// The part of a pixel that a shape covers, from the distance at the center of the pixel.
fn cover(distance: f64) f64 {
    return @min(1.0, @max(0.0, 0.5 - distance));
}

/// Paints `rgb` at alpha `alpha` over the premultiplied `px`.
fn over(px: Premultiplied, rgb: Rgb, alpha: f64) Premultiplied {
    if (alpha <= 0.0) return px;
    const keep = 1.0 - alpha;
    return .{
        rgb[0] * alpha + px[0] * keep,
        rgb[1] * alpha + px[1] * keep,
        rgb[2] * alpha + px[2] * keep,
        alpha + px[3] * keep,
    };
}
