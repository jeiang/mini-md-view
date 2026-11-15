//! Minied: a native macOS viewer for Markdown files.
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
const Id = objc.Id;
const Selector = objc.Selector;

const extensions = [_][]const u8{ "md", "markdown", "mdown", "mkd", "mdx", "txt" };
const refresh_interval_seconds = 1.0;

const toolbar_zoom_out = "MiniedZoomOut";
const toolbar_zoom_in = "MiniedZoomIn";

var controller: Id = undefined;

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
    return objc.class_define("MiniedController", "NSObject", &.{
        .{ .name = "applicationDidFinishLaunching:", .types = "v@:@", .implementation = &did_finish_launching },
        .{ .name = "application:openFiles:", .types = "v@:@@", .implementation = &open_files },
        .{
            .name = "applicationShouldHandleReopen:hasVisibleWindows:",
            .types = "B@:@B",
            .implementation = &should_handle_reopen,
        },
        .{
            .name = "applicationSupportsSecureRestorableState:",
            .types = "B@:@",
            .implementation = &supports_secure_state,
        },
        .{ .name = "openDocument:", .types = "v@:@", .implementation = &action_open },
        .{ .name = "reloadDocument:", .types = "v@:@", .implementation = &action_reload },
        .{ .name = "zoomIn:", .types = "v@:@", .implementation = &action_zoom_in },
        .{ .name = "zoomOut:", .types = "v@:@", .implementation = &action_zoom_out },
        .{ .name = "zoomReset:", .types = "v@:@", .implementation = &action_zoom_reset },
        .{ .name = "validateMenuItem:", .types = "B@:@", .implementation = &validate_item },
        .{ .name = "validateToolbarItem:", .types = "B@:@", .implementation = &validate_item },
        .{ .name = "windowWillClose:", .types = "v@:@", .implementation = &window_will_close },
        .{ .name = "numberOfRowsInTableView:", .types = "q@:@", .implementation = &outline_row_count },
        .{ .name = "tableView:viewForTableColumn:row:", .types = "@@:@@q", .implementation = &outline_row_view },
        .{
            .name = "tableViewSelectionDidChange:",
            .types = "v@:@",
            .implementation = &outline_selection_changed,
        },
        .{ .name = "textView:clickedOnLink:atIndex:", .types = "B@:@@Q", .implementation = &link_clicked },
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
        .{ .name = "timerFired:", .types = "v@:@", .implementation = &timer_fired },
        .{ .name = frame_changed, .types = "v@:@", .implementation = &view_frame_changed },
    }, false);
}

// Application delegate.

fn did_finish_launching(_: Id, _: Selector, _: ?Id) callconv(.c) void {
    _ = objc.send(
        Id,
        objc.class("NSTimer"),
        "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:",
        .{ @as(f64, refresh_interval_seconds), controller, objc.selector("timerFired:"), @as(?Id, null), true },
    );
    arguments_open();
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
        var file_path = objc.send(Id, arguments, "objectAtIndex:", .{index});
        const argument = cocoa.string_bytes(file_path);
        if (argument.len == 0) continue;
        if (argument[0] == '-') {
            index += 1;
            continue;
        }
        if (!objc.send(bool, file_path, "isAbsolutePath", .{})) {
            const manager = objc.send(Id, objc.class("NSFileManager"), "defaultManager", .{});
            const directory = objc.send(Id, manager, "currentDirectoryPath", .{});
            file_path = objc.send(Id, directory, "stringByAppendingPathComponent:", .{file_path});
        }
        path_open(objc.send(Id, file_path, "stringByStandardizingPath", .{}));
    }
}

fn open_files(_: Id, _: Selector, _: ?Id, file_names: Id) callconv(.c) void {
    const count = objc.send(usize, file_names, "count", .{});
    for (0..count) |index| path_open(objc.send(Id, file_names, "objectAtIndex:", .{index}));
    const reply_success: usize = 0;
    objc.send(void, app(), "replyToOpenOrPrint:", .{reply_success});
}

fn should_handle_reopen(_: Id, _: Selector, _: ?Id, has_visible_windows: bool) callconv(.c) bool {
    if (!has_visible_windows and document.open_count() == 0) open_panel_run();
    return true;
}

fn supports_secure_state(_: Id, _: Selector, _: ?Id) callconv(.c) bool {
    return true;
}

fn timer_fired(_: Id, _: Selector, _: ?Id) callconv(.c) void {
    document.refresh_all();
}

// Opening documents.

