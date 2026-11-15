//! Remote images: the only part of the viewer that uses the network.
//!
//! A document can name images by `https` URL. Nothing is fetched for a URL until the user
//! approves it in a warning that lists every address in full. A decision lasts until the app
//! quits, so a reload does not ask again. Plain `http` is not fetched at all.
//!
//! Fetched images stay in memory, keyed by URL. The renderer only looks an image up: a document
//! with missing images is rendered again when one arrives.

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc.zig");
const cocoa = @import("cocoa.zig");
const document = @import("document.zig");
const Id = objc.Id;
const Selector = objc.Selector;

/// URLs that one warning lists. More remote images in one document are not loaded.
pub const sources_max = 64;
/// URLs with a decision. Past this, further remote images are not loaded.
const states_max = 512;
const image_size_max = 16 * 1024 * 1024;
const request_timeout_seconds = 30.0;
const resource_timeout_seconds = 120.0;
/// Images often arrive close together: one render shows all that came in this time.
const arrival_delay_seconds = 0.1;

/// What is known about a URL, besides a loaded image. Stored as NSNumber.
const State = enum(isize) { declined, fetching, failed };

var delegate: Id = undefined;
/// NSMutableDictionary from the URL (NSString) to its NSImage, or to a `State`.
var states: Id = undefined;
/// NSMutableDictionary from a task identifier to the NSMutableData received so far.
var buffers: Id = undefined;
var session: ?Id = null;

pub fn init() void {
    const class = objc.class_define("MiniMdViewRemote", "NSObject", &.{
        .{ .name = "remoteAsk:", .types = "v@:@", .implementation = &ask },
        .{ .name = "remoteArrived:", .types = "v@:@", .implementation = &arrived },
        .{
            .name = "URLSession:dataTask:didReceiveData:",
            .types = "v@:@@@",
            .implementation = &task_received,
        },
        .{
            .name = "URLSession:task:didCompleteWithError:",
            .types = "v@:@@@",
            .implementation = &task_completed,
        },
    }, false);
    delegate = objc.send(Id, objc.send(Id, class, "alloc", .{}), "init", .{});
    states = objc.send(Id, objc.alloc("NSMutableDictionary"), "init", .{});
    buffers = objc.send(Id, objc.alloc("NSMutableDictionary"), "init", .{});
}

/// Whether an image source is one that this module can fetch.
pub fn is_remote(source: []const u8) bool {
    const scheme = "https://";
    return source.len > scheme.len and std.ascii.startsWithIgnoreCase(source, scheme);
}

/// The fetched image of a URL, or null when there is none (yet).
pub fn image(source: Id) ?Id {
    const found = objc.send(?Id, states, "objectForKey:", .{source}) orelse return null;
    if (!objc.send(bool, found, "isKindOfClass:", .{objc.class("NSImage")})) return null;
    return found;
}

/// Forgets the URLs that the user declined and the ones that failed, so that the next request
/// asks about them again.
pub fn retry() void {
    const image_class = objc.class("NSImage");
    const keys = objc.send(Id, states, "allKeys", .{});
    for (0..objc.send(usize, keys, "count", .{})) |index| {
        const key = objc.send(Id, keys, "objectAtIndex:", .{index});
        const found = objc.send(Id, states, "objectForKey:", .{key});
        if (objc.send(bool, found, "isKindOfClass:", .{image_class})) continue;
        const value = objc.send(isize, found, "integerValue", .{});
        const state: State = @fromBackingInt(@intCast(value));
        if (state != .fetching) objc.send(void, states, "removeObjectForKey:", .{key});
    }
}

/// Asks the user about the missing remote images of a document (an NSArray of URL strings),
/// and fetches the ones that are approved. `name` is the NSString that names the document in
/// the warning. The warning is modal and a render can run inside a callback, so the question
/// comes after the current event.
pub fn request(sources: Id, name: Id) void {
    if (objc.send(usize, undecided(sources), "count", .{}) == 0) return;
    objc.send(void, delegate, "performSelector:withObject:afterDelay:", .{
        objc.selector("remoteAsk:"),
        cocoa.array(&.{ name, sources }),
        @as(f64, 0),
    });
}

