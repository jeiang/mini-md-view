//! Foundation, AppKit and CoreGraphics declarations that the app uses, plus small helpers.
//!
//! Nothing here is generated from headers. Each declaration was checked against the SDK, and
//! enum values are spelled out where they are used, next to the name that the headers give them.

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc.zig");
const Id = objc.Id;

pub const Point = extern struct { x: f64 = 0, y: f64 = 0 };
pub const Size = extern struct { width: f64 = 0, height: f64 = 0 };
pub const Rect = extern struct {
    origin: Point = .{},
    size: Size = .{},

    pub fn init(x: f64, y: f64, width: f64, height: f64) Rect {
        return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = width, .height = height } };
    }
};
pub const Range = extern struct { location: usize, length: usize };
pub const EdgeInsets = extern struct { top: f64, left: f64, bottom: f64, right: f64 };

pub const type_rect = "{CGRect={CGPoint=dd}{CGSize=dd}}";
pub const type_point = "{CGPoint=dd}";
pub const type_size = "{CGSize=dd}";
pub const type_range = "{_NSRange=QQ}";

// Attributed string keys.
pub extern const NSFontAttributeName: Id;
pub extern const NSForegroundColorAttributeName: Id;
pub extern const NSBackgroundColorAttributeName: Id;
pub extern const NSParagraphStyleAttributeName: Id;
pub extern const NSLinkAttributeName: Id;
pub extern const NSStrikethroughStyleAttributeName: Id;
pub extern const NSToolTipAttributeName: Id;
pub extern const NSCursorAttributeName: Id;

pub extern const NSViewFrameDidChangeNotification: Id;
pub extern const NSToolbarToggleSidebarItemIdentifier: Id;
pub extern const NSToolbarSidebarTrackingSeparatorItemIdentifier: Id;
pub extern const NSToolbarFlexibleSpaceItemIdentifier: Id;
pub extern const NSDefaultRunLoopMode: Id;

/// NSTextAlignment. Apple Silicon uses the iOS values, where center is 1 and right is 2.
pub const TextAlignment = enum(isize) { left = 0, center = 1, right = 2, natural = 4 };

/// NSRectEdge.
pub const Edge = enum(usize) { x_min = 0, y_min = 1, x_max = 2, y_max = 3 };

/// NSTextBlockLayer.
pub const BlockLayer = enum(isize) { padding = -1, border = 0, margin = 1 };

pub const EventStream = *opaque {};
pub const EventStreamContext = extern struct {
    version: isize = 0,
    info: ?*anyopaque,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copy_description: ?*const anyopaque = null,
};
pub const EventStreamCallback = *const fn (
    stream: EventStream,
    info: ?*anyopaque,
    event_count: usize,
    event_paths: *anyopaque,
    event_flags: [*]const u32,
    event_ids: [*]const u64,
) callconv(.c) void;
/// kFSEventStreamEventIdSinceNow.
pub const event_id_since_now: u64 = 0xFFFFFFFFFFFFFFFF;
/// kFSEventStreamCreateFlagFileEvents.
pub const event_stream_flag_file_events: u32 = 0x10;

pub extern "c" fn FSEventStreamCreate(
    allocator: ?*anyopaque,
    callback: EventStreamCallback,
    context: *const EventStreamContext,
    paths: Id,
    since_when: u64,
    latency: f64,
    flags: u32,
) ?EventStream;
pub extern "c" fn FSEventStreamSetDispatchQueue(stream: EventStream, queue: ?*anyopaque) void;
pub extern "c" fn FSEventStreamStart(stream: EventStream) bool;
pub extern "c" fn FSEventStreamStop(stream: EventStream) void;
pub extern "c" fn FSEventStreamInvalidate(stream: EventStream) void;
pub extern "c" fn FSEventStreamRelease(stream: EventStream) void;
/// The main dispatch queue, which `dispatch_get_main_queue` returns.
pub extern "c" var _dispatch_main_q: opaque {};

pub const Context = *opaque {};
pub const Path = *opaque {};