fn path_open(file_path: Id) void {
    const bytes = cocoa.string_bytes(file_path);
    if (bytes.len == 0) return;
    document.open(bytes, controller) catch |err| {
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
    };
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
    const urls = objc.send(Id, panel, "URLs", .{});
    const count = objc.send(usize, urls, "count", .{});
    for (0..count) |index| {
        const url = objc.send(Id, urls, "objectAtIndex:", .{index});
        if (objc.send(?Id, url, "path", .{})) |file_path| path_open(file_path);
    }
}

// Menu and toolbar actions.

fn action_open(_: Id, _: Selector, _: ?Id) callconv(.c) void {
    open_panel_run();
}

fn action_reload(_: Id, _: Selector, _: ?Id) callconv(.c) void {
    const current = document.current() orelse return;
    document.reload(current) catch {
        alert_show("The document could not be reloaded.", "The file is missing or is no longer text.");
    };
}

fn action_zoom_in(_: Id, _: Selector, _: ?Id) callconv(.c) void {
    if (document.current()) |current| document.zoom(current, .in);
}

fn action_zoom_out(_: Id, _: Selector, _: ?Id) callconv(.c) void {
    if (document.current()) |current| document.zoom(current, .out);
}

fn action_zoom_reset(_: Id, _: Selector, _: ?Id) callconv(.c) void {
    if (document.current()) |current| document.zoom(current, .reset);
}

/// Document actions need a document. Opening a file is always possible.
fn validate_item(_: Id, _: Selector, item: Id) callconv(.c) bool {
    const action = objc.send(?Selector, item, "action", .{});
    if (action == objc.selector("openDocument:")) return true;
    return document.current() != null;
}

// Window, outline and text view delegates.

fn window_will_close(_: Id, _: Selector, notification: Id) callconv(.c) void {
    const window = objc.send(?Id, notification, "object", .{});
    if (document.find(.window, window)) |closing| document.close(closing);
}

fn view_frame_changed(_: Id, _: Selector, notification: Id) callconv(.c) void {
    const view = objc.send(?Id, notification, "object", .{});
    if (document.find(.scroll_view, view)) |resized| document.inset_update(resized);
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

    const label = objc.send(Id, objc.class("NSTextField"), "labelWithString:", .{cocoa.string(heading.title)});
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
    const row = objc.send(isize, table.?, "selectedRow", .{});
    if (row < 0 or row >= shown.content.heading_count) return;
    document.heading_show(shown, @intCast(row));
}

