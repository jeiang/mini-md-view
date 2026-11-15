//! Renderer: Markdown events to an attributed string for the native text system.
//!
//! Text, lists, tables, quotes and code blocks all use TextKit: paragraph styles, tab stops,
//! `NSTextTable`, and `NSTextBlock` subclasses that draw their own backgrounds. Diagrams and
//! images are text attachments. The result is one attributed string in one text view, so that
//! selection, copy, find and printing work across the whole document.

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc.zig");
const cocoa = @import("cocoa.zig");
const canvas = @import("canvas.zig");
const markdown = @import("markdown.zig");
const mermaid = @import("mermaid.zig");
const highlight = @import("highlight.zig");
const scene = @import("scene.zig");
const Id = objc.Id;

pub const headings_max = 2048;
pub const diagrams_max = 64;
const heading_title_size_max = 160;
const heading_text_size_max = headings_max * 48;
const commands_max = 1 << 14;
const points_max = 1 << 15;
const diagram_text_size_max = 512 * 1024;
const table_cells_max = 4096;
const frames_max = markdown.depth_max + 2;

/// Width of the text column at zoom 1. Text lines longer than this are hard to read.
pub const column_width = 720;

const size_body = 15;
const sizes_heading = [6]f64{ 30, 23, 19, 16, 15, 14 };
const size_code = 13;
const list_indent = 26;

pub const Heading = struct {
    level: u8,
    title: []const u8,
    /// Position of the heading in the attributed string, in UTF-16 units.
    location: usize,
};

/// What a document keeps after rendering, besides the attributed string. Diagram attachments
/// point at `diagrams`, so the content must outlive the attributed string and must not be
/// rebuilt while a text view still shows the old string.
pub const Content = struct {
    headings: [headings_max]Heading,
    heading_count: u32,
    heading_text: [heading_text_size_max]u8,
    heading_text_count: u32,
    diagrams: [diagrams_max]canvas.Diagram,
    diagram_count: u32,
    commands: [commands_max]scene.Command,
    command_count: u32,
    points: [points_max]scene.Point,
    point_count: u32,
    /// Diagram sources and generated diagram text.
    text: [diagram_text_size_max]u8,
    text_count: u32,
    /// Positions of footnote definitions and of their first references, by footnote number
    /// minus one, or `location_none`.
    footnote_locations: [markdown.footnotes_max]usize,
    footnote_reference_locations: [markdown.footnotes_max]usize,

    pub fn reset(content: *Content) void {
        content.heading_count = 0;
        content.heading_text_count = 0;
        content.diagram_count = 0;
        content.command_count = 0;
        content.point_count = 0;
        content.text_count = 0;
        content.footnote_locations = @splat(location_none);
        content.footnote_reference_locations = @splat(location_none);
    }

    pub fn headings_slice(content: *const Content) []const Heading {
        assert(content.heading_count <= headings_max);
        return content.headings[0..content.heading_count];
    }

    /// The position that a `fn-N` or `fnref-N` link fragment points to.
    pub fn footnote_location(content: *const Content, fragment: []const u8) ?usize {
        const reference = std.mem.startsWith(u8, fragment, "fnref-");
        if (!reference and !std.mem.startsWith(u8, fragment, "fn-")) return null;
        const digits = fragment[if (reference) "fnref-".len else "fn-".len..];
        const number = std.fmt.parseInt(u32, digits, 10) catch return null;
        if (number == 0 or number > markdown.footnotes_max) return null;
        const locations = if (reference)
            &content.footnote_reference_locations
        else
            &content.footnote_locations;
        const location = locations[number - 1];
        return if (location == location_none) null else location;
    }
};

const location_none = std.math.maxInt(usize);

pub const Options = struct {
    zoom: f64,
    /// NSString with the directory of the document, which relative image paths start from.
    directory: Id,
    /// Working memory for diagram layout.
    scratch: []u8,
    truncated: bool,
};

const Frame = union(enum) {
    quote: struct { block: Id, alert: markdown.Alert },
    list: struct { ordered: bool, number: u32, tight: bool, item_count: u32 },
    item,
    cell: Id,
};

const FontStyle = struct {
    mono: bool = false,
    bold: bool = false,
    italic: bool = false,
    size: u8 = 0,
};
const font_sizes_count = 10;
const font_size_code_block = 7;
const font_size_tiny = 8;
const font_size_note = 9;

const CodeMode = enum { none, plain, highlight, mermaid };

