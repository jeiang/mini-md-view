//! mini-md-view: a native macOS viewer for Markdown files.
//!
//! This file is the application shell: the controller object that AppKit calls back, the menu
//! bar, and the launch sequence. One controller instance serves as the delegate of the
//! application, of every window and toolbar, and of every outline and text view. It finds the
//! document that a callback is about by the view or window that sent it.

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc.zig");
const cocoa = @import("cocoa.zig");
const document = @import("document.zig");
const history = @import("history.zig");
const Id = objc.Id;
const Selector = objc.Selector;

const extensions = [_][]const u8{ "md", "markdown", "mdown", "mkd", "mdx", "txt" };

const ToolbarButton = struct {
    identifier: []const u8,
    label: []const u8,
    symbol: []const u8,
    action: [:0]const u8,
    /// The toolbar puts navigational items before the window title.
    navigational: bool = false,
};

const toolbar_back: ToolbarButton = .{
    .identifier = "MiniMdViewBack",
    .label = "Back",
    .symbol = "chevron.left",
    .action = "goBack:",
    .navigational = true,
};
const toolbar_forward: ToolbarButton = .{
    .identifier = "MiniMdViewForward",
    .label = "Forward",
    .symbol = "chevron.right",
    .action = "goForward:",
    .navigational = true,
};
const toolbar_zoom_out: ToolbarButton = .{
    .identifier = "MiniMdViewZoomOut",
    .label = "Zoom Out",
    .symbol = "textformat.size.smaller",
    .action = "zoomOut:",
};
const toolbar_zoom_in: ToolbarButton = .{
    .identifier = "MiniMdViewZoomIn",
    .label = "Zoom In",
    .symbol = "textformat.size.larger",
    .action = "zoomIn:",
};
const toolbar_buttons = [_]ToolbarButton{
    toolbar_back,
    toolbar_forward,
    toolbar_zoom_out,
    toolbar_zoom_in,
};

var controller: Id = undefined;
/// The command line or Finder named files to open, so the last session is not reopened.
var files_requested = false;
/// AppKit closes the windows when the app quits. Those closes keep the documents in the set
/// that the next launch reopens.
var terminating = false;

fn app() Id {
    return objc.send(Id, objc.class("NSApplication"), "sharedApplication", .{});
}

pub fn main() void {
    const pool = objc.Pool.push();
    defer pool.pop();
    document.init();
    controller = objc.send(Id, objc.send(Id, controller_class(), "alloc", .{}), "init", .{});
    const activation_policy_regular: isize = 0;
    _ = objc.send(bool, app(), "setActivationPolicy:", .{activation_policy_regular});
    objc.send(void, app(), "setDelegate:", .{controller});
    menu_bar_create();
    objc.send(void, app(), "run", .{});
}