/// Links inside the document scroll to their heading, links to other Markdown files open in the
/// viewer, and everything else goes to the system's default application.
fn link_clicked(_: Id, _: Selector, text_view: ?Id, link: Id, _: usize) callconv(.c) bool {
    const shown = document.find(.text_view, text_view) orelse return false;
    const is_string = objc.send(bool, link, "isKindOfClass:", .{objc.class("NSString")});
    if (!is_string) return false;
    const destination = cocoa.string_bytes(link);
    if (destination.len == 0) return true;
    if (destination[0] == '#') {
        _ = document.anchor_show(shown, destination[1..]);
        return true;
    }
    const workspace = objc.send(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const scheme_end = std.mem.indexOfScalar(u8, destination, ':');
    const path_end = std.mem.indexOfAny(u8, destination, "/?#") orelse destination.len;
    if (scheme_end != null and scheme_end.? < path_end) {
        const url = objc.send(?Id, objc.class("NSURL"), "URLWithString:", .{link}) orelse return true;
        _ = objc.send(bool, workspace, "openURL:", .{url});
        return true;
    }
    if (std.mem.indexOfScalar(u8, destination, '@') != null and path_end == destination.len) {
        const address = objc.send(Id, cocoa.string("mailto:"), "stringByAppendingString:", .{link});
        const url = objc.send(?Id, objc.class("NSURL"), "URLWithString:", .{address}) orelse return true;
        _ = objc.send(bool, workspace, "openURL:", .{url});
        return true;
    }
    file_link_open(shown, destination);
    return true;
}

/// Opens a link to a local file, relative to the directory of the document.
fn file_link_open(shown: *document.Document, destination: []const u8) void {
    const path_end = std.mem.indexOfAny(u8, destination, "?#") orelse destination.len;
    if (path_end == 0) return;
    const path_raw = cocoa.string(destination[0..path_end]);
    var file_path = objc.send(?Id, path_raw, "stringByRemovingPercentEncoding", .{}) orelse path_raw;
    if (!objc.send(bool, file_path, "isAbsolutePath", .{})) {
        const own_path = cocoa.string(shown.path());
        const directory = objc.send(Id, own_path, "stringByDeletingLastPathComponent", .{});
        file_path = objc.send(Id, directory, "stringByAppendingPathComponent:", .{file_path});
    }
    file_path = objc.send(Id, file_path, "stringByStandardizingPath", .{});
    const extension = cocoa.string_bytes(objc.send(Id, file_path, "pathExtension", .{}));
    for (extensions) |known| {
        if (std.ascii.eqlIgnoreCase(extension, known)) return path_open(file_path);
    }
    const workspace = objc.send(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const url = objc.send(Id, objc.class("NSURL"), "fileURLWithPath:", .{file_path});
    _ = objc.send(bool, workspace, "openURL:", .{url});
}

// Toolbar.

fn toolbar_identifiers(_: Id, _: Selector, _: ?Id) callconv(.c) Id {
    return cocoa.array(&.{
        cocoa.NSToolbarToggleSidebarItemIdentifier,
        cocoa.NSToolbarSidebarTrackingSeparatorItemIdentifier,
        cocoa.NSToolbarFlexibleSpaceItemIdentifier,
        cocoa.string(toolbar_zoom_out),
        cocoa.string(toolbar_zoom_in),
    });
}

fn toolbar_item_create(_: Id, _: Selector, _: ?Id, identifier: Id, _: bool) callconv(.c) ?Id {
    const name = cocoa.string_bytes(identifier);
    const zoom_in = std.mem.eql(u8, name, toolbar_zoom_in);
    if (!zoom_in and !std.mem.eql(u8, name, toolbar_zoom_out)) return null;
    const item = objc.autorelease(objc.send(
        Id,
        objc.alloc("NSToolbarItem"),
        "initWithItemIdentifier:",
        .{identifier},
    ));
    const label = cocoa.string(if (zoom_in) "Zoom In" else "Zoom Out");
    const symbol_name = if (zoom_in) "textformat.size.larger" else "textformat.size.smaller";
    objc.send(void, item, "setLabel:", .{label});
    objc.send(void, item, "setToolTip:", .{label});
    if (cocoa.symbol(symbol_name)) |image| objc.send(void, item, "setImage:", .{image});
    objc.send(void, item, "setBordered:", .{true});
    objc.send(void, item, "setTarget:", .{controller});
    objc.send(void, item, "setAction:", .{
        if (zoom_in) objc.selector("zoomIn:") else objc.selector("zoomOut:"),
    });
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
    const menu = objc.autorelease(objc.send(Id, objc.alloc("NSMenu"), "initWithTitle:", .{cocoa.string(title)}));
    for (items) |item| {
        if (item.title.len == 0) {
            objc.send(void, menu, "addItem:", .{objc.send(Id, objc.class("NSMenuItem"), "separatorItem", .{})});
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

fn menu_bar_create() void {
    const bar = objc.new("NSMenu");
    const command_shift = Modifiers.command | Modifiers.shift;
    const command_control = Modifiers.command | Modifiers.control;
    const command_option = Modifiers.command | Modifiers.option;
    _ = menu_add(bar, "Minied", &.{
        .{ .title = "About Minied", .action = "orderFrontStandardAboutPanel:" },
        separator,
        .{ .title = "Hide Minied", .action = "hide:", .key = "h" },
        .{ .title = "Hide Others", .action = "hideOtherApplications:", .key = "h", .modifiers = command_option },
        .{ .title = "Show All", .action = "unhideAllApplications:" },
        separator,
        .{ .title = "Quit Minied", .action = "terminate:", .key = "q" },
    });
    _ = menu_add(bar, "File", &.{
        .{ .title = "Open…", .action = "openDocument:", .key = "o" },
        separator,
        .{ .title = "Close", .action = "performClose:", .key = "w" },
        .{ .title = "Reload", .action = "reloadDocument:", .key = "r" },
        separator,
        .{ .title = "Print…", .action = "print:", .key = "p" },
    });
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
        .{ .title = "Use Selection for Find", .action = "performTextFinderAction:", .key = "e", .tag = 7 },
    });
    _ = menu_add(bar, "View", &.{
        .{ .title = "Show Sidebar", .action = "toggleSidebar:", .key = "s", .modifiers = command_control },
        separator,
        .{ .title = "Actual Size", .action = "zoomReset:", .key = "0" },
        .{ .title = "Zoom In", .action = "zoomIn:", .key = "+" },
        .{ .title = "Zoom Out", .action = "zoomOut:", .key = "-" },
        separator,
        .{ .title = "Enter Full Screen", .action = "toggleFullScreen:", .key = "f", .modifiers = command_control },
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