const Builder = struct {
    storage: Id,
    content: *Content,
    options: Options,
    fonts: [2][2][2][font_sizes_count]?Id = @splat(@splat(@splat(@splat(null)))),

    frames: [frames_max]Frame = undefined,
    frame_count: u32 = 0,
    /// The next block is the first one in its container, which changes the gap above it.
    block_first: bool = true,
    paragraph_start: usize = 0,
    marker_pending: bool = false,
    marker_task: markdown.Task = .none,
    /// The open paragraph or heading carries a list marker on its first line.
    text_marker: bool = false,
    /// A list marker stands on the line above, so the next block follows it closely.
    gap_small_next: bool = false,

    bold_depth: u32 = 0,
    italic_depth: u32 = 0,
    strike_depth: u32 = 0,
    heading_level: u8 = 0,
    link: ?Id = null,
    /// Nesting depth inside an image that was loaded: its alternative text is not shown.
    image_hidden_depth: u32 = 0,
    /// The alternative text of an image that was not loaded links to the image source.
    image_link: bool = false,
    /// The string length after the last paragraph, which a footnote back link can join.
    paragraph_end_location: usize = 0,

    code_mode: CodeMode = .none,
    code_block: ?Id = null,
    code_line_count: u32 = 0,
    mermaid_start: u32 = 0,
    mermaid_overflow: bool = false,
    highlight_language: highlight.Language = undefined,
    highlight_start: u32 = 0,
    /// Zero until the first highlighted block of the document.
    highlight_deadline: u64 = 0,

    table: ?Id = null,
    table_row: u32 = 0,
    table_column: u32 = 0,
    table_header: bool = false,
    table_align: markdown.Align = .default,
    table_column_count: u32 = 0,
    table_widths: [markdown.table_columns_max]f64 = undefined,
    table_cells: [table_cells_max]Id = undefined,
    table_cell_count: u32 = 0,

    fn scaled(builder: *const Builder, value: f64) f64 {
        assert(builder.options.zoom > 0);
        return value * builder.options.zoom;
    }

    fn length(builder: *const Builder) usize {
        return objc.send(usize, builder.storage, "length", .{});
    }

    // Fonts and attributes.

    fn font_size(builder: *const Builder, index: u8) f64 {
        assert(index < font_sizes_count);
        return builder.scaled(switch (index) {
            0 => size_body,
            1...6 => sizes_heading[index - 1],
            font_size_code_block => size_code,
            font_size_tiny => 1,
            font_size_note => size_body * 0.7,
            else => unreachable,
        });
    }

    fn font(builder: *Builder, style: FontStyle) Id {
        const slot = &builder.fonts[@intFromBool(style.mono)][@intFromBool(style.bold)] //
            [@intFromBool(style.italic)][style.size];
        if (slot.*) |cached| return cached;
        const weight_regular: f64 = 0;
        const weight_semibold: f64 = 0.3;
        const weight: f64 = if (style.bold) weight_semibold else weight_regular;
        // Inline code is slightly smaller, so that it matches the x-height of the text around it.
        const mono_inline = style.mono and style.size != font_size_code_block;
        const size = builder.font_size(style.size) * @as(f64, if (mono_inline) 0.9 else 1);
        const font_class = objc.class("NSFont");
        var created = if (style.mono)
            objc.send(Id, font_class, "monospacedSystemFontOfSize:weight:", .{ size, weight })
        else
            objc.send(Id, font_class, "systemFontOfSize:weight:", .{ size, weight });
        if (style.italic) {
            const trait_italic: usize = 1;
            const manager = objc.send(Id, objc.class("NSFontManager"), "sharedFontManager", .{});
            created = objc.send(
                Id,
                manager,
                "convertFont:toHaveTrait:",
                .{ created, trait_italic },
            );
        }
        slot.* = created;
        return created;
    }

    /// Text in a quote is muted, but text in an alert is not.
    fn quote_muted(builder: *const Builder) bool {
        var index = builder.frame_count;
        while (index > 0) {
            index -= 1;
            switch (builder.frames[index]) {
                .quote => |quote| return quote.alert == .none,
                .list, .item, .cell => {},
            }
        }
        return false;
    }

    fn style_current(builder: *const Builder) FontStyle {
        const heading = builder.heading_level > 0;
        return .{
            .bold = builder.bold_depth > 0 or heading or builder.table_header,
            .italic = builder.italic_depth > 0,
            .size = builder.heading_level,
        };
    }

    /// The attributes for a run of text in the current inline state.
    fn attributes(builder: *Builder, style: FontStyle) Id {
        const result = objc.new("NSMutableDictionary");
        const muted = builder.heading_level == 6 or builder.quote_muted();
        const color = if (muted) cocoa.color("secondaryLabelColor") else cocoa.color("labelColor");
        dictionary_set(result, cocoa.NSFontAttributeName, builder.font(style));
        dictionary_set(result, cocoa.NSForegroundColorAttributeName, color);
        if (builder.link) |link| {
            dictionary_set(result, cocoa.NSLinkAttributeName, link);
            dictionary_set(result, cocoa.NSToolTipAttributeName, link);
        }
        if (builder.strike_depth > 0) {
            const style_single: isize = 1;
            dictionary_set(
                result,
                cocoa.NSStrikethroughStyleAttributeName,
                cocoa.number(style_single),
            );
        }
        return result;
    }

    fn append(builder: *Builder, bytes: []const u8, run_attributes: Id) void {
        if (bytes.len == 0) return;
        const piece = objc.autorelease(objc.send(
            Id,
            objc.alloc("NSAttributedString"),
            "initWithString:attributes:",
            .{ cocoa.string(bytes), run_attributes },
        ));
        objc.send(void, builder.storage, "appendAttributedString:", .{piece});
    }

    fn append_text(builder: *Builder, bytes: []const u8) void {
        builder.append(bytes, builder.attributes(builder.style_current()));
    }

    // Containers and spacing.

    fn frame_push(builder: *Builder, frame: Frame) void {
        assert(builder.frame_count < frames_max);
        builder.frames[builder.frame_count] = frame;
        builder.frame_count += 1;
    }

    fn frame_pop(builder: *Builder) Frame {
        assert(builder.frame_count > 0);
        builder.frame_count -= 1;
        return builder.frames[builder.frame_count];
    }

    /// The innermost list, when the current block sits in one of its items.
    fn list_current(builder: *Builder) ?*@FieldType(Frame, "list") {
        var index = builder.frame_count;
        while (index > 0) {
            index -= 1;
            switch (builder.frames[index]) {
                .list => |*list| return list,
                .item => {},
                .quote, .cell => return null,
            }
        }
        return null;
    }

    /// Indent from list items, counted from the innermost text block: blocks have their own
    /// coordinate system, so the indent outside of them is already part of their margin.
    fn indent(builder: *const Builder) f64 {
        var items: u32 = 0;
        var index = builder.frame_count;
        while (index > 0) {
            index -= 1;
            switch (builder.frames[index]) {
                .item => items += 1,
                .list => {},
                .quote, .cell => break,
            }
        }
        return builder.scaled(list_indent) * @as(f64, @floatFromInt(items));
    }

    /// Vertical space above the next block.
    fn gap(builder: *Builder) f64 {
        const normal = builder.scaled(size_body * 0.75);
        if (builder.gap_small_next) {
            builder.gap_small_next = false;
            return builder.scaled(size_body * 0.25);
        }
        if (!builder.block_first) return normal;
        if (builder.frame_count == 0) return 0;
        switch (builder.frames[builder.frame_count - 1]) {
            .quote, .cell => return 0,
            .list => return normal,
            .item => {},
        }
        const list = builder.list_current().?;
        var list_count: u32 = 0;
        for (builder.frames[0..builder.frame_count]) |frame| {
            list_count += @intFromBool(frame == .list);
        }
        const first_of_outer_list = list.item_count == 1 and list_count == 1;
        if (list.tight and !first_of_outer_list) return builder.scaled(size_body * 0.25);
        return normal;
    }

    /// The text blocks that enclose the current paragraph, outermost first.
    fn blocks(builder: *Builder, extra: ?Id) Id {
        const result = objc.new("NSMutableArray");
        for (builder.frames[0..builder.frame_count]) |frame| switch (frame) {
            .quote => |quote| objc.send(void, result, "addObject:", .{quote.block}),
            .cell => |block| objc.send(void, result, "addObject:", .{block}),
            .list, .item => {},
        };
        if (extra) |block| objc.send(void, result, "addObject:", .{block});
        return result;
    }

    const ParagraphOptions = struct {
        before: f64 = 0,
        after: f64 = 0,
        indent_first: f64 = 0,
        indent_rest: f64 = 0,
        alignment: cocoa.TextAlignment = .natural,
        line_spacing: f64 = 0,
        block: ?Id = null,
        marker_tabs: bool = false,
        /// Font of the paragraph's newline, which sets the height of an empty line.
        font_style: ?FontStyle = null,
    };

    /// Ends the paragraph that began at `paragraph_start`, and applies its paragraph style.
    fn paragraph_end(builder: *Builder, options: ParagraphOptions) void {
        const style = objc.new("NSMutableParagraphStyle");
        objc.send(void, style, "setParagraphSpacingBefore:", .{options.before});
        objc.send(void, style, "setParagraphSpacing:", .{options.after});
        objc.send(void, style, "setFirstLineHeadIndent:", .{options.indent_first});
        objc.send(void, style, "setHeadIndent:", .{options.indent_rest});
        objc.send(void, style, "setAlignment:", .{@backingInt(options.alignment)});
        objc.send(void, style, "setLineSpacing:", .{options.line_spacing});
        objc.send(void, style, "setTextBlocks:", .{builder.blocks(options.block)});
        if (options.marker_tabs) {
            const marker_gap = builder.scaled(8);
            objc.send(void, style, "setTabStops:", .{cocoa.array(&.{
                tab_stop(.right, options.indent_rest - marker_gap),
                tab_stop(.left, options.indent_rest),
            })});
        }
        builder.append("\n", builder.attributes(options.font_style orelse builder.style_current()));
        const range: cocoa.Range = .{
            .location = builder.paragraph_start,
            .length = builder.length() - builder.paragraph_start,
        };
        assert(range.length > 0);
        objc.send(
            void,
            builder.storage,
            "addAttribute:value:range:",
            .{ cocoa.NSParagraphStyleAttributeName, style, range },
        );
        builder.block_first = false;
    }

    /// An empty paragraph of the given height, for gaps that paragraph spacing cannot express.
    fn spacer_add(builder: *Builder, height: f64) void {
        if (height <= 0) return;
        builder.paragraph_start = builder.length();
        const style = objc.new("NSMutableParagraphStyle");
        objc.send(void, style, "setMinimumLineHeight:", .{height});
        objc.send(void, style, "setMaximumLineHeight:", .{height});
        objc.send(void, style, "setTextBlocks:", .{builder.blocks(null)});
        const spacer_attributes = builder.attributes(.{ .size = font_size_tiny });
        dictionary_set(spacer_attributes, cocoa.NSParagraphStyleAttributeName, style);
        builder.append("\n", spacer_attributes);
    }

    // List markers.

    /// Starts a block of running text: a paragraph or a heading. A pending list marker goes on
    /// its first line.
    fn text_block_begin(builder: *Builder) bool {
        builder.paragraph_start = builder.length();
        if (!builder.marker_pending) return false;
        builder.marker_pending = false;
        builder.marker_append();
        return true;
    }

    fn marker_append(builder: *Builder) void {
        const list = builder.list_current().?;
        const marker_attributes = builder.attributes(.{});
        dictionary_set(
            marker_attributes,
            cocoa.NSForegroundColorAttributeName,
            cocoa.color("secondaryLabelColor"),
        );
        builder.append("\t", marker_attributes);
        if (builder.marker_task != .none) {
            builder.task_marker_append(marker_attributes);
        } else if (list.ordered) {
            var buffer: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d}.", .{list.number}) catch unreachable;
            builder.append(text, marker_attributes);
        } else {
            var list_count: u32 = 0;
            for (builder.frames[0..builder.frame_count]) |frame| {
                list_count += @intFromBool(frame == .list);
            }
            const bullets = [_][]const u8{ "•", "◦", "▪" };
            builder.append(bullets[(list_count -| 1) % bullets.len], marker_attributes);
        }
        builder.append("\t", marker_attributes);
    }

    fn task_marker_append(builder: *Builder, marker_attributes: Id) void {
        const checked = builder.marker_task == .checked;
        const image = cocoa.symbol(if (checked) "checkmark.square.fill" else "square") orelse {
            return builder.append(if (checked) "☑" else "☐", marker_attributes);
        };
        const tint = if (checked)
            cocoa.color("controlAccentColor")
        else
            cocoa.color("tertiaryLabelColor");
        const configuration = objc.send(
            Id,
            objc.class("NSImageSymbolConfiguration"),
            "configurationWithHierarchicalColor:",
            .{tint},
        );
        const tinted = objc.send(
            ?Id,
            image,
            "imageWithSymbolConfiguration:",
            .{configuration},
        ) orelse image;
        const side = builder.scaled(size_body * 1.05);
        const attachment = objc.new("NSTextAttachment");
        objc.send(void, attachment, "setImage:", .{tinted});
        objc.send(void, attachment, "setBounds:", .{cocoa.Rect.init(0, -side * 0.2, side, side)});
        builder.attachment_append(attachment, marker_attributes);
    }

    fn attachment_append(builder: *Builder, attachment: Id, run_attributes: Id) void {
        const piece = objc.send(
            Id,
            objc.class("NSAttributedString"),
            "attributedStringWithAttachment:",
            .{attachment},
        );
        const location = builder.length();
        objc.send(void, builder.storage, "appendAttributedString:", .{piece});
        const range: cocoa.Range = .{ .location = location, .length = builder.length() - location };
        objc.send(void, builder.storage, "addAttributes:range:", .{ run_attributes, range });
    }

    /// Puts a pending list marker on a line of its own, for items that start with a block that
    /// cannot carry the marker, such as a code block.
    fn marker_flush(builder: *Builder) void {
        if (!builder.text_block_begin()) return;
        const indent_rest = builder.indent();
        builder.paragraph_end(.{
            .before = builder.gap(),
            .indent_first = indent_rest - builder.scaled(list_indent),
            .indent_rest = indent_rest,
            .marker_tabs = true,
        });
        builder.gap_small_next = true;
    }

    fn text_block_end(builder: *Builder, before: f64, after: f64) void {
        const indent_rest = builder.indent();
        const marker_width = if (builder.text_marker) builder.scaled(list_indent) else 0;
        builder.paragraph_end(.{
            .before = before,
            .after = after,
            .indent_first = indent_rest - marker_width,
            .indent_rest = indent_rest,
            .line_spacing = builder.font_size(builder.heading_level) * 0.28,
            .marker_tabs = builder.text_marker,
        });
        builder.text_marker = false;
    }
};