fn controller_class() Id {
    const frame_changed = "viewFrameChanged:";
    const toolbar_item = "toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:";
    return objc.class_define("MiniMdViewController", "NSObject", &.{
        .{
            .name = "applicationDidFinishLaunching:",
            .types = "v@:@",
            .implementation = &did_finish_launching,
        },
        .{ .name = "application:openFiles:", .types = "v@:@@", .implementation = &open_files },
        .{
            .name = "applicationShouldHandleReopen:hasVisibleWindows:",
            .types = "B@:@B",
            .implementation = &should_handle_reopen,
        },
        .{
            .name = "applicationShouldTerminate:",
            .types = "Q@:@",
            .implementation = &should_terminate,
        },
        .{
            .name = "applicationSupportsSecureRestorableState:",
            .types = "B@:@",
            .implementation = &supports_secure_state,
        },
        .{ .name = "openDocument:", .types = "v@:@", .implementation = &action_open },
        .{ .name = "openURLs:", .types = "v@:@", .implementation = &action_open_urls },
        .{ .name = "openRecent:", .types = "v@:@", .implementation = &action_open_recent },
        .{ .name = "clearRecent:", .types = "v@:@", .implementation = &action_clear_recent },
        .{ .name = "menuNeedsUpdate:", .types = "v@:@", .implementation = &recent_menu_update },
        .{ .name = "draggingEntered:", .types = "Q@:@", .implementation = &drag_entered },
        .{ .name = "performDragOperation:", .types = "B@:@", .implementation = &drag_perform },
        .{ .name = "reloadDocument:", .types = "v@:@", .implementation = &action_reload },
        .{ .name = "zoomIn:", .types = "v@:@", .implementation = &action_zoom_in },
        .{ .name = "zoomOut:", .types = "v@:@", .implementation = &action_zoom_out },
        .{ .name = "zoomReset:", .types = "v@:@", .implementation = &action_zoom_reset },
        .{ .name = "goBack:", .types = "v@:@", .implementation = &action_go_back },
        .{ .name = "goForward:", .types = "v@:@", .implementation = &action_go_forward },
        .{ .name = "loadRemoteImages:", .types = "v@:@", .implementation = &action_remote_load },
        .{ .name = "validateMenuItem:", .types = "B@:@", .implementation = &validate_item },
        .{ .name = "validateToolbarItem:", .types = "B@:@", .implementation = &validate_item },
        .{ .name = "windowWillClose:", .types = "v@:@", .implementation = &window_will_close },
        .{
            .name = "numberOfRowsInTableView:",
            .types = "q@:@",
            .implementation = &outline_row_count,
        },
        .{
            .name = "tableView:viewForTableColumn:row:",
            .types = "@@:@@q",
            .implementation = &outline_row_view,
        },
        .{
            .name = "tableViewSelectionDidChange:",
            .types = "v@:@",
            .implementation = &outline_selection_changed,
        },
        .{
            .name = "textView:clickedOnLink:atIndex:",
            .types = "B@:@@Q",
            .implementation = &link_clicked,
        },
        .{
            .name = "toolbarDefaultItemIdentifiers:",
            .types = "@@:@",
            .implementation = &toolbar_identifiers,
        },
        .{
            .name = "toolbarAllowedItemIdentifiers:",
            .types = "@@:@",
            .implementation = &toolbar_identifiers,
        },
        .{ .name = toolbar_item, .types = "@@:@@B", .implementation = &toolbar_item_create },
        .{ .name = frame_changed, .types = "v@:@", .implementation = &view_frame_changed },
        .{ .name = "viewBoundsChanged:", .types = "v@:@", .implementation = &view_bounds_changed },
    }, false);
}

// Application delegate.

fn did_finish_launching(_: Id, _: Selector, _: ?Id) callconv(.c) void {
    arguments_open();
    if (!files_requested) document.reopen(controller);
    objc.send(void, app(), "activateIgnoringOtherApps:", .{true});
    if (document.open_count() == 0) open_panel_run();
}

/// Opens the files that were named on the command line. Arguments that start with a dash are
/// AppKit defaults overrides, which come in pairs.
fn arguments_open() void {
    const process = objc.send(Id, objc.class("NSProcessInfo"), "processInfo", .{});
    const arguments = objc.send(Id, process, "arguments", .{});
    const count = objc.send(usize, arguments, "count", .{});
    var index: usize = 1;
    while (index < count) : (index += 1) {
        const file_path = objc.send(Id, arguments, "objectAtIndex:", .{index});
        const argument = cocoa.string_bytes(file_path);
        if (argument.len == 0) continue;
        if (argument[0] == '-') {
            index += 1;
            continue;
        }
        files_requested = true;
        path_open(path_absolute(file_path));
    }
}

/// Resolves a path from the command line against the working directory. AppKit also passes such
/// paths to `application:openFiles:` as they were typed.
fn path_absolute(file_path: Id) Id {
    var absolute = file_path;
    if (!objc.send(bool, file_path, "isAbsolutePath", .{})) {
        const manager = objc.send(Id, objc.class("NSFileManager"), "defaultManager", .{});
        const directory = objc.send(Id, manager, "currentDirectoryPath", .{});
        absolute = objc.send(Id, directory, "stringByAppendingPathComponent:", .{file_path});
    }
    return objc.send(Id, absolute, "stringByStandardizingPath", .{});
}