/// The sources that have no decision, each once, up to the limits.
fn undecided(sources: Id) Id {
    const result = objc.new("NSMutableArray");
    const state_count = objc.send(usize, states, "count", .{});
    assert(state_count <= states_max);
    const room = @min(sources_max, states_max - state_count);
    for (0..objc.send(usize, sources, "count", .{})) |index| {
        if (objc.send(usize, result, "count", .{}) == room) break;
        const source = objc.send(Id, sources, "objectAtIndex:", .{index});
        if (objc.send(?Id, states, "objectForKey:", .{source}) != null) continue;
        if (objc.send(bool, result, "containsObject:", .{source})) continue;
        objc.send(void, result, "addObject:", .{source});
    }
    return result;
}

fn state_set(source: Id, state: State) void {
    objc.send(void, states, "setObject:forKey:", .{ cocoa.number(@backingInt(state)), source });
    assert(objc.send(usize, states, "count", .{}) <= states_max);
}

fn ask(_: Id, _: Selector, arguments: Id) callconv(.c) void {
    const name = objc.send(Id, arguments, "objectAtIndex:", .{@as(usize, 0)});
    // An earlier warning can have decided these sources in the meantime.
    const sources = undecided(objc.send(Id, arguments, "objectAtIndex:", .{@as(usize, 1)}));
    const count = objc.send(usize, sources, "count", .{});
    if (count == 0) return;
    const approved = warning_run(name, sources);
    for (0..count) |index| {
        const source = objc.send(Id, sources, "objectAtIndex:", .{index});
        if (approved) fetch(source) else state_set(source, .declined);
    }
}

/// Shows the warning with the list of addresses. Returns whether the user approved them.
fn warning_run(name: Id, sources: Id) bool {
    const count = objc.send(usize, sources, "count", .{});
    assert(count > 0);
    assert(count <= sources_max);
    var buffer: [512]u8 = undefined;
    const name_bytes = cocoa.string_bytes(name);
    var name_size = @min(name_bytes.len, 256);
    while (name_size < name_bytes.len and name_bytes[name_size] & 0xC0 == 0x80) name_size -= 1;
    const message = std.fmt.bufPrint(
        &buffer,
        "“{s}” refers to {d} {s} on the network.",
        .{ name_bytes[0..name_size], count, if (count == 1) "image" else "images" },
    ) catch unreachable;

    const alert = objc.new("NSAlert");
    objc.send(void, alert, "setMessageText:", .{cocoa.string(message)});
    objc.send(void, alert, "setInformativeText:", .{cocoa.string(
        "Loading an image tells its server that you opened this document. " ++
            "Nothing is loaded unless you approve these addresses.",
    )});
    objc.send(void, alert, "setAccessoryView:", .{sources_view(sources)});
    _ = objc.send(Id, alert, "addButtonWithTitle:", .{cocoa.string("Load Images")});
    const decline = objc.send(Id, alert, "addButtonWithTitle:", .{cocoa.string("Don’t Load")});
    objc.send(void, decline, "setKeyEquivalent:", .{cocoa.string("\x1b")});
    const response_first_button: isize = 1000;
    return objc.send(isize, alert, "runModal", .{}) == response_first_button;
}

/// A scrolling list of the addresses, one per line. Long addresses wrap, so that each one can
/// be read in full.
fn sources_view(sources: Id) Id {
    const width = 460;
    const line_height = 17;
    const lines_max = 12;
    const count = objc.send(usize, sources, "count", .{});
    // Room for two lines per address, because most addresses wrap once.
    const lines: f64 = @floatFromInt(@min(count * 2, lines_max));
    const height = lines * line_height + 8;
    const frame = cocoa.Rect.init(0, 0, width, height);
    const text_view = objc.autorelease(
        objc.send(Id, objc.alloc("NSTextView"), "initWithFrame:", .{frame}),
    );
    const autoresizing_width: usize = 2;
    objc.send(void, text_view, "setEditable:", .{false});
    objc.send(void, text_view, "setAutoresizingMask:", .{autoresizing_width});
    objc.send(void, text_view, "setFont:", .{objc.send(
        Id,
        objc.class("NSFont"),
        "monospacedSystemFontOfSize:weight:",
        .{ @as(f64, 11), @as(f64, 0) },
    )});
    objc.send(void, text_view, "setTextContainerInset:", .{cocoa.Size{ .width = 2, .height = 4 }});
    objc.send(void, text_view, "setString:", .{
        objc.send(Id, sources, "componentsJoinedByString:", .{cocoa.string("\n")}),
    });

    const scroll_view = objc.autorelease(
        objc.send(Id, objc.alloc("NSScrollView"), "initWithFrame:", .{frame}),
    );
    const border_bezel: usize = 2;
    objc.send(void, scroll_view, "setBorderType:", .{border_bezel});
    objc.send(void, scroll_view, "setHasVerticalScroller:", .{true});
    objc.send(void, scroll_view, "setAutohidesScrollers:", .{true});
    objc.send(void, scroll_view, "setDocumentView:", .{text_view});
    return scroll_view;
}