fn dictionary_set(dictionary: Id, key: Id, value: Id) void {
    objc.send(void, dictionary, "setObject:forKey:", .{ value, key });
}

fn tab_stop(alignment: cocoa.TextAlignment, location: f64) Id {
    const options = objc.send(Id, objc.class("NSDictionary"), "dictionary", .{});
    return objc.autorelease(objc.send(
        Id,
        objc.alloc("NSTextTab"),
        "initWithTextAlignment:location:options:",
        .{ @backingInt(alignment), @max(1, location), options },
    ));
}

// Text blocks that draw their own background. TextKit calls them for every paragraph that
// lists the block in its paragraph style.

const block_draw_types = "v@:" ++ cocoa.type_rect ++ "@" ++ cocoa.type_range ++ "@";
const block_draw_name = "drawBackgroundWithFrame:inView:characterRange:layoutManager:";

/// The frame that TextKit passes to a block includes the block's margin. This removes it.
fn block_frame_inner(block: Id, frame: cocoa.Rect) cocoa.Rect {
    var margins: [4]f64 = undefined;
    for (std.enums.values(cocoa.Edge), &margins) |edge, *margin| {
        margin.* = objc.send(f64, block, "widthForLayer:edge:", .{
            @backingInt(cocoa.BlockLayer.margin),
            @backingInt(edge),
        });
    }
    const left = margins[@backingInt(cocoa.Edge.x_min)];
    const top = margins[@backingInt(cocoa.Edge.y_min)];
    const right = margins[@backingInt(cocoa.Edge.x_max)];
    const bottom = margins[@backingInt(cocoa.Edge.y_max)];
    return cocoa.Rect.init(
        frame.origin.x + left,
        frame.origin.y + top,
        @max(0, frame.size.width - left - right),
        @max(0, frame.size.height - top - bottom),
    );
}

