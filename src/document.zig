//! Documents: a fixed pool of open files, each with its own window.
//!
//! A document window is a split view. The sidebar lists the headings, and the content pane is
//! one read-only text view. The window uses the standard toolbar and sidebar, which is all that
//! the system needs to give it the current macOS design, such as Liquid Glass.
//!
//! All memory is static. The pool bounds how many documents can be open, and the parser and
//! diagram workspaces are shared, because documents are loaded one at a time on the main thread.

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc.zig");
const cocoa = @import("cocoa.zig");
const markdown = @import("markdown.zig");
const render = @import("render.zig");
const Id = objc.Id;

pub const documents_max = 8;
const path_size_max = 1024;
const scratch_size = 8 * 1024 * 1024;
const zoom_min = 0.6;
const zoom_max = 3.0;
const zoom_step = 1.1;
const inset_min = 28;
/// Space between the top of the visible area and a heading that the outline scrolled to.
const heading_margin = 16;

pub const Document = struct {
    open: bool,
    path_buffer: [path_size_max]u8,
    path_length: u32,
    window: Id,
    scroll_view: Id,
    text_view: Id,
    /// Owns the text system: the layout manager, the container, and through them the text.
    text_storage: Id,
    outline_view: Id,
    /// Modification time of the file when it was last loaded, in seconds.
    modified: f64,
    /// Smallest heading level in the document, which the outline shows without indentation.
    heading_level_min: u8,
    word_count: u32,
    /// The bytes of the last successful load. A zoom step renders them again.
    source_buffer: [markdown.source_size_max]u8,
    source_length: u32,
    /// Watches the directory of the file. Null when no stream could be started.
    stream: ?cocoa.EventStream,
    /// The subtitle says that the last reload failed, in place of the word count.
    notice: bool,
    /// The outline row that a click selected. It stays selected while the scroll position that
    /// the click gave stays, even when the heading cannot reach the top of the visible area.
    heading_clicked: ?u32,
    heading_clicked_scroll: f64,
    /// The outline selection changes because of scrolling, not because of the user.
    outline_selecting: bool,
    content: render.Content,

    pub fn path(document: *const Document) []const u8 {
        assert(document.open);
        return document.path_buffer[0..document.path_length];
    }
};

pub const OpenError = error{
    /// Every slot of the document pool is in use.
    TooManyDocuments,
    PathTooLong,
} || LoadError;

pub const LoadError = error{
    Unreadable,
    TooLarge,
    /// The file is not valid UTF-8.
    NotText,
};

var documents: [documents_max]Document = undefined;
var parse_storage: markdown.Storage = undefined;
var scratch: [scratch_size]u8 align(16) = undefined;
/// The zoom of every window. It is saved in the user defaults.
var zoom_level: f64 = 1;
const zoom_key = "Zoom";

pub fn init() void {
    for (&documents) |*document| document.open = false;
    const saved = objc.send(f64, defaults(), "doubleForKey:", .{cocoa.string(zoom_key)});
    if (saved >= zoom_min and saved <= zoom_max) zoom_level = saved;
}

fn defaults() Id {
    return objc.send(Id, objc.class("NSUserDefaults"), "standardUserDefaults", .{});
}

pub fn open_count() u32 {
    var count: u32 = 0;
    for (&documents) |*document| count += @intFromBool(document.open);
    return count;
}

const Field = enum { window, scroll_view, text_view, outline_view };

/// Finds the open document that owns the given AppKit object.
pub fn find(comptime field: Field, object: ?Id) ?*Document {
    const wanted = object orelse return null;
    for (&documents) |*document| {
        if (document.open and @field(document, @tagName(field)) == wanted) return document;
    }
    return null;
}

/// The document of the window that has the user's focus.
pub fn current() ?*Document {
    const app = objc.send(Id, objc.class("NSApplication"), "sharedApplication", .{});
    const window = objc.send(?Id, app, "keyWindow", .{}) orelse
        objc.send(?Id, app, "mainWindow", .{});
    return find(.window, window);
}