fn open_files(_: Id, _: Selector, _: ?Id, file_names: Id) callconv(.c) void {
    const count = objc.send(usize, file_names, "count", .{});
    files_requested = true;
    for (0..count) |index| {
        path_open(path_absolute(objc.send(Id, file_names, "objectAtIndex:", .{index})));
    }
    const reply_success: usize = 0;
    objc.send(void, app(), "replyToOpenOrPrint:", .{reply_success});
}

fn should_terminate(_: Id, _: Selector, _: ?Id) callconv(.c) usize {
    terminating = true;
    const terminate_now: usize = 1;
    return terminate_now;
}

fn should_handle_reopen(_: Id, _: Selector, _: ?Id, has_visible_windows: bool) callconv(.c) bool {
    if (!has_visible_windows and document.open_count() == 0) open_panel_run();
    return true;
}

fn supports_secure_state(_: Id, _: Selector, _: ?Id) callconv(.c) bool {
    return true;
}

// Opening documents.

fn path_open(file_path: Id) void {
    const bytes = cocoa.string_bytes(file_path);
    if (bytes.len == 0) return;
    document.open(bytes, controller) catch |err| open_alert_show(file_path, err);
}

fn open_alert_show(file_path: Id, err: document.OpenError) void {
    const name = objc.send(Id, file_path, "lastPathComponent", .{});
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "“{s}” could not be opened.", .{
        cocoa.string_bytes(name)[0..@min(cocoa.string_bytes(name).len, 256)],
    }) catch unreachable;
    alert_show(message, switch (err) {
        error.TooManyDocuments => "Too many documents are open. Close a window and try again.",
        error.PathTooLong => "The path of the file is too long.",
        error.Unreadable => "The file does not exist or cannot be read.",
        error.TooLarge => "The file is larger than 4 MB.",
        error.NotText => "The file is not UTF-8 text.",
    });
}

fn alert_show(message: []const u8, information: []const u8) void {
    const alert = objc.new("NSAlert");
    objc.send(void, alert, "setMessageText:", .{cocoa.string(message)});
    objc.send(void, alert, "setInformativeText:", .{cocoa.string(information)});
    _ = objc.send(isize, alert, "runModal", .{});
}

fn open_panel_run() void {
    const panel = objc.send(Id, objc.class("NSOpenPanel"), "openPanel", .{});
    const types = objc.new("NSMutableArray");
    for (extensions) |extension| {
        const content_type = objc.send(
            ?Id,
            objc.class("UTType"),
            "typeWithFilenameExtension:",
            .{cocoa.string(extension)},
        ) orelse continue;
        objc.send(void, types, "addObject:", .{content_type});
    }
    objc.send(void, panel, "setAllowedContentTypes:", .{types});
    objc.send(void, panel, "setAllowsMultipleSelection:", .{true});
    const response_ok: isize = 1;
    if (objc.send(isize, panel, "runModal", .{}) != response_ok) return;
    urls_open(objc.send(Id, panel, "URLs", .{}));
}

fn urls_open(urls: Id) void {
    const count = objc.send(usize, urls, "count", .{});
    for (0..count) |index| {
        const url = objc.send(Id, urls, "objectAtIndex:", .{index});
        if (objc.send(?Id, url, "path", .{})) |file_path| path_open(file_path);
    }
}

// Dropping files on a window.

/// The file URLs of a drag, or null when it carries none.
fn drag_urls(info: Id) ?Id {
    const pasteboard = objc.send(Id, info, "draggingPasteboard", .{});
    const options = objc.send(Id, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{
        objc.send(Id, objc.class("NSNumber"), "numberWithBool:", .{true}),
        cocoa.NSPasteboardURLReadingFileURLsOnlyKey,
    });
    const urls = objc.send(?Id, pasteboard, "readObjectsForClasses:options:", .{
        cocoa.array(&.{objc.class("NSURL")}),
        options,
    }) orelse return null;
    if (objc.send(usize, urls, "count", .{}) == 0) return null;
    return urls;
}

fn drag_entered(_: Id, _: Selector, info: Id) callconv(.c) usize {
    const drag_operation_none: usize = 0;
    const drag_operation_copy: usize = 1;
    return if (drag_urls(info) == null) drag_operation_none else drag_operation_copy;
}