fn quote_block_draw(
    block: Id,
    _: objc.Selector,
    frame_outer: cocoa.Rect,
    _: ?Id,
    _: cocoa.Range,
    _: ?Id,
) callconv(.c) void {
    const frame = block_frame_inner(block, frame_outer);
    const context = cocoa.context_current();
    const bar_width: f64 = 3.5;
    const bar = cocoa.Rect.init(frame.origin.x, frame.origin.y, bar_width, frame.size.height);
    cocoa.path_add_rounded(context, bar, bar_width / 2);
    // This method replaces the background drawing, so an alert keeps its bar color there.
    const color = objc.send(?Id, block, "backgroundColor", .{}) orelse
        cocoa.color("controlAccentColor");
    objc.send(void, color, "setFill", .{});
    cocoa.CGContextFillPath(context);
}

fn code_block_draw(
    block: Id,
    _: objc.Selector,
    frame_outer: cocoa.Rect,
    _: ?Id,
    _: cocoa.Range,
    _: ?Id,
) callconv(.c) void {
    const frame = block_frame_inner(block, frame_outer);
    const context = cocoa.context_current();
    cocoa.path_add_rounded(context, frame, 9);
    objc.send(void, cocoa.color_alpha(cocoa.color("labelColor"), 0.055), "setFill", .{});
    cocoa.CGContextFillPath(context);
}

var quote_block_class: ?Id = null;
var code_block_class: ?Id = null;

fn text_block_new(class_slot: *?Id, comptime name: [:0]const u8, draw: *const anyopaque) Id {
    if (class_slot.* == null) {
        class_slot.* = objc.class_define(name, "NSTextBlock", &.{
            .{ .name = block_draw_name, .types = block_draw_types, .implementation = draw },
        }, false);
    }
    const allocated = objc.send(Id, class_slot.*.?, "alloc", .{});
    return objc.autorelease(objc.send(Id, allocated, "init", .{}));
}

/// Sets an absolute width on one edge of a text block layer.
fn block_edge_set(block: Id, layer: cocoa.BlockLayer, edge: cocoa.Edge, width: f64) void {
    assert(width >= 0);
    const type_absolute: usize = 0;
    objc.send(
        void,
        block,
        "setWidth:type:forLayer:edge:",
        .{ width, type_absolute, @backingInt(layer), @backingInt(edge) },
    );
}

/// Makes a text block as wide as its container. Without a width, a block shrinks to nothing.
fn block_fill_width(block: Id) void {
    const type_percentage: usize = 1;
    const dimension_width: usize = 0;
    objc.send(
        void,
        block,
        "setValue:type:forDimension:",
        .{ @as(f64, 100), type_percentage, dimension_width },
    );
}

fn block_layer_set(block: Id, layer: cocoa.BlockLayer, width: f64) void {
    for (std.enums.values(cocoa.Edge)) |edge| block_edge_set(block, layer, edge, width);
}

// Block events.

fn event_apply(builder: *Builder, event: markdown.Event) void {
    switch (event) {
        .blockquote_start => |alert| quote_begin(builder, alert),
        .blockquote_end, .list_end => container_end(builder),
        .list_start => |list| {
            builder.marker_flush();
            builder.frame_push(.{ .list = .{
                .ordered = list.ordered,
                .number = list.start,
                .tight = list.tight,
                .item_count = 0,
            } });
        },
        .item_start => |task| item_begin(builder, task),
        .item_end => {
            builder.marker_flush();
            container_end(builder);
        },
        .paragraph_start => builder.text_marker = builder.text_block_begin(),
        .paragraph_end => {
            builder.text_block_end(builder.gap(), 0);
            builder.paragraph_end_location = builder.length();
        },
        .heading_start => |level| {
            assert(level >= 1 and level <= 6);
            builder.heading_level = level;
            builder.text_marker = builder.text_block_begin();
        },
        .heading_end => heading_end(builder),
        .code_block_start => |info| code_begin(builder, info),
        .code_line => |line| switch (builder.code_mode) {
            .plain => code_line_append(builder, line, false),
            .highlight => highlight_line_add(builder, line),
            .mermaid => mermaid_line_add(builder, line),
            .none => unreachable,
        },
        .code_block_end => code_end(builder),
        .thematic_break => rule_add(builder),
        .table_start => |column_count| table_begin(builder, column_count),
        .table_end => table_end(builder),
        .row_start => |header| builder.table_header = header,
        .row_end => {
            builder.table_header = false;
            builder.table_row += 1;
            builder.table_column = 0;
        },
        .cell_start => |cell_align| {
            builder.table_align = cell_align;
            cell_begin(builder);
        },
        .cell_end => cell_end(builder, builder.table_align),
        .footnote_start => |number| footnote_begin(builder, number),
        .footnote_end => footnote_end(builder),
        else => inline_apply(builder, event),
    }
}

fn container_end(builder: *Builder) void {
    _ = builder.frame_pop();
    builder.block_first = false;
}