/// Opens the file in a new window, or brings its window to the front when it is already open.
pub fn open(file_path: []const u8, controller: Id) OpenError!void {
    assert(file_path.len > 0);
    if (file_path.len > path_size_max) return error.PathTooLong;
    for (&documents) |*document| {
        if (document.open and std.mem.eql(u8, document.path(), file_path)) {
            objc.send(void, document.window, "makeKeyAndOrderFront:", .{@as(?Id, null)});
            return;
        }
    }
    const document = for (&documents) |*candidate| {
        if (!candidate.open) break candidate;
    } else return error.TooManyDocuments;

    @memcpy(document.path_buffer[0..file_path.len], file_path);
    document.path_length = @intCast(file_path.len);
    document.content.reset();
    document.stream = null;
    document.notice = false;
    document.outline_selecting = false;
    document.heading_clicked = null;
    window_create(document, controller);
    document.open = true;
    document.modified = file_read(document, cocoa.string(file_path)) catch |err| {
        objc.send(void, document.window, "close", .{});
        assert(!document.open);
        return err;
    };
    show(document, null);
    watch_start(document);
    inset_update(document);
    objc.send(void, document.window, "makeKeyAndOrderFront:", .{@as(?Id, null)});
}

/// Releases the document's objects. The controller calls this when the window closes.
pub fn close(document: *Document) void {
    assert(document.open);
    document.open = false;
    watch_stop(document);
    const center = objc.send(Id, objc.class("NSNotificationCenter"), "defaultCenter", .{});
    const controller = objc.send(?Id, document.window, "delegate", .{});
    if (controller) |observer| {
        objc.send(void, center, "removeObserver:name:object:", .{
            observer,
            cocoa.NSViewFrameDidChangeNotification,
            document.scroll_view,
        });
        objc.send(void, center, "removeObserver:name:object:", .{
            observer,
            cocoa.NSViewBoundsDidChangeNotification,
            objc.send(Id, document.scroll_view, "contentView", .{}),
        });
    }
    objc.send(void, document.window, "setDelegate:", .{@as(?Id, null)});
    objc.send(void, document.outline_view, "setDelegate:", .{@as(?Id, null)});
    objc.send(void, document.outline_view, "setDataSource:", .{@as(?Id, null)});
    objc.send(void, document.text_view, "setDelegate:", .{@as(?Id, null)});
    // Diagram attachments point into the document's content. Drop them before the slot is reused.
    const empty = objc.new("NSAttributedString");
    objc.send(void, document.text_storage, "setAttributedString:", .{empty});
    objc.release(document.outline_view);
    objc.release(document.text_view);
    objc.release(document.scroll_view);
    objc.release(document.text_storage);
    _ = objc.autorelease(document.window);
}

fn file_modified(file_path: Id) ?f64 {
    const manager = objc.send(Id, objc.class("NSFileManager"), "defaultManager", .{});
    const attributes = objc.send(
        ?Id,
        manager,
        "attributesOfItemAtPath:error:",
        .{ file_path, @as(?*?Id, null) },
    ) orelse return null;
    const date = objc.send(?Id, attributes, "fileModificationDate", .{}) orelse return null;
    return objc.send(f64, date, "timeIntervalSinceReferenceDate", .{});
}

/// Reloads the document when its file changed on disk. When the new file cannot be shown, the
/// old content stays and the subtitle gives the reason. A notice is checked again on every
/// change in the directory, so that it goes away once an editor's save completes.
fn refresh(document: *Document) void {
    assert(document.open);
    const modified = file_modified(cocoa.string(document.path()));
    if (modified == document.modified and !document.notice) return;
    reload(document) catch |err| notice_show(document, err);
}

fn notice_show(document: *Document, err: LoadError) void {
    assert(document.open);
    const reason = switch (err) {
        error.Unreadable => "the file does not exist or cannot be read",
        error.TooLarge => "the file is larger than 4 MB",
        error.NotText => "the file is not UTF-8 text",
    };
    var buffer: [128]u8 = undefined;
    const subtitle = std.fmt.bufPrint(&buffer, "Not reloaded: {s}", .{reason}) catch {
        unreachable;
    };
    objc.send(void, document.window, "setSubtitle:", .{cocoa.string(subtitle)});
    document.notice = true;
}