fn fetch(source: Id) void {
    const url = objc.send(?Id, objc.class("NSURL"), "URLWithString:", .{source}) orelse {
        return state_set(source, .failed);
    };
    if (session == null) session = session_create();
    const task = objc.send(Id, session.?, "dataTaskWithURL:", .{url});
    objc.send(void, task, "setTaskDescription:", .{source});
    objc.send(void, buffers, "setObject:forKey:", .{ objc.new("NSMutableData"), task_key(task) });
    state_set(source, .fetching);
    objc.send(void, task, "resume", .{});
}

/// The session keeps nothing on disk: no cache, no cookies. Its delegate runs on the main
/// thread.
fn session_create() Id {
    const configuration = objc.send(
        Id,
        objc.class("NSURLSessionConfiguration"),
        "ephemeralSessionConfiguration",
        .{},
    );
    objc.send(void, configuration, "setTimeoutIntervalForRequest:", .{
        @as(f64, request_timeout_seconds),
    });
    objc.send(void, configuration, "setTimeoutIntervalForResource:", .{
        @as(f64, resource_timeout_seconds),
    });
    const queue = objc.send(Id, objc.class("NSOperationQueue"), "mainQueue", .{});
    return objc.retain(objc.send(
        Id,
        objc.class("NSURLSession"),
        "sessionWithConfiguration:delegate:delegateQueue:",
        .{ configuration, delegate, queue },
    ));
}

fn task_key(task: Id) Id {
    const identifier = objc.send(usize, task, "taskIdentifier", .{});
    return objc.send(Id, objc.class("NSNumber"), "numberWithUnsignedInteger:", .{identifier});
}

fn task_received(_: Id, _: Selector, _: Id, task: Id, data: Id) callconv(.c) void {
    const buffer = objc.send(?Id, buffers, "objectForKey:", .{task_key(task)}) orelse return;
    objc.send(void, buffer, "appendData:", .{data});
    // A canceled task completes with an error, which marks the image as failed.
    if (objc.send(usize, buffer, "length", .{}) > image_size_max) {
        objc.send(void, task, "cancel", .{});
    }
}

fn task_completed(_: Id, _: Selector, _: Id, task: Id, failure: ?Id) callconv(.c) void {
    const key = task_key(task);
    const source = objc.send(?Id, task, "taskDescription", .{}) orelse return;
    const buffer = objc.send(?Id, buffers, "objectForKey:", .{key}) orelse return;
    const decoded = if (failure == null) image_decode(buffer) else null;
    if (decoded) |loaded| {
        objc.send(void, states, "setObject:forKey:", .{ loaded, source });
    } else {
        state_set(source, .failed);
    }
    objc.send(void, buffers, "removeObjectForKey:", .{key});

    const selector = objc.selector("remoteArrived:");
    objc.send(
        void,
        objc.class("NSObject"),
        "cancelPreviousPerformRequestsWithTarget:selector:object:",
        .{ delegate, selector, @as(?Id, null) },
    );
    objc.send(void, delegate, "performSelector:withObject:afterDelay:", .{
        selector,
        @as(?Id, null),
        @as(f64, arrival_delay_seconds),
    });
}

fn image_decode(data: Id) ?Id {
    const allocated = objc.alloc("NSImage");
    const loaded = objc.send(?Id, allocated, "initWithData:", .{data}) orelse return null;
    const decoded = objc.autorelease(loaded);
    const size = objc.send(cocoa.Size, decoded, "size", .{});
    if (!(size.width >= 1 and size.height >= 1)) return null;
    return decoded;
}

fn arrived(_: Id, _: Selector, _: ?Id) callconv(.c) void {
    document.remote_arrived();
}