fn quote_begin(builder: *Builder, alert: markdown.Alert) void {
    builder.marker_flush();
    const block = text_block_new(&quote_block_class, "MiniMdViewQuoteBlock", &quote_block_draw);
    block_fill_width(block);
    block_edge_set(block, .margin, .y_min, builder.gap());
    block_edge_set(block, .margin, .x_min, builder.indent());
    block_edge_set(block, .padding, .x_min, builder.scaled(16));
    builder.frame_push(.{ .quote = .{ .block = block, .alert = alert } });
    builder.block_first = true;
    if (alert == .none) return;

    const color = switch (alert) {
        .none => unreachable,
        .note => cocoa.color("systemBlueColor"),
        .tip => cocoa.color("systemGreenColor"),
        .important => cocoa.color("systemPurpleColor"),
        .warning => cocoa.color("systemOrangeColor"),
        .caution => cocoa.color("systemRedColor"),
    };
    objc.send(void, block, "setBackgroundColor:", .{color});
    const title = switch (alert) {
        .none => unreachable,
        .note => "Note",
        .tip => "Tip",
        .important => "Important",
        .warning => "Warning",
        .caution => "Caution",
    };
    const title_attributes = builder.attributes(.{ .bold = true });
    dictionary_set(title_attributes, cocoa.NSForegroundColorAttributeName, color);
    builder.paragraph_start = builder.length();
    builder.append(title, title_attributes);
    builder.paragraph_end(.{ .before = builder.gap(), .font_style = .{ .bold = true } });
    builder.gap_small_next = true;
}

fn item_begin(builder: *Builder, task: markdown.Task) void {
    assert(builder.frame_count > 0);
    const list = &builder.frames[builder.frame_count - 1].list;
    if (list.item_count > 0) list.number +|= 1;
    list.item_count += 1;
    builder.frame_push(.item);
    builder.marker_pending = true;
    builder.marker_task = task;
    builder.block_first = true;
}

/// A footnote definition is shown as a one-item ordered list that starts at its number.
fn footnote_begin(builder: *Builder, number: u32) void {
    assert(number >= 1 and number <= markdown.footnotes_max);
    builder.marker_flush();
    builder.content.footnote_locations[number - 1] = builder.length();
    builder.frame_push(.{ .list = .{
        .ordered = true,
        .number = number,
        .tight = false,
        .item_count = 0,
    } });
    item_begin(builder, .none);
}

/// Ends a footnote with a link back to its first reference, on its last paragraph.
fn footnote_end(builder: *Builder) void {
    assert(builder.frame_count >= 2);
    assert(builder.frames[builder.frame_count - 1] == .item);
    const number = builder.frames[builder.frame_count - 2].list.number;
    var buffer: [32]u8 = undefined;
    assert(builder.link == null);
    builder.link = cocoa.string(std.fmt.bufPrint(&buffer, "#fnref-{d}", .{number}) catch {
        unreachable;
    });
    const back_attributes = builder.attributes(.{});
    builder.link = null;
    const back = " \u{21A9}\u{FE0E}";
    const end = builder.length();
    if (!builder.marker_pending and builder.paragraph_end_location == end) {
        assert(end > 0);
        const style = objc.send(
            ?Id,
            builder.storage,
            "attribute:atIndex:effectiveRange:",
            .{ cocoa.NSParagraphStyleAttributeName, end - 1, @as(?*cocoa.Range, null) },
        );
        if (style) |paragraph_style| {
            dictionary_set(back_attributes, cocoa.NSParagraphStyleAttributeName, paragraph_style);
        }
        const piece = objc.autorelease(objc.send(
            Id,
            objc.alloc("NSAttributedString"),
            "initWithString:attributes:",
            .{ cocoa.string(back), back_attributes },
        ));
        objc.send(void, builder.storage, "insertAttributedString:atIndex:", .{ piece, end - 1 });
    } else {
        builder.text_marker = builder.text_block_begin();
        builder.append(back, back_attributes);
        builder.text_block_end(builder.gap(), 0);
    }
    container_end(builder);
    container_end(builder);
}

fn heading_end(builder: *Builder) void {
    const level = builder.heading_level;
    assert(level >= 1 and level <= 6);
    heading_record(builder);
    const top = builder.block_first and builder.frame_count == 0;
    const before_factor: f64 = if (top) 0 else if (level <= 2) 1.5 else 1.1;
    builder.text_block_end(
        builder.scaled(size_body * before_factor),
        builder.scaled(size_body * 0.2),
    );
    builder.heading_level = 0;
}

/// Stores the heading's plain text and position for the outline.
fn heading_record(builder: *Builder) void {
    const content = builder.content;
    if (content.heading_count == headings_max) return;
    const range: cocoa.Range = .{
        .location = builder.paragraph_start,
        .length = builder.length() - builder.paragraph_start,
    };
    const whole = objc.send(Id, builder.storage, "string", .{});
    const title_string = objc.send(Id, whole, "substringWithRange:", .{range});
    var title = std.mem.trim(u8, cocoa.string_bytes(title_string), " \t\n");
    // The marker of a list item is not part of the title. Cut long titles at a character.
    if (std.mem.lastIndexOfScalar(u8, title, '\t')) |tab| title = title[tab + 1 ..];
    var size = @min(title.len, heading_title_size_max);
    while (size > 0 and size < title.len and title[size] & 0xC0 == 0x80) size -= 1;
    if (size > heading_text_size_max - content.heading_text_count) return;
    const stored = content.heading_text[content.heading_text_count..][0..size];
    @memcpy(stored, title[0..size]);
    content.heading_text_count += @intCast(size);
    content.headings[content.heading_count] = .{
        .level = builder.heading_level,
        .title = stored,
        .location = range.location,
    };
    content.heading_count += 1;
}

fn rule_add(builder: *Builder) void {
    builder.marker_flush();
    const block = objc.new("NSTextBlock");
    block_fill_width(block);
    block_edge_set(block, .margin, .y_min, builder.gap() + builder.scaled(8));
    block_edge_set(block, .margin, .y_max, builder.scaled(4));
    block_edge_set(block, .margin, .x_min, builder.indent());
    block_edge_set(block, .border, .y_min, 1);
    objc.send(void, block, "setBorderColor:", .{cocoa.color("separatorColor")});
    builder.paragraph_start = builder.length();
    builder.paragraph_end(.{ .block = block, .font_style = .{ .size = font_size_tiny } });
}

// Code blocks and diagrams.

fn code_begin(builder: *Builder, info: []const u8) void {
    assert(builder.code_mode == .none);
    builder.marker_flush();
    var words = std.mem.tokenizeAny(u8, info, " \t{");
    const language = words.next() orelse "";
    if (std.ascii.eqlIgnoreCase(language, "mermaid")) {
        builder.code_mode = .mermaid;
        builder.mermaid_start = builder.content.text_count;
        builder.mermaid_overflow = false;
    } else {
        code_block_open(builder);
        if (highlight.language_find(language)) |found| {
            builder.code_mode = .highlight;
            builder.highlight_language = found;
            builder.highlight_start = builder.content.text_count;
        }
    }
}