/// Watches the directory of the file rather than the file itself: editors often save by
/// writing a new file and renaming it over the old one, which a watch on the file would lose.
fn watch_start(document: *Document) void {
    assert(document.open);
    watch_stop(document);
    const file_path = cocoa.string(document.path());
    const resolved = objc.send(Id, file_path, "stringByResolvingSymlinksInPath", .{});
    const directory = objc.send(Id, resolved, "stringByDeletingLastPathComponent", .{});
    const latency_seconds = 0.15;
    const stream = cocoa.FSEventStreamCreate(
        null,
        &watch_changed,
        &.{ .info = document },
        cocoa.array(&.{directory}),
        cocoa.event_id_since_now,
        latency_seconds,
        cocoa.event_stream_flag_file_events,
    ) orelse return;
    cocoa.FSEventStreamSetDispatchQueue(stream, &cocoa._dispatch_main_q);
    if (!cocoa.FSEventStreamStart(stream)) {
        cocoa.FSEventStreamInvalidate(stream);
        cocoa.FSEventStreamRelease(stream);
        return;
    }
    document.stream = stream;
}

fn watch_stop(document: *Document) void {
    const stream = document.stream orelse return;
    cocoa.FSEventStreamStop(stream);
    cocoa.FSEventStreamInvalidate(stream);
    cocoa.FSEventStreamRelease(stream);
    document.stream = null;
}

fn watch_changed(
    stream: cocoa.EventStream,
    info: ?*anyopaque,
    _: usize,
    _: *anyopaque,
    _: [*]const u32,
    _: [*]const u64,
) callconv(.c) void {
    const document: *Document = @ptrCast(@alignCast(info.?));
    // A callback can be queued just before its stream stops.
    if (!document.open or document.stream != stream) return;
    refresh(document);
}

/// Reads the file again and shows it at the same scroll position. On error, the view is
/// unchanged.
pub fn reload(document: *Document) LoadError!void {
    assert(document.open);
    document.modified = try file_read(document, cocoa.string(document.path()));
    show(document, scroll_get(document));
}

/// Renders the kept bytes again, for example after a zoom step, and keeps the scroll position.
pub fn rerender(document: *Document) void {
    assert(document.open);
    show(document, scroll_get(document));
}

pub const ZoomChange = enum { in, out, reset };

/// Changes the zoom of every window and saves it.
pub fn zoom(change: ZoomChange) void {
    const zoom_new = switch (change) {
        .in => @min(zoom_max, zoom_level * zoom_step),
        .out => @max(zoom_min, zoom_level / zoom_step),
        .reset => 1,
    };
    if (zoom_new == zoom_level) return;
    zoom_level = zoom_new;
    objc.send(void, defaults(), "setDouble:forKey:", .{ zoom_level, cocoa.string(zoom_key) });
    for (&documents) |*document| {
        if (!document.open) continue;
        rerender(document);
        inset_update(document);
    }
}

/// Reads the file into the kept bytes of the document and returns its modification time. On
/// error, the kept bytes are unchanged.
fn file_read(document: *Document, file_path: Id) LoadError!f64 {
    assert(document.open);
    const modified = file_modified(file_path) orelse return error.Unreadable;
    const data = objc.send(
        ?Id,
        objc.class("NSData"),
        "dataWithContentsOfFile:",
        .{file_path},
    ) orelse {
        return error.Unreadable;
    };
    const size = objc.send(usize, data, "length", .{});
    if (size > markdown.source_size_max) return error.TooLarge;
    var source: []const u8 = "";
    if (size > 0) source = objc.send([*]const u8, data, "bytes", .{})[0..size];
    if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) source = source[3..];
    if (!std.unicode.utf8ValidateSlice(source)) return error.NotText;
    @memcpy(document.source_buffer[0..source.len], source);
    document.source_length = @intCast(source.len);
    return modified;
}