fn drag_perform(_: Id, _: Selector, info: Id) callconv(.c) bool {
    const urls = drag_urls(info) orelse return false;
    // The files open after the drag ends: an alert during the drag would stall Finder.
    objc.send(void, controller, "performSelector:withObject:afterDelay:", .{
        objc.selector("openURLs:"),
        urls,
        @as(f64, 0),
    });
    return true;
}

fn action_open_urls(_: Id, _: Selector, urls: Id) callconv(.c) void {
    urls_open(urls);
}

// Menu and toolbar actions.

fn action_open(_: Id, _: Selector, _: ?Id) callconv(.c) void {
    open_panel_run();
}

fn action_reload(_: Id, _: Selector, _: ?Id) callconv(.c) void {
    const current = document.current() orelse return;
    document.reload(current) catch {
        alert_show(
            "The document could not be reloaded.",
            "The file is missing or is no longer text.",
        );
    };
}

fn action_zoom_in(_: Id, _: Selector, _: ?Id) callconv(.c) void {
    document.zoom(.in);
}

fn action_zoom_out(_: Id, _: Selector, _: ?Id) callconv(.c) void {
    document.zoom(.out);
}

fn action_zoom_reset(_: Id, _: Selector, _: ?Id) callconv(.c) void {
    document.zoom(.reset);
}

fn action_go_back(_: Id, _: Selector, sender: ?Id) callconv(.c) void {
    history_go(sender, .back);
}

fn action_go_forward(_: Id, _: Selector, sender: ?Id) callconv(.c) void {
    history_go(sender, .forward);
}

fn action_remote_load(_: Id, _: Selector, sender: ?Id) callconv(.c) void {
    if (sender_document(sender)) |shown| document.remote_retry(shown);
}

fn history_go(sender: ?Id, direction: history.Direction) void {
    const shown = sender_document(sender) orelse return;
    const file_path = document.history_peek(shown, direction) orelse return;
    document.history_go(shown, direction) catch |err| {
        open_alert_show(cocoa.string(file_path), err);
    };
}

/// A toolbar button acts on the window of its toolbar, which need not be the key window. A menu
/// item acts on the key window.
fn sender_document(sender: ?Id) ?*document.Document {
    const item = sender orelse return document.current();
    const toolbar_item = objc.send(bool, item, "isKindOfClass:", .{objc.class("NSToolbarItem")});
    if (!toolbar_item) return document.current();
    return document.find_toolbar(objc.send(?Id, item, "toolbar", .{}));
}

fn action_open_recent(_: Id, _: Selector, item: Id) callconv(.c) void {
    const url = objc.send(?Id, item, "representedObject", .{}) orelse return;
    if (objc.send(?Id, url, "path", .{})) |file_path| path_open(file_path);
}

fn action_clear_recent(_: Id, _: Selector, _: ?Id) callconv(.c) void {
    objc.send(void, document_controller(), "clearRecentDocuments:", .{@as(?Id, null)});
}

fn document_controller() Id {
    return objc.send(Id, objc.class("NSDocumentController"), "sharedDocumentController", .{});
}

fn recent_count() usize {
    const urls = objc.send(Id, document_controller(), "recentDocumentURLs", .{});
    return objc.send(usize, urls, "count", .{});
}

/// Document actions need a document, and Back and Forward need a history entry to go to.
/// Opening a file is always possible.
fn validate_item(_: Id, _: Selector, item: Id) callconv(.c) bool {
    const action = objc.send(?Selector, item, "action", .{});
    if (action == objc.selector("openDocument:")) return true;
    if (action == objc.selector("openRecent:")) return true;
    if (action == objc.selector("clearRecent:")) return recent_count() > 0;
    const shown = sender_document(item) orelse return false;
    if (action == objc.selector("goBack:")) return document.history_peek(shown, .back) != null;
    if (action == objc.selector("goForward:")) {
        return document.history_peek(shown, .forward) != null;
    }
    if (action == objc.selector("loadRemoteImages:")) return shown.remote_missing;
    return true;
}