fn code_block_open(builder: *Builder) void {
    const block = text_block_new(&code_block_class, "MiniMdViewCodeBlock", &code_block_draw);
    block_fill_width(block);
    block_edge_set(block, .margin, .y_min, builder.gap());
    block_edge_set(block, .margin, .x_min, builder.indent());
    block_layer_set(block, .padding, builder.scaled(10));
    block_edge_set(block, .padding, .x_min, builder.scaled(14));
    block_edge_set(block, .padding, .x_max, builder.scaled(14));
    builder.code_block = block;
    builder.code_mode = .plain;
    builder.code_line_count = 0;
}

fn code_line_append(builder: *Builder, line: []const u8, caption: bool) void {
    assert(builder.code_block != null);
    const style: FontStyle = .{ .mono = !caption, .size = font_size_code_block };
    const line_attributes = builder.attributes(style);
    if (caption) dictionary_set(
        line_attributes,
        cocoa.NSForegroundColorAttributeName,
        cocoa.color("secondaryLabelColor"),
    );
    builder.paragraph_start = builder.length();
    builder.append(line, line_attributes);
    builder.paragraph_end(.{
        .block = builder.code_block,
        .line_spacing = builder.scaled(2.5),
        .font_style = style,
    });
    builder.code_line_count += 1;
}

fn code_end(builder: *Builder) void {
    if (builder.code_mode == .highlight) highlight_finish(builder);
    if (builder.code_mode == .mermaid) mermaid_finish(builder);
    if (builder.code_mode == .plain and builder.code_line_count == 0) {
        code_line_append(builder, "", false);
    }
    builder.code_block = null;
    builder.code_mode = .none;
    builder.block_first = false;
}

var highlight_spans: [highlight.spans_max]highlight.Span = undefined;

/// Collects the source of a block to highlight. A block too large to highlight is shown plain.
fn highlight_line_add(builder: *Builder, line: []const u8) void {
    const content = builder.content;
    assert(builder.code_mode == .highlight);
    assert(content.text_count <= diagram_text_size_max);
    const size = content.text_count - builder.highlight_start;
    assert(size <= highlight.source_size_max);
    if (line.len + 1 > highlight.source_size_max - size or
        line.len + 1 > diagram_text_size_max - content.text_count)
    {
        const collected = content.text[builder.highlight_start..content.text_count];
        highlight_lines_append(builder, collected, &.{});
        content.text_count = builder.highlight_start;
        builder.code_mode = .plain;
        code_line_append(builder, line, false);
        return;
    }
    @memcpy(content.text[content.text_count..][0..line.len], line);
    content.text[content.text_count + line.len] = '\n';
    content.text_count += @intCast(line.len + 1);
}

fn highlight_finish(builder: *Builder) void {
    const content = builder.content;
    assert(builder.code_mode == .highlight);
    assert(builder.highlight_start <= content.text_count);
    const source = content.text[builder.highlight_start..content.text_count];
    if (builder.highlight_deadline == 0) builder.highlight_deadline = highlight.document_deadline();
    const spans = highlight.highlight(
        builder.highlight_language,
        source,
        &highlight_spans,
        builder.highlight_deadline,
    ) orelse &.{};
    highlight_lines_append(builder, source, spans);
    // The text view copied the source, so its space in the pool is free again.
    content.text_count = builder.highlight_start;
    builder.code_mode = .plain;
}

/// Appends the lines of `source`, each ended by a newline, and colors them with `spans`.
fn highlight_lines_append(
    builder: *Builder,
    source: []const u8,
    spans: []const highlight.Span,
) void {
    assert(source.len == 0 or source[source.len - 1] == '\n');
    assert(source.len <= highlight.source_size_max);
    var line_start: u32 = 0;
    var span_index: usize = 0;
    while (line_start < source.len) {
        const line_end: u32 = @intCast(std.mem.indexOfScalarPos(u8, source, line_start, '\n').?);
        const line = source[line_start..line_end];
        code_line_append(builder, line, false);
        span_index = code_line_color(builder, line, line_start, spans, span_index);
        line_start = line_end + 1;
    }
    assert(span_index <= spans.len);
}

/// Colors the code line just appended with the spans that touch it, from `span_first` on.
/// Returns the first span that continues on the next lines.
fn code_line_color(
    builder: *Builder,
    line: []const u8,
    line_start: u32,
    spans: []const highlight.Span,
    span_first: usize,
) usize {
    assert(span_first <= spans.len);
    assert(builder.length() > builder.paragraph_start);
    const line_end: u32 = line_start + @as(u32, @intCast(line.len));
    // The text view shows invalid UTF-8 as an empty line, so byte offsets do not map to it.
    const appended_length = builder.length() - builder.paragraph_start - 1;
    const valid = highlight.utf16_length(line) == appended_length;
    var span_index = span_first;
    var byte: u32 = 0;
    var unit: usize = 0;
    while (span_index < spans.len and spans[span_index].start < line_end) {
        const span = spans[span_index];
        const start = @max(span.start, line_start) - line_start;
        const end = @min(span.end, line_end) - line_start;
        if (valid and start < end) {
            assert(byte <= start);
            unit += highlight.utf16_length(line[byte..start]);
            const unit_start = unit;
            unit += highlight.utf16_length(line[start..end]);
            byte = end;
            if (highlight_color(span.kind)) |color| objc.send(
                void,
                builder.storage,
                "addAttribute:value:range:",
                .{
                    cocoa.NSForegroundColorAttributeName,
                    color,
                    cocoa.Range{
                        .location = builder.paragraph_start + unit_start,
                        .length = unit - unit_start,
                    },
                },
            );
        }
        if (span.end > line_end) break;
        span_index += 1;
    }
    return span_index;
}

/// Null for kinds shown in the color of the text around the block.
fn highlight_color(kind: highlight.Kind) ?Id {
    return switch (kind) {
        .keyword, .tag => cocoa.color("systemPinkColor"),
        .string => cocoa.color("systemRedColor"),
        .comment => cocoa.color("secondaryLabelColor"),
        .number, .constant => cocoa.color("systemOrangeColor"),
        .type => cocoa.color("systemTealColor"),
        .function => cocoa.color("systemBlueColor"),
        .property, .attribute => cocoa.color("systemIndigoColor"),
        .variable, .operator, .punctuation => null,
    };
}