/// Parses and renders the kept bytes and shows the result. Then scrolls to `scroll`, the
/// vertical origin of the visible area, unless it is null.
fn show(document: *Document, scroll: ?f64) void {
    assert(document.open);
    assert(document.source_length <= markdown.source_size_max);
    const file_path = cocoa.string(document.path());
    // The old attributed string points into `content`, so it goes away before the rebuild.
    const empty = objc.new("NSAttributedString");
    objc.send(void, document.text_storage, "setAttributedString:", .{empty});
    const parsed = markdown.parse(
        &parse_storage,
        document.source_buffer[0..document.source_length],
    );
    const attributed = render.build(parsed.events, &document.content, .{
        .zoom = zoom_level,
        .directory = objc.send(Id, file_path, "stringByDeletingLastPathComponent", .{}),
        .scratch = &scratch,
        .truncated = parsed.truncated,
    });
    objc.send(void, document.text_storage, "setAttributedString:", .{attributed});
    document.word_count = parsed.word_count;

    document.heading_level_min = 6;
    for (document.content.headings_slice()) |heading| {
        document.heading_level_min = @min(document.heading_level_min, heading.level);
    }
    objc.send(void, document.outline_view, "reloadData", .{});
    title_update(document);
    if (scroll) |y| scroll_set(document, y);
    document.heading_clicked = null;
    outline_follow(document);
}

fn scroll_get(document: *const Document) f64 {
    const clip_view = objc.send(Id, document.scroll_view, "contentView", .{});
    return objc.send(cocoa.Rect, clip_view, "bounds", .{}).origin.y;
}

fn scroll_set(document: *Document, y: f64) void {
    const layout_manager = objc.send(Id, document.text_view, "layoutManager", .{});
    const container = objc.send(Id, document.text_view, "textContainer", .{});
    objc.send(void, layout_manager, "ensureLayoutForTextContainer:", .{container});
    objc.send(void, document.text_view, "scrollPoint:", .{cocoa.Point{ .x = 0, .y = y }});
}

fn title_update(document: *Document) void {
    const window = document.window;
    const file_path = cocoa.string(document.path());
    objc.send(void, window, "setTitle:", .{objc.send(Id, file_path, "lastPathComponent", .{})});
    const url = objc.send(Id, objc.class("NSURL"), "fileURLWithPath:", .{file_path});
    objc.send(void, window, "setRepresentedURL:", .{url});
    const words_per_minute = 230;
    const word_count = document.word_count;
    const minutes = @max(1, (word_count + words_per_minute / 2) / words_per_minute);
    var buffer: [64]u8 = undefined;
    const subtitle = std.fmt.bufPrint(
        &buffer,
        "{d} words · {d} min read",
        .{ word_count, minutes },
    ) catch {
        unreachable;
    };
    objc.send(void, window, "setSubtitle:", .{cocoa.string(subtitle)});
    document.notice = false;
}

/// Centers the text column in the pane. The pane can be wider than a readable line.
pub fn inset_update(document: *Document) void {
    assert(document.open);
    const width = objc.send(cocoa.Size, document.scroll_view, "contentSize", .{}).width;
    const column = render.column_width * zoom_level;
    const inset: cocoa.Size = .{
        .width = @floor(@max(inset_min, (width - column) / 2)),
        .height = 24,
    };
    const inset_old = objc.send(cocoa.Size, document.text_view, "textContainerInset", .{});
    if (inset_old.width == inset.width and inset_old.height == inset.height) return;
    objc.send(void, document.text_view, "setTextContainerInset:", .{inset});
}

/// Scrolls the heading to the top of the visible area, just below the toolbar.
pub fn heading_show(document: *Document, heading_index: usize) void {
    assert(document.open);
    assert(heading_index < document.content.heading_count);
    const heading = document.content.headings[heading_index];
    const layout_manager = objc.send(Id, document.text_view, "layoutManager", .{});
    const container = objc.send(Id, document.text_view, "textContainer", .{});
    const glyphs = objc.send(
        cocoa.Range,
        layout_manager,
        "glyphRangeForCharacterRange:actualCharacterRange:",
        .{ cocoa.Range{ .location = heading.location, .length = 1 }, @as(?*cocoa.Range, null) },
    );
    const rect = objc.send(
        cocoa.Rect,
        layout_manager,
        "boundingRectForGlyphRange:inTextContainer:",
        .{ glyphs, container },
    );
    const origin = objc.send(cocoa.Point, document.text_view, "textContainerOrigin", .{});
    const insets = objc.send(cocoa.EdgeInsets, document.scroll_view, "contentInsets", .{});
    const target: cocoa.Point = .{
        .x = 0,
        .y = rect.origin.y + origin.y - insets.top - heading_margin,
    };
    objc.send(void, document.text_view, "scrollPoint:", .{target});
}