/// Fills the Open Recent menu when it opens, newest document first.
fn recent_menu_update(_: Id, _: Selector, menu: Id) callconv(.c) void {
    objc.send(void, menu, "removeAllItems", .{});
    const urls = objc.send(Id, document_controller(), "recentDocumentURLs", .{});
    const count = objc.send(usize, urls, "count", .{});
    for (0..count) |index| {
        const url = objc.send(Id, urls, "objectAtIndex:", .{index});
        const title = objc.send(?Id, url, "lastPathComponent", .{}) orelse continue;
        const item = objc.send(Id, menu, "addItemWithTitle:action:keyEquivalent:", .{
            title,
            objc.selector("openRecent:"),
            cocoa.string(""),
        });
        objc.send(void, item, "setTarget:", .{controller});
        objc.send(void, item, "setRepresentedObject:", .{url});
    }
    if (count > 0) {
        objc.send(void, menu, "addItem:", .{
            objc.send(Id, objc.class("NSMenuItem"), "separatorItem", .{}),
        });
    }
    const clear = objc.send(Id, menu, "addItemWithTitle:action:keyEquivalent:", .{
        cocoa.string("Clear Menu"),
        objc.selector("clearRecent:"),
        cocoa.string(""),
    });
    objc.send(void, clear, "setTarget:", .{controller});
}

// Window, outline and text view delegates.

fn window_will_close(_: Id, _: Selector, notification: Id) callconv(.c) void {
    const window = objc.send(?Id, notification, "object", .{});
    const closing = document.find(.window, window) orelse return;
    document.close(closing);
    if (!terminating) document.paths_store();
}

fn view_frame_changed(_: Id, _: Selector, notification: Id) callconv(.c) void {
    const view = objc.send(?Id, notification, "object", .{});
    if (document.find(.scroll_view, view)) |resized| document.inset_update(resized);
}

fn view_bounds_changed(_: Id, _: Selector, notification: Id) callconv(.c) void {
    const clip_view = objc.send(?Id, notification, "object", .{}) orelse return;
    const scroll_view = objc.send(?Id, clip_view, "superview", .{});
    if (document.find(.scroll_view, scroll_view)) |scrolled| document.outline_follow(scrolled);
}

fn outline_row_count(_: Id, _: Selector, table: ?Id) callconv(.c) isize {
    const shown = document.find(.outline_view, table) orelse return 0;
    return shown.content.heading_count;
}

fn outline_row_view(_: Id, _: Selector, table: ?Id, _: ?Id, row: isize) callconv(.c) ?Id {
    const shown = document.find(.outline_view, table) orelse return null;
    if (row < 0 or row >= shown.content.heading_count) return null;
    const heading = shown.content.headings[@intCast(row)];
    assert(heading.level >= shown.heading_level_min);

    const label = objc.send(
        Id,
        objc.class("NSTextField"),
        "labelWithString:",
        .{cocoa.string(heading.title)},
    );
    const line_break_truncate_tail: usize = 4;
    objc.send(void, label, "setLineBreakMode:", .{line_break_truncate_tail});
    objc.send(void, label, "setTranslatesAutoresizingMaskIntoConstraints:", .{false});
    const top_level = heading.level == shown.heading_level_min;
    objc.send(void, label, "setTextColor:", .{
        if (top_level) cocoa.color("labelColor") else cocoa.color("secondaryLabelColor"),
    });

    const cell = objc.new("NSTableCellView");
    objc.send(void, cell, "addSubview:", .{label});
    objc.send(void, cell, "setTextField:", .{label});
    const indent: f64 = @floatFromInt(@as(u32, heading.level - shown.heading_level_min) * 12);
    constraint_activate(label, "leadingAnchor", cell, "leadingAnchor", 2 + indent);
    constraint_activate(cell, "trailingAnchor", label, "trailingAnchor", 2);
    constraint_activate(label, "centerYAnchor", cell, "centerYAnchor", 0);
    return cell;
}

fn constraint_activate(
    first: Id,
    comptime first_anchor: [:0]const u8,
    second: Id,
    comptime second_anchor: [:0]const u8,
    constant: f64,
) void {
    const constraint = objc.send(
        Id,
        objc.send(Id, first, first_anchor, .{}),
        "constraintEqualToAnchor:constant:",
        .{ objc.send(Id, second, second_anchor, .{}), constant },
    );
    objc.send(void, constraint, "setActive:", .{true});
}