fn mermaid_line_add(builder: *Builder, line: []const u8) void {
    const content = builder.content;
    assert(content.text_count <= diagram_text_size_max);
    if (line.len + 1 > diagram_text_size_max - content.text_count) {
        builder.mermaid_overflow = true;
        return;
    }
    @memcpy(content.text[content.text_count..][0..line.len], line);
    content.text[content.text_count + line.len] = '\n';
    content.text_count += @intCast(line.len + 1);
}

/// Lays out the collected diagram source. On failure the source is shown as a code block, with
/// a caption that says why.
fn mermaid_finish(builder: *Builder) void {
    const content = builder.content;
    const source = content.text[builder.mermaid_start..content.text_count];
    const failure = mermaid_render(builder, source) orelse {
        builder.code_mode = .none;
        return;
    };
    code_block_open(builder);
    code_line_append(builder, failure, true);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, source, "\n"), '\n');
    while (lines.next()) |line| code_line_append(builder, line, false);
    // The text view copied the source, so its space in the pool is free again.
    content.text_count = builder.mermaid_start;
}

/// Returns null on success, or the reason for the failure.
fn mermaid_render(builder: *Builder, source: []const u8) ?[]const u8 {
    const content = builder.content;
    const overflow = "Diagram not shown: it exceeds the viewer's limits.";
    if (builder.mermaid_overflow or content.diagram_count == diagrams_max) return overflow;
    var drawn = scene.Scene.init(
        content.commands[content.command_count..],
        content.points[content.point_count..],
        content.text[content.text_count..],
    );
    mermaid.render(source, canvas.measurer, builder.options.scratch, &drawn) catch |err| {
        return switch (err) {
            error.Syntax => "Diagram not shown: the source has an error or " ++
                "uses unsupported syntax.",
            error.Overflow => overflow,
        };
    };
    const size_max = 20_000;
    const size = drawn.size;
    if (!(size.width >= 1 and size.width < size_max)) return overflow;
    if (!(size.height >= 1 and size.height < size_max)) return overflow;
    // Shrink the scene to what it uses, and hand the rest of the pools to the next diagram.
    drawn.commands = drawn.commands[0..drawn.command_count];
    drawn.points = drawn.points[0..drawn.point_count];
    drawn.text = drawn.text[0..drawn.text_count];
    content.command_count += drawn.command_count;
    content.point_count += drawn.point_count;
    content.text_count += drawn.text_count;
    const diagram = &content.diagrams[content.diagram_count];
    diagram.* = .{ .scene = drawn, .zoom = builder.options.zoom };
    content.diagram_count += 1;

    builder.paragraph_start = builder.length();
    objc.send(void, builder.storage, "appendAttributedString:", .{
        canvas.attachment_string(diagram),
    });
    const indent = builder.indent();
    builder.paragraph_end(.{
        .before = builder.gap() + builder.scaled(4),
        .indent_first = indent,
        .indent_rest = indent,
        .alignment = .center,
    });
    return null;
}

// Tables.

fn table_begin(builder: *Builder, column_count: u8) void {
    assert(builder.table == null);
    assert(column_count > 0 and column_count <= markdown.table_columns_max);
    builder.marker_flush();
    builder.spacer_add(builder.gap());
    const table = objc.new("NSTextTable");
    objc.send(void, table, "setNumberOfColumns:", .{@as(usize, column_count)});
    objc.send(void, table, "setCollapsesBorders:", .{true});
    builder.table = table;
    builder.table_row = 0;
    builder.table_column = 0;
    builder.table_column_count = column_count;
    builder.table_cell_count = 0;
    @memset(builder.table_widths[0..column_count], 0);
}

fn cell_begin(builder: *Builder) void {
    assert(builder.table_column < builder.table_column_count);
    const block = objc.autorelease(objc.send(
        Id,
        objc.alloc("NSTextTableBlock"),
        "initWithTable:startingRow:rowSpan:startingColumn:columnSpan:",
        .{
            builder.table.?,
            @as(isize, builder.table_row),
            @as(isize, 1),
            @as(isize, builder.table_column),
            @as(isize, 1),
        },
    ));
    block_layer_set(block, .border, 0.5);
    block_layer_set(block, .padding, builder.scaled(6));
    block_edge_set(block, .padding, .x_min, builder.scaled(table_cell_padding));
    block_edge_set(block, .padding, .x_max, builder.scaled(table_cell_padding));
    objc.send(void, block, "setBorderColor:", .{cocoa.color("separatorColor")});
    if (builder.table_header) {
        const fill = cocoa.color_alpha(cocoa.color("labelColor"), 0.055);
        objc.send(void, block, "setBackgroundColor:", .{fill});
    }
    if (builder.table_cell_count < table_cells_max) {
        builder.table_cells[builder.table_cell_count] = block;
    }
    builder.table_cell_count += 1;
    builder.frame_push(.{ .cell = block });
    builder.paragraph_start = builder.length();
}

const table_cell_padding = 12;

fn cell_end(builder: *Builder, cell_align: markdown.Align) void {
    const text_range: cocoa.Range = .{
        .location = builder.paragraph_start,
        .length = builder.length() - builder.paragraph_start,
    };
    if (text_range.length > 0) {
        const text = objc.send(Id, builder.storage, "attributedSubstringFromRange:", .{text_range});
        const width = objc.send(cocoa.Size, text, "size", .{}).width;
        const slot = &builder.table_widths[builder.table_column];
        slot.* = @max(slot.*, width);
    }
    builder.paragraph_end(.{
        .alignment = switch (cell_align) {
            .default => .natural,
            .left => .left,
            .center => .center,
            .right => .right,
        },
        .line_spacing = builder.scaled(size_body * 0.2),
    });
    _ = builder.frame_pop();
    builder.table_column += 1;
}

/// Sizes the columns in proportion to their widest cell. A small table keeps its natural
/// width, and a large one fills the text column.
fn table_end(builder: *Builder) void {
    assert(builder.table != null);
    const column_count = builder.table_column_count;
    const chrome = builder.scaled(2 * table_cell_padding) + 1;
    var total: f64 = 0;
    for (builder.table_widths[0..column_count]) |width| total += @ceil(width) + chrome;
    assert(total > 0);
    const natural = total <= builder.scaled(420);
    const type_absolute: usize = 0;
    const type_percentage: usize = 1;
    const dimension_width: usize = 0;
    if (builder.table_cell_count <= table_cells_max) {
        for (builder.table_cells[0..builder.table_cell_count], 0..) |block, index| {
            const width = @ceil(builder.table_widths[index % column_count]) + chrome;
            objc.send(void, block, "setValue:type:forDimension:", .{
                if (natural) width else width / total * 100,
                if (natural) type_absolute else type_percentage,
                dimension_width,
            });
        }
    }
    builder.table = null;
    builder.block_first = false;
}