/// Scrolls to the heading of the outline row that the user selected, and keeps the row selected.
pub fn heading_click(document: *Document, row: u32) void {
    assert(document.open);
    assert(row < document.content.heading_count);
    heading_show(document, row);
    document.heading_clicked = row;
    document.heading_clicked_scroll = scroll_get(document);
    outline_select(document, row);
}

/// Selects the outline row of the heading that the top of the visible text belongs to. The
/// work per call is small, because it runs for every scroll event.
pub fn outline_follow(document: *Document) void {
    assert(document.open);
    if (document.heading_clicked) |row| {
        if (scroll_get(document) == document.heading_clicked_scroll) {
            return outline_select(document, row);
        }
        document.heading_clicked = null;
    }
    outline_select(document, heading_top(document));
}

/// The last heading at or above the top of the visible text, or null when there is none.
fn heading_top(document: *Document) ?u32 {
    const headings = document.content.headings_slice();
    if (headings.len == 0) return null;
    const layout_manager = objc.send(Id, document.text_view, "layoutManager", .{});
    const container = objc.send(Id, document.text_view, "textContainer", .{});
    const origin = objc.send(cocoa.Point, document.text_view, "textContainerOrigin", .{});
    const insets = objc.send(cocoa.EdgeInsets, document.scroll_view, "contentInsets", .{});
    // One point below where `heading_show` puts a heading, so that the heading counts.
    const top = scroll_get(document) + insets.top + heading_margin + 1 - origin.y;
    const glyph = objc.send(
        usize,
        layout_manager,
        "glyphIndexForPoint:inTextContainer:fractionOfDistanceThroughGlyph:",
        .{ cocoa.Point{ .x = 0, .y = @max(0, top) }, container, @as(?*f64, null) },
    );
    const location = objc.send(usize, layout_manager, "characterIndexForGlyphAtIndex:", .{glyph});
    const count = std.sort.partitionPoint(render.Heading, headings, location, heading_before);
    if (count == 0) return null;
    return @intCast(count - 1);
}

fn heading_before(location: usize, heading: render.Heading) bool {
    return heading.location <= location;
}

fn outline_select(document: *Document, row: ?u32) void {
    const table = document.outline_view;
    const wanted: isize = if (row) |index| index else -1;
    if (objc.send(isize, table, "selectedRow", .{}) == wanted) return;
    // While a render is in progress, the table still shows the old headings.
    if (wanted >= objc.send(isize, table, "numberOfRows", .{})) return;
    document.outline_selecting = true;
    defer document.outline_selecting = false;
    if (row) |index| {
        const rows = objc.send(Id, objc.class("NSIndexSet"), "indexSetWithIndex:", .{
            @as(usize, index),
        });
        objc.send(void, table, "selectRowIndexes:byExtendingSelection:", .{ rows, false });
        objc.send(void, table, "scrollRowToVisible:", .{wanted});
    } else {
        objc.send(void, table, "deselectAll:", .{@as(?Id, null)});
    }
}

/// Scrolls to the heading that a `#fragment` link names. Returns whether one matched.
pub fn anchor_show(document: *Document, fragment: []const u8) bool {
    assert(document.open);
    var slug_buffer: [256]u8 = undefined;
    var fragment_buffer: [256]u8 = undefined;
    if (fragment.len > fragment_buffer.len) return false;
    const wanted = std.ascii.lowerString(&fragment_buffer, fragment);
    for (document.content.headings_slice(), 0..) |heading, index| {
        if (std.mem.eql(u8, slug(heading.title, &slug_buffer), wanted)) {
            heading_show(document, index);
            return true;
        }
    }
    return false;
}

/// The anchor name of a heading, as GitHub derives it: lowercase, spaces become hyphens, and
/// other punctuation is dropped.
fn slug(title: []const u8, buffer: []u8) []const u8 {
    var count: usize = 0;
    for (title) |byte| {
        if (count == buffer.len) break;
        const kept: ?u8 = if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or
            byte >= 0x80)
            std.ascii.toLower(byte)
        else if (byte == ' ')
            '-'
        else
            null;
        if (kept) |value| {
            buffer[count] = value;
            count += 1;
        }
    }
    return buffer[0..count];
}