fn outline_selection_changed(_: Id, _: Selector, notification: Id) callconv(.c) void {
    const table = objc.send(?Id, notification, "object", .{});
    const shown = document.find(.outline_view, table) orelse return;
    if (shown.outline_selecting) return;
    const row = objc.send(isize, table.?, "selectedRow", .{});
    if (row < 0 or row >= shown.content.heading_count) return;
    document.heading_click(shown, @intCast(row));
}

/// Schemes that a click may hand to another application. A document is untrusted input, so a
/// link must not be able to start an arbitrary URL handler.
const schemes_allowed = [_][]const u8{ "http", "https", "mailto" };

/// Links inside the document scroll to their heading, links to other Markdown files show them in
/// the same window, and web and mail links go to the default application.
fn link_clicked(_: Id, _: Selector, text_view: ?Id, link: Id, _: usize) callconv(.c) bool {
    const shown = document.find(.text_view, text_view) orelse return false;
    const is_string = objc.send(bool, link, "isKindOfClass:", .{objc.class("NSString")});
    if (!is_string) return false;
    const destination = cocoa.string_bytes(link);
    if (destination.len == 0) return true;
    if (destination[0] == '#') {
        document.fragment_follow(shown, destination[1..]);
        return true;
    }
    const scheme_end = std.mem.indexOfScalar(u8, destination, ':');
    const path_end = std.mem.indexOfAny(u8, destination, "/?#") orelse destination.len;
    if (scheme_end != null and scheme_end.? < path_end) {
        const scheme = destination[0..scheme_end.?];
        if (std.ascii.eqlIgnoreCase(scheme, "file")) {
            const path_start = if (std.mem.startsWith(u8, destination[scheme.len..], "://"))
                scheme.len + 3
            else
                scheme.len + 1;
            file_link_open(shown, destination[path_start..]);
            return true;
        }
        for (schemes_allowed) |allowed| {
            if (std.ascii.eqlIgnoreCase(scheme, allowed)) url_open(link);
        }
        return true;
    }
    if (std.mem.indexOfScalar(u8, destination, '@') != null and path_end == destination.len) {
        url_open(objc.send(Id, cocoa.string("mailto:"), "stringByAppendingString:", .{link}));
        return true;
    }
    file_link_open(shown, destination);
    return true;
}