// Inline events.

fn inline_apply(builder: *Builder, event: markdown.Event) void {
    switch (event) {
        .text => |bytes| builder.append_text(bytes),
        .code => |bytes| {
            var style = builder.style_current();
            style.mono = true;
            const code_attributes = builder.attributes(style);
            dictionary_set(
                code_attributes,
                cocoa.NSBackgroundColorAttributeName,
                cocoa.color_alpha(cocoa.color("labelColor"), 0.07),
            );
            builder.append(bytes, code_attributes);
        },
        .soft_break => builder.append_text(" "),
        // A line separator breaks the line and stays inside the paragraph.
        .hard_break => builder.append_text("\u{2028}"),
        .footnote_reference => |number| footnote_reference_add(builder, number),
        .emphasis_start => builder.italic_depth += 1,
        .emphasis_end => builder.italic_depth -= 1,
        .strong_start => builder.bold_depth += 1,
        .strong_end => builder.bold_depth -= 1,
        .strike_start => builder.strike_depth += 1,
        .strike_end => builder.strike_depth -= 1,
        .link_start => |destination| builder.link = cocoa.string(destination),
        .link_end => builder.link = null,
        .image_start => |image| image_begin(builder, image),
        .image_end => if (builder.image_link) {
            builder.image_link = false;
            builder.link = null;
        },
        else => unreachable,
    }
}

/// Adds a raised footnote number that links to the footnote.
fn footnote_reference_add(builder: *Builder, number: u32) void {
    assert(number >= 1 and number <= markdown.footnotes_max);
    const locations = &builder.content.footnote_reference_locations;
    if (locations[number - 1] == location_none) locations[number - 1] = builder.length();
    var buffer: [32]u8 = undefined;
    const link = builder.link;
    builder.link = cocoa.string(std.fmt.bufPrint(&buffer, "#fn-{d}", .{number}) catch {
        unreachable;
    });
    var style = builder.style_current();
    style.size = font_size_note;
    const reference_attributes = builder.attributes(style);
    builder.link = link;
    const offset: isize = @intFromFloat(@round(builder.scaled(size_body * 0.35)));
    dictionary_set(reference_attributes, cocoa.NSBaselineOffsetAttributeName, cocoa.number(offset));
    const text = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch unreachable;
    builder.append(text, reference_attributes);
}

fn image_begin(builder: *Builder, image_event: markdown.Image) void {
    const source = image_event.source;
    const image = image_load(builder, source) orelse {
        // Show the alternative text instead, as a link to the image when it has no link yet.
        if (builder.link == null) {
            builder.link = cocoa.string(source);
            builder.image_link = true;
        }
        return;
    };
    const natural = objc.send(cocoa.Size, image, "size", .{});
    assert(natural.width >= 1 and natural.height >= 1);
    const width: f64 = @floatFromInt(image_event.width);
    const height: f64 = @floatFromInt(image_event.height);
    // With one dimension given, the other keeps the aspect ratio.
    const size: cocoa.Size = if (width > 0 and height > 0)
        .{ .width = width, .height = height }
    else if (width > 0)
        .{ .width = width, .height = natural.height * width / natural.width }
    else if (height > 0)
        .{ .width = natural.width * height / natural.height, .height = height }
    else
        natural;
    const scale = @min(1, builder.scaled(column_width - 80) / size.width);
    const attachment = objc.new("NSTextAttachment");
    objc.send(void, attachment, "setImage:", .{image});
    objc.send(void, attachment, "setBounds:", .{
        cocoa.Rect.init(0, 0, @floor(size.width * scale), @floor(size.height * scale)),
    });
    builder.attachment_append(attachment, builder.attributes(builder.style_current()));
    builder.image_hidden_depth = 1;
}

/// Loads an image from a local file. Remote images are not fetched: the viewer never uses the
/// network.
fn image_load(builder: *Builder, source: []const u8) ?Id {
    var path_bytes = source;
    if (std.mem.startsWith(u8, path_bytes, "file://")) {
        path_bytes = path_bytes["file://".len..];
    } else if (std.mem.indexOf(u8, path_bytes, "://") != null) {
        return null;
    }
    path_bytes = path_bytes[0 .. std.mem.indexOfAny(u8, path_bytes, "?#") orelse path_bytes.len];
    if (path_bytes.len == 0) return null;
    const path_raw = cocoa.string(path_bytes);
    var path = objc.send(?Id, path_raw, "stringByRemovingPercentEncoding", .{}) orelse path_raw;
    if (!objc.send(bool, path, "isAbsolutePath", .{})) {
        path = objc.send(Id, builder.options.directory, "stringByAppendingPathComponent:", .{path});
    }
    const loaded = objc.send(?Id, objc.alloc("NSImage"), "initWithContentsOfFile:", .{path});
    const image = objc.autorelease(loaded orelse return null);
    const size = objc.send(cocoa.Size, image, "size", .{});
    if (!(size.width >= 1 and size.height >= 1)) return null;
    return image;
}

fn notice_add(builder: *Builder) void {
    builder.paragraph_start = builder.length();
    const notice_attributes = builder.attributes(.{ .italic = true });
    dictionary_set(
        notice_attributes,
        cocoa.NSForegroundColorAttributeName,
        cocoa.color("secondaryLabelColor"),
    );
    builder.append(
        "The rest of this document is not shown: it exceeds the viewer's limits.",
        notice_attributes,
    );
    builder.paragraph_end(.{ .before = builder.scaled(size_body) });
}

/// Builds the attributed string for the events. Returns an autoreleased object. `content` is
/// reset and refilled, so no text view may still show a string that was built from it.
pub fn build(events: []const markdown.Event, content: *Content, options: Options) Id {
    assert(options.zoom > 0);
    assert(options.scratch.len > 0);
    content.reset();
    var builder: Builder = .{
        .storage = objc.new("NSMutableAttributedString"),
        .content = content,
        .options = options,
    };
    objc.send(void, builder.storage, "beginEditing", .{});
    for (events) |event| {
        if (builder.image_hidden_depth > 0) {
            // Skip the alternative text of a loaded image, including images nested in it.
            if (event == .image_start) builder.image_hidden_depth += 1;
            if (event == .image_end) builder.image_hidden_depth -= 1;
            continue;
        }
        event_apply(&builder, event);
    }
    assert(builder.frame_count == 0);
    assert(builder.code_mode == .none);
    if (options.truncated) notice_add(&builder);
    objc.send(void, builder.storage, "endEditing", .{});
    return builder.storage;
}