test "slug" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("getting-started", slug("Getting Started!", &buffer));
    try std.testing.expectEqualStrings("a_b-c-1", slug("A_b-c (1)", &buffer));
}

// Window construction.

fn window_create(document: *Document, controller: Id) void {
    // NSWindowStyleMask: titled, closable, miniaturizable, resizable, full size content view.
    const style_mask: usize = 1 | 2 | 4 | 8 | (1 << 15);
    const backing_buffered: usize = 2;
    const frame = cocoa.Rect.init(0, 0, 1080, 780);
    const window = objc.send(
        Id,
        objc.alloc("NSWindow"),
        "initWithContentRect:styleMask:backing:defer:",
        .{ frame, style_mask, backing_buffered, false },
    );
    objc.send(void, window, "setReleasedWhenClosed:", .{false});
    objc.send(void, window, "setDelegate:", .{controller});
    objc.send(void, window, "setTabbingIdentifier:", .{cocoa.string("MiniMdViewDocument")});
    // The window passes drags to its delegate, which opens the dropped files.
    objc.send(void, window, "registerForDraggedTypes:", .{
        cocoa.array(&.{cocoa.NSPasteboardTypeFileURL}),
    });
    document.window = window;

    const toolbar = objc.autorelease(objc.send(
        Id,
        objc.alloc("NSToolbar"),
        "initWithIdentifier:",
        .{cocoa.string("MiniMdViewDocumentToolbar")},
    ));
    const display_icon_only: usize = 2;
    const style_unified: isize = 3;
    objc.send(void, toolbar, "setDelegate:", .{controller});
    objc.send(void, toolbar, "setDisplayMode:", .{display_icon_only});
    objc.send(void, window, "setToolbar:", .{toolbar});
    objc.send(void, window, "setToolbarStyle:", .{style_unified});

    const split = objc.new("NSSplitViewController");
    const sidebar_item = objc.send(
        Id,
        objc.class("NSSplitViewItem"),
        "sidebarWithViewController:",
        .{view_controller(sidebar_create(document, controller))},
    );
    objc.send(void, sidebar_item, "setMinimumThickness:", .{@as(f64, 180)});
    objc.send(void, sidebar_item, "setMaximumThickness:", .{@as(f64, 360)});
    const content_item = objc.send(
        Id,
        objc.class("NSSplitViewItem"),
        "splitViewItemWithViewController:",
        .{view_controller(content_create(document, controller))},
    );
    objc.send(void, split, "addSplitViewItem:", .{sidebar_item});
    objc.send(void, split, "addSplitViewItem:", .{content_item});
    objc.send(void, window, "setContentViewController:", .{split});
    objc.send(void, window, "setContentSize:", .{frame.size});
    objc.send(void, window, "setContentMinSize:", .{cocoa.Size{ .width = 520, .height = 320 }});
    objc.send(void, window, "center", .{});
    _ = objc.send(bool, window, "setFrameAutosaveName:", .{cocoa.string("MiniMdViewDocumentWindow")});

    const center = objc.send(Id, objc.class("NSNotificationCenter"), "defaultCenter", .{});
    objc.send(void, center, "addObserver:selector:name:object:", .{
        controller,
        objc.selector("viewFrameChanged:"),
        cocoa.NSViewFrameDidChangeNotification,
        document.scroll_view,
    });
    const clip_view = objc.send(Id, document.scroll_view, "contentView", .{});
    objc.send(void, clip_view, "setPostsBoundsChangedNotifications:", .{true});
    objc.send(void, center, "addObserver:selector:name:object:", .{
        controller,
        objc.selector("viewBoundsChanged:"),
        cocoa.NSViewBoundsDidChangeNotification,
        clip_view,
    });
}

fn view_controller(view: Id) Id {
    const controller = objc.new("NSViewController");
    objc.send(void, controller, "setView:", .{view});
    return controller;
}