pub extern "c" fn CGContextSaveGState(context: Context) void;
pub extern "c" fn CGContextRestoreGState(context: Context) void;
pub extern "c" fn CGContextTranslateCTM(context: Context, x: f64, y: f64) void;
pub extern "c" fn CGContextScaleCTM(context: Context, x: f64, y: f64) void;
pub extern "c" fn CGContextBeginPath(context: Context) void;
pub extern "c" fn CGContextMoveToPoint(context: Context, x: f64, y: f64) void;
pub extern "c" fn CGContextAddLineToPoint(context: Context, x: f64, y: f64) void;
pub extern "c" fn CGContextAddCurveToPoint(
    context: Context,
    control_1_x: f64,
    control_1_y: f64,
    control_2_x: f64,
    control_2_y: f64,
    x: f64,
    y: f64,
) void;
pub extern "c" fn CGContextAddArc(
    context: Context,
    x: f64,
    y: f64,
    radius: f64,
    angle_start: f64,
    angle_end: f64,
    clockwise: c_int,
) void;
pub extern "c" fn CGContextAddEllipseInRect(context: Context, rect: Rect) void;
pub extern "c" fn CGContextAddPath(context: Context, path: Path) void;
pub extern "c" fn CGContextClosePath(context: Context) void;
pub extern "c" fn CGContextFillPath(context: Context) void;
pub extern "c" fn CGContextStrokePath(context: Context) void;
pub extern "c" fn CGContextSetLineWidth(context: Context, width: f64) void;
pub extern "c" fn CGContextSetLineCap(context: Context, cap: c_int) void;
pub extern "c" fn CGContextSetLineJoin(context: Context, join: c_int) void;
pub extern "c" fn CGContextSetLineDash(
    context: Context,
    phase: f64,
    lengths: ?[*]const f64,
    count: usize,
) void;
pub extern "c" fn CGPathCreateWithRoundedRect(
    rect: Rect,
    corner_width: f64,
    corner_height: f64,
    transform: ?*const anyopaque,
) Path;
pub extern "c" fn CGPathRelease(path: Path) void;

/// The CoreGraphics context that AppKit is currently drawing into.
pub fn context_current() Context {
    const graphics = objc.send(?Id, objc.class("NSGraphicsContext"), "currentContext", .{});
    return objc.send(Context, graphics.?, "CGContext", .{});
}

/// Adds a rounded rectangle to the current path. The radius is clamped to what the rectangle
/// allows, which CoreGraphics requires.
pub fn path_add_rounded(context: Context, rect: Rect, radius: f64) void {
    assert(rect.size.width >= 0);
    assert(rect.size.height >= 0);
    const radius_max = @min(rect.size.width, rect.size.height) / 2;
    const radius_clamped = @max(0, @min(radius, radius_max));
    const path = CGPathCreateWithRoundedRect(rect, radius_clamped, radius_clamped, null);
    defer CGPathRelease(path);
    CGContextAddPath(context, path);
}

/// An autoreleased NSString with a copy of the bytes. Invalid UTF-8 gives an empty string.
pub fn string(bytes: []const u8) Id {
    const utf8_encoding: usize = 4;
    const allocated = objc.alloc("NSString");
    const created = objc.send(
        ?Id,
        allocated,
        "initWithBytes:length:encoding:",
        .{ bytes.ptr, bytes.len, utf8_encoding },
    ) orelse return objc.send(Id, objc.class("NSString"), "string", .{});
    return objc.autorelease(created);
}

/// The UTF-8 bytes of an NSString. They live as long as the string object does.
pub fn string_bytes(ns_string: Id) []const u8 {
    const bytes = objc.send(?[*:0]const u8, ns_string, "UTF8String", .{}) orelse return "";
    return std.mem.span(bytes);
}

/// A named system color, such as "labelColor". System colors follow the appearance.
pub fn color(comptime name: [:0]const u8) Id {
    return objc.send(Id, objc.class("NSColor"), name, .{});
}

pub fn color_alpha(base: Id, alpha: f64) Id {
    assert(alpha >= 0);
    assert(alpha <= 1);
    return objc.send(Id, base, "colorWithAlphaComponent:", .{alpha});
}

pub fn number(value: isize) Id {
    return objc.send(Id, objc.class("NSNumber"), "numberWithInteger:", .{value});
}

/// An autoreleased NSArray of the objects.
pub fn array(objects: []const Id) Id {
    return objc.send(
        Id,
        objc.class("NSArray"),
        "arrayWithObjects:count:",
        .{ objects.ptr, objects.len },
    );
}

/// An SF Symbol image, or null when the system does not have the symbol.
pub fn symbol(name: []const u8) ?Id {
    return objc.send(
        ?Id,
        objc.class("NSImage"),
        "imageWithSystemSymbolName:accessibilityDescription:",
        .{ string(name), @as(?Id, null) },
    );
}