fn url_open(address: Id) void {
    const url = objc.send(?Id, objc.class("NSURL"), "URLWithString:", .{address}) orelse return;
    const workspace = objc.send(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    _ = objc.send(bool, workspace, "openURL:", .{url});
}

/// Follows a link to a local file, relative to the directory of the document. A Markdown file
/// replaces the document in the window. Any other file is shown in Finder and not opened:
/// opening it would let a document run a script or an application with one click.
fn file_link_open(shown: *document.Document, destination: []const u8) void {
    const path_end = std.mem.indexOfAny(u8, destination, "?#") orelse destination.len;
    if (path_end == 0) return;
    const fragment_start = std.mem.indexOfScalar(u8, destination, '#');
    const fragment = if (fragment_start) |start| destination[start + 1 ..] else "";
    const path_raw = cocoa.string(destination[0..path_end]);
    var file_path = objc.send(
        ?Id,
        path_raw,
        "stringByRemovingPercentEncoding",
        .{},
    ) orelse path_raw;
    if (!objc.send(bool, file_path, "isAbsolutePath", .{})) {
        const own_path = cocoa.string(shown.path());
        const directory = objc.send(Id, own_path, "stringByDeletingLastPathComponent", .{});
        file_path = objc.send(Id, directory, "stringByAppendingPathComponent:", .{file_path});
    }
    file_path = objc.send(Id, file_path, "stringByStandardizingPath", .{});
    const extension = cocoa.string_bytes(objc.send(Id, file_path, "pathExtension", .{}));
    for (extensions) |known| {
        if (!std.ascii.eqlIgnoreCase(extension, known)) continue;
        const bytes = cocoa.string_bytes(file_path);
        if (bytes.len == 0) return;
        document.navigate(shown, bytes, fragment) catch |err| open_alert_show(file_path, err);
        return;
    }
    const workspace = objc.send(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const url = objc.send(Id, objc.class("NSURL"), "fileURLWithPath:", .{file_path});
    objc.send(void, workspace, "activateFileViewerSelectingURLs:", .{cocoa.array(&.{url})});
}

// Toolbar.

fn toolbar_identifiers(_: Id, _: Selector, _: ?Id) callconv(.c) Id {
    return cocoa.array(&.{
        cocoa.NSToolbarToggleSidebarItemIdentifier,
        cocoa.NSToolbarSidebarTrackingSeparatorItemIdentifier,
        cocoa.string(toolbar_back.identifier),
        cocoa.string(toolbar_forward.identifier),
        cocoa.NSToolbarFlexibleSpaceItemIdentifier,
        cocoa.string(toolbar_zoom_out.identifier),
        cocoa.string(toolbar_zoom_in.identifier),
    });
}

fn toolbar_item_create(_: Id, _: Selector, _: ?Id, identifier: Id, _: bool) callconv(.c) ?Id {
    const name = cocoa.string_bytes(identifier);
    const button = for (toolbar_buttons) |candidate| {
        if (std.mem.eql(u8, name, candidate.identifier)) break candidate;
    } else return null;
    const item = objc.autorelease(objc.send(
        Id,
        objc.alloc("NSToolbarItem"),
        "initWithItemIdentifier:",
        .{identifier},
    ));
    const label = cocoa.string(button.label);
    objc.send(void, item, "setLabel:", .{label});
    objc.send(void, item, "setToolTip:", .{label});
    if (cocoa.symbol(button.symbol)) |image| objc.send(void, item, "setImage:", .{image});
    objc.send(void, item, "setBordered:", .{true});
    objc.send(void, item, "setNavigational:", .{button.navigational});
    objc.send(void, item, "setTarget:", .{controller});
    objc.send(void, item, "setAction:", .{objc.selector_dynamic(button.action)});
    return item;
}

// Menu bar.

const Modifiers = struct {
    // NSEventModifierFlags.
    const shift: usize = 1 << 17;
    const control: usize = 1 << 18;
    const option: usize = 1 << 19;
    const command: usize = 1 << 20;
};

const Item = struct {
    title: []const u8 = "",
    action: ?[:0]const u8 = null,
    key: []const u8 = "",
    modifiers: usize = Modifiers.command,
    /// NSTextFinderAction for the find commands, which share one action.
    tag: isize = 0,
};

const separator: Item = .{};

fn menu_add(bar: Id, title: []const u8, items: []const Item) Id {
    const menu_allocated = objc.alloc("NSMenu");
    const menu = objc.autorelease(
        objc.send(Id, menu_allocated, "initWithTitle:", .{cocoa.string(title)}),
    );
    for (items) |item| {
        if (item.title.len == 0) {
            const separator_item = objc.send(Id, objc.class("NSMenuItem"), "separatorItem", .{});
            objc.send(void, menu, "addItem:", .{separator_item});
            continue;
        }
        const menu_item = objc.send(Id, menu, "addItemWithTitle:action:keyEquivalent:", .{
            cocoa.string(item.title),
            if (item.action) |action| @as(?Selector, objc.selector_dynamic(action)) else null,
            cocoa.string(item.key),
        });
        objc.send(void, menu_item, "setKeyEquivalentModifierMask:", .{item.modifiers});
        objc.send(void, menu_item, "setTag:", .{item.tag});
    }
    const bar_item = objc.send(Id, bar, "addItemWithTitle:action:keyEquivalent:", .{
        cocoa.string(title),
        @as(?Selector, null),
        cocoa.string(""),
    });
    objc.send(void, bar_item, "setSubmenu:", .{menu});
    return menu;
}

/// Adds File > Open Recent. Its items are made when it opens, from the list of recent documents
/// that `NSDocumentController` keeps.
fn menu_recent_add(file_menu: Id) void {
    const title = cocoa.string("Open Recent");
    const menu = objc.autorelease(objc.send(Id, objc.alloc("NSMenu"), "initWithTitle:", .{title}));
    objc.send(void, menu, "setDelegate:", .{controller});
    const item = objc.autorelease(objc.send(
        Id,
        objc.alloc("NSMenuItem"),
        "initWithTitle:action:keyEquivalent:",
        .{ title, @as(?Selector, null), cocoa.string("") },
    ));
    objc.send(void, item, "setSubmenu:", .{menu});
    objc.send(void, file_menu, "insertItem:atIndex:", .{ item, @as(isize, 1) });
}

/// Adds the Edit menu. It is separate from `menu_bar_create` to keep that function short.
fn menu_edit_add(bar: Id) void {
    const command_shift = Modifiers.command | Modifiers.shift;
    _ = menu_add(bar, "Edit", &.{
        .{ .title = "Copy", .action = "copy:", .key = "c" },
        .{ .title = "Select All", .action = "selectAll:", .key = "a" },
        separator,
        .{ .title = "Find…", .action = "performTextFinderAction:", .key = "f", .tag = 1 },
        .{ .title = "Find Next", .action = "performTextFinderAction:", .key = "g", .tag = 2 },
        .{
            .title = "Find Previous",
            .action = "performTextFinderAction:",
            .key = "g",
            .modifiers = command_shift,
            .tag = 3,
        },
        .{
            .title = "Use Selection for Find",
            .action = "performTextFinderAction:",
            .key = "e",
            .tag = 7,
        },
    });
}

/// Adds the View menu. It is separate from `menu_bar_create` to keep that function short.
fn menu_view_add(bar: Id) void {
    const command_control = Modifiers.command | Modifiers.control;
    _ = menu_add(bar, "View", &.{
        .{
            .title = "Show Sidebar",
            .action = "toggleSidebar:",
            .key = "s",
            .modifiers = command_control,
        },
        separator,
        .{ .title = "Actual Size", .action = "zoomReset:", .key = "0" },
        .{ .title = "Zoom In", .action = "zoomIn:", .key = "+" },
        .{ .title = "Zoom Out", .action = "zoomOut:", .key = "-" },
        separator,
        .{ .title = "Load Remote Images", .action = "loadRemoteImages:" },
        separator,
        .{
            .title = "Enter Full Screen",
            .action = "toggleFullScreen:",
            .key = "f",
            .modifiers = command_control,
        },
    });
}

fn menu_bar_create() void {
    const bar = objc.new("NSMenu");
    const command_option = Modifiers.command | Modifiers.option;
    _ = menu_add(bar, "mini-md-view", &.{
        .{ .title = "About mini-md-view", .action = "orderFrontStandardAboutPanel:" },
        separator,
        .{ .title = "Hide mini-md-view", .action = "hide:", .key = "h" },
        .{
            .title = "Hide Others",
            .action = "hideOtherApplications:",
            .key = "h",
            .modifiers = command_option,
        },
        .{ .title = "Show All", .action = "unhideAllApplications:" },
        separator,
        .{ .title = "Quit mini-md-view", .action = "terminate:", .key = "q" },
    });
    const file_menu = menu_add(bar, "File", &.{
        .{ .title = "Open…", .action = "openDocument:", .key = "o" },
        separator,
        .{ .title = "Close", .action = "performClose:", .key = "w" },
        .{ .title = "Reload", .action = "reloadDocument:", .key = "r" },
        separator,
        .{ .title = "Print…", .action = "print:", .key = "p" },
    });
    menu_recent_add(file_menu);
    menu_edit_add(bar);
    menu_view_add(bar);
    _ = menu_add(bar, "Go", &.{
        .{ .title = "Back", .action = "goBack:", .key = "[" },
        .{ .title = "Forward", .action = "goForward:", .key = "]" },
    });
    const window_menu = menu_add(bar, "Window", &.{
        .{ .title = "Minimize", .action = "performMiniaturize:", .key = "m" },
        .{ .title = "Zoom", .action = "performZoom:" },
        separator,
        .{ .title = "Bring All to Front", .action = "arrangeInFront:" },
    });
    objc.send(void, app(), "setMainMenu:", .{bar});
    objc.send(void, app(), "setWindowsMenu:", .{window_menu});
}