fn sidebar_create(document: *Document, controller: Id) Id {
    const table = objc.send(Id, objc.alloc("NSTableView"), "init", .{});
    const column = objc.autorelease(objc.send(
        Id,
        objc.alloc("NSTableColumn"),
        "initWithIdentifier:",
        .{cocoa.string("title")},
    ));
    const style_source_list: isize = 3;
    const focus_ring_none: usize = 1;
    objc.send(void, table, "addTableColumn:", .{column});
    objc.send(void, table, "setHeaderView:", .{@as(?Id, null)});
    objc.send(void, table, "setStyle:", .{style_source_list});
    objc.send(void, table, "setRowHeight:", .{@as(f64, 26)});
    objc.send(void, table, "setFocusRingType:", .{focus_ring_none});
    objc.send(void, table, "setDataSource:", .{controller});
    objc.send(void, table, "setDelegate:", .{controller});
    document.outline_view = table;

    const scroll_view = objc.new("NSScrollView");
    objc.send(void, scroll_view, "setDrawsBackground:", .{false});
    objc.send(void, scroll_view, "setHasVerticalScroller:", .{true});
    objc.send(void, scroll_view, "setAutohidesScrollers:", .{true});
    objc.send(void, scroll_view, "setDocumentView:", .{table});
    objc.send(void, scroll_view, "setFrame:", .{cocoa.Rect.init(0, 0, 240, 600)});
    return scroll_view;
}

fn content_create(document: *Document, controller: Id) Id {
    const frame = cocoa.Rect.init(0, 0, 840, 780);
    const dimension_max = 1.0e7;
    const text_storage = objc.send(Id, objc.alloc("NSTextStorage"), "init", .{});
    const layout_manager = objc.new("NSLayoutManager");
    objc.send(void, text_storage, "addLayoutManager:", .{layout_manager});
    const container = objc.autorelease(objc.send(
        Id,
        objc.alloc("NSTextContainer"),
        "initWithSize:",
        .{cocoa.Size{ .width = frame.size.width, .height = dimension_max }},
    ));
    objc.send(void, container, "setWidthTracksTextView:", .{true});
    objc.send(void, layout_manager, "addTextContainer:", .{container});

    const text_view = objc.send(
        Id,
        objc.alloc("NSTextView"),
        "initWithFrame:textContainer:",
        .{ frame, container },
    );
    const autoresizing_width: usize = 2;
    objc.send(void, text_view, "setEditable:", .{false});
    objc.send(void, text_view, "setSelectable:", .{true});
    objc.send(void, text_view, "setVerticallyResizable:", .{true});
    objc.send(void, text_view, "setHorizontallyResizable:", .{false});
    objc.send(void, text_view, "setAutoresizingMask:", .{autoresizing_width});
    objc.send(void, text_view, "setMaxSize:", .{
        cocoa.Size{ .width = dimension_max, .height = dimension_max },
    });
    objc.send(void, text_view, "setBackgroundColor:", .{cocoa.color("textBackgroundColor")});
    objc.send(void, text_view, "setUsesFindBar:", .{true});
    objc.send(void, text_view, "setIncrementalSearchingEnabled:", .{true});
    objc.send(void, text_view, "setDisplaysLinkToolTips:", .{true});
    objc.send(void, text_view, "setDelegate:", .{controller});
    const link_attributes = objc.new("NSMutableDictionary");
    objc.send(void, link_attributes, "setObject:forKey:", .{
        cocoa.color("controlAccentColor"),
        cocoa.NSForegroundColorAttributeName,
    });
    objc.send(void, link_attributes, "setObject:forKey:", .{
        objc.send(Id, objc.class("NSCursor"), "pointingHandCursor", .{}),
        cocoa.NSCursorAttributeName,
    });
    objc.send(void, text_view, "setLinkTextAttributes:", .{link_attributes});

    const scroll_view = objc.send(Id, objc.alloc("NSScrollView"), "initWithFrame:", .{frame});
    objc.send(void, scroll_view, "setHasVerticalScroller:", .{true});
    objc.send(void, scroll_view, "setAutohidesScrollers:", .{true});
    objc.send(void, scroll_view, "setDrawsBackground:", .{false});
    objc.send(void, scroll_view, "setDocumentView:", .{text_view});
    document.text_storage = text_storage;
    document.text_view = text_view;
    document.scroll_view = scroll_view;
    return scroll_view;
}
