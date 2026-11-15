//! Markdown parser: source bytes to a flat stream of events.
//!
//! The parser handles the CommonMark block structure (containers and leaf blocks) plus the GFM
//! tables, task lists, strikethrough, autolink and alert extensions, and YAML front matter. Of
//! HTML it interprets only comments and a few tags (see `markdown_inline.zig`); all other HTML is
//! passed through as text. The output is a flat, well-nested event stream instead of a tree, so
//! that consumers iterate it with a small explicit stack and no recursion.
//!
//! The parser does not allocate. All working memory lives in a caller-provided `Storage`, which
//! bounds the size of the documents that can be parsed.

const std = @import("std");
const assert = std.debug.assert;
const inline_parser = @import("markdown_inline.zig");

pub const source_size_max = 4 * 1024 * 1024;
pub const events_max = 1 << 18;
pub const tokens_max = inline_parser.tokens_max;
pub const definitions_max = 512;
pub const depth_max = 16;
pub const table_columns_max = 32;
/// Footnote definitions that references can find. Further references stay text.
pub const footnotes_max = 256;

/// Events that one line can emit outside of inline content: closing and opening every container,
/// a leaf block, and one table row.
const events_reserve = 4 * depth_max + 2 * table_columns_max + 16;
comptime {
    assert(events_reserve * 4 < events_max);
}

pub const Align = enum(u8) { default, left, center, right };
pub const Task = enum(u8) { none, unchecked, checked };
pub const List = struct { ordered: bool, start: u32, tight: bool };
/// The kind of a GFM alert, a block quote that starts with a marker such as `[!NOTE]`.
pub const Alert = enum(u8) { none, note, tip, important, warning, caution };

pub const Event = union(enum) {
    blockquote_start: Alert,
    blockquote_end,
    list_start: List,
    list_end,
    item_start: Task,
    item_end,
    paragraph_start,
    paragraph_end,
    /// Payload is the heading level, 1 to 6.
    heading_start: u8,
    heading_end,
    /// Payload is the info string of a fenced block, or empty.
    code_block_start: []const u8,
    code_line: []const u8,
    code_block_end,
    thematic_break,
    /// Payload is the column count.
    table_start: u8,
    table_end,
    /// Payload is true for the header row.
    row_start: bool,
    row_end,
    cell_start: Align,
    cell_end,
    /// A footnote definition, which the parser moves to the end of the document. Payload is
    /// the footnote number, from 1.
    footnote_start: u32,
    footnote_end,

    text: []const u8,
    code: []const u8,
    soft_break,
    hard_break,
    /// Payload is the footnote number, from 1.
    footnote_reference: u32,
    emphasis_start,
    emphasis_end,
    strong_start,
    strong_end,
    strike_start,
    strike_end,
    /// Payload is the link destination.
    link_start: []const u8,
    link_end,
    /// The events up to `image_end` are the alternative text.
    image_start: Image,
    image_end,
};

pub const Definition = struct { label: []const u8, destination: []const u8 };
/// The display size is in pixels, and zero where the source does not give it.
pub const Image = struct { source: []const u8, width: u32 = 0, height: u32 = 0 };

pub const Footnote = struct {
    label: []const u8,
    /// The footnote number, by first reference, or zero while it has no reference.
    number: u32 = 0,
    /// The definition's events in the document, from its `footnote_start` to after its
    /// `footnote_end`. The end is zero until the definition was parsed.
    event_start: u32 = 0,
    event_end: u32 = 0,
};

pub const Storage = struct {
    events: [events_max]Event,
    /// Paragraph text, copied from the source with container prefixes removed. Inline events
    /// point into this buffer. It never needs more bytes than the source has.
    text: [source_size_max]u8,
    tokens: [tokens_max]inline_parser.Token,
    definitions: [definitions_max]Definition,
    footnotes: [footnotes_max]Footnote,
};

pub const Result = struct {
    events: []const Event,
    /// The document exceeded a static limit, and the events cover only a prefix of it.
    truncated: bool,
    word_count: u32,
};

const Container = union(enum) {
    blockquote,
    list: struct { ordered: bool, marker: u8, event_index: u32 },
    item: struct { content_indent: u32, event_index: u32, child_count: u32 },
    /// The index of the footnote that the definition belongs to. A definition without a
    /// footnote, such as a repeated one, is parsed and then dropped.
    footnote: ?u32,
};

const Leaf = union(enum) {
    none,
    paragraph: struct { text_start: u32, line_count: u32, heading_level: u8, first_in_item: bool },
    fenced: struct { marker: u8, length: u32, indent: u32 },
    indented_code: struct { blank_count: u32 },
    table: struct { column_count: u8, aligns: [table_columns_max]Align },
    /// An HTML comment block, which is not shown.
    comment,
};

const Indent = struct { columns: u32, bytes: u32 };

const Marker = struct {
    ordered: bool,
    start: u32,
    /// The bullet character, or the delimiter of an ordered marker.
    marker: u8,
    /// Bytes from the marker's first byte up to the item's content.
    content_offset: u32,
    /// Columns from the marker's first byte up to the item's content.
    content_columns: u32,
    empty: bool,
};

const Fence = struct { marker: u8, length: u32, info: []const u8 };

const Parser = struct {
    storage: *Storage,
    event_count: u32 = 0,
    text_count: u32 = 0,
    definition_count: u32 = 0,
    footnote_definition_count: u32 = 0,
    /// Footnote numbers given out so far.
    footnote_count: u32 = 0,
    word_count: u32 = 0,
    truncated: bool = false,
    containers: [depth_max]Container = undefined,
    container_count: u32 = 0,
    leaf: Leaf = .none,
    /// A blank line was seen inside a list. The next block decides whether that list is loose.
    blank_pending: bool = false,
    blank_event_count: u32 = 0,
    /// The innermost container that the current line opened is a block quote.
    quote_opened: bool = false,

    fn event_add(parser: *Parser, event: Event) void {
        assert(parser.event_count < events_max);
        parser.storage.events[parser.event_count] = event;
        parser.event_count += 1;
    }

    fn events_free(parser: *const Parser) u32 {
        assert(parser.event_count <= events_max);
        return events_max - parser.event_count;
    }

    fn container_push(parser: *Parser, container: Container) void {
        assert(parser.container_count < depth_max);
        parser.containers[parser.container_count] = container;
        parser.container_count += 1;
    }

    fn container_top(parser: *Parser) ?*Container {
        if (parser.container_count == 0) return null;
        return &parser.containers[parser.container_count - 1];
    }

    /// Copies bytes into the text buffer, and returns the mutable copy.
    fn text_add(parser: *Parser, bytes: []const u8) []u8 {
        assert(bytes.len <= source_size_max - parser.text_count);
        const target = parser.storage.text[parser.text_count..][0..bytes.len];
        @memcpy(target, bytes);
        parser.text_count += @intCast(bytes.len);
        return target;
    }

    fn inlines_add(parser: *Parser, text: []u8) void {
        if (parser.events_free() < 2 * events_reserve) {
            parser.truncated = true;
            return;
        }
        const free = parser.events_free() - events_reserve;
        const result = inline_parser.parse(.{
            .text = text,
            .tokens = &parser.storage.tokens,
            .definitions = parser.storage.definitions[0..parser.definition_count],
            .footnotes = parser.storage.footnotes[0..parser.footnote_definition_count],
            .footnote_count = &parser.footnote_count,
            .events = parser.storage.events[parser.event_count..][0..free],
        });
        parser.event_count += result.event_count;
        parser.word_count += result.word_count;
        if (result.truncated) parser.truncated = true;
    }

    /// Matches the open containers against the start of the line. Returns how many containers
    /// the line continues, and the line with their prefixes removed.
    fn containers_match(parser: *Parser, line: []const u8) struct { count: u32, rest: []const u8 } {
        var rest = line;
        var count: u32 = 0;
        while (count < parser.container_count) : (count += 1) {
            const indent = indent_of(rest);
            switch (parser.containers[count]) {
                .blockquote => {
                    if (indent.columns >= 4) break;
                    if (indent.bytes == rest.len or rest[indent.bytes] != '>') break;
                    rest = rest[indent.bytes + 1 ..];
                    if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
                },
                // A list continues as long as one of its items does, which the item decides.
                .list => {},
                .item => |item| {
                    if (is_blank(rest)) continue;
                    if (indent.columns < item.content_indent) break;
                    rest = columns_skip(rest, item.content_indent);
                },
                .footnote => {
                    if (is_blank(rest)) continue;
                    if (indent.columns < footnote_indent) break;
                    rest = columns_skip(rest, footnote_indent);
                },
            }
        }
        assert(count <= parser.container_count);
        return .{ .count = count, .rest = rest };
    }

    fn containers_close(parser: *Parser, count_target: u32) void {
        assert(count_target <= parser.container_count);
        assert(parser.leaf == .none);
        while (parser.container_count > count_target) {
            parser.container_count -= 1;
            switch (parser.containers[parser.container_count]) {
                .blockquote => parser.event_add(.blockquote_end),
                .list => parser.event_add(.list_end),
                .item => parser.event_add(.item_end),
                .footnote => |footnote| {
                    parser.event_add(.footnote_end);
                    if (footnote) |index| {
                        parser.storage.footnotes[index].event_end = parser.event_count;
                    }
                },
            }
        }
    }

    /// A list whose last item was closed stays open until the next line shows whether it gets
    /// another item. This closes it when it did not.
    fn list_dangling_close(parser: *Parser) void {
        const top = parser.container_top() orelse return;
        if (top.* != .list) return;
        parser.containers_close(parser.container_count - 1);
        assert(parser.container_top() == null or parser.container_top().?.* != .list);
    }

    /// Opens the containers that start on this line. Returns the line after their markers.
    fn containers_open(parser: *Parser, line: []const u8) []const u8 {
        var rest = line;
        var iterations: u32 = 0;
        parser.quote_opened = false;
        while (iterations < depth_max) : (iterations += 1) {
            if (parser.container_count + 2 > depth_max) break;
            // Only a dangling list can be open when the line is at the top level.
            const top_level = parser.container_count == 0 or
                (parser.container_count == 1 and parser.containers[0] == .list);
            if (top_level and iterations == 0) {
                if (footnote_definition_match(rest)) |definition| {
                    parser.leaf_close();
                    parser.list_dangling_close();
                    parser.footnote_open(definition.label);
                    rest = std.mem.trimStart(u8, rest[definition.content_offset..], " \t");
                    continue;
                }
            }
            const indent = indent_of(rest);
            if (indent.columns >= 4) break;
            const content = rest[indent.bytes..];
            if (content.len > 0 and content[0] == '>') {
                parser.leaf_close();
                parser.list_dangling_close();
                parser.container_push(.blockquote);
                parser.event_add(.{ .blockquote_start = .none });
                parser.quote_opened = true;
                rest = content[1..];
                if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
                continue;
            }
            if (thematic_break_match(content)) break;
            const marker = list_marker_match(content) orelse break;
            if (parser.leaf == .paragraph) {
                // Only a non-empty item that starts at 1 can interrupt a paragraph.
                if (marker.empty) break;
                if (marker.ordered and marker.start != 1) break;
            }
            parser.leaf_close();
            parser.item_open(marker, indent.columns);
            parser.quote_opened = false;
            rest = content[marker.content_offset..];
        }
        return rest;
    }

    /// Opens a footnote definition. Definitions are only at the top level, so they never nest.
    fn footnote_open(parser: *Parser, label: []const u8) void {
        assert(parser.container_count == 0);
        assert(parser.leaf == .none);
        const footnotes = parser.storage.footnotes[0..parser.footnote_definition_count];
        var owner: ?u32 = inline_parser.footnote_find(footnotes, label);
        if (owner) |index| {
            // Only the first definition of a label is shown.
            if (footnotes[index].event_end != 0) owner = null;
        }
        if (owner) |index| footnotes[index].event_start = parser.event_count;
        parser.container_push(.{ .footnote = owner });
        parser.event_add(.{ .footnote_start = 0 });
    }

    fn item_open(parser: *Parser, marker: Marker, indent_columns: u32) void {
        assert(parser.leaf == .none);
        assert(parser.container_count + 2 <= depth_max);
        if (parser.container_top()) |top| {
            if (top.* == .list) {
                const compatible = top.list.ordered == marker.ordered and
                    top.list.marker == marker.marker;
                if (!compatible) parser.list_dangling_close();
            }
        }
        const list_open = if (parser.container_top()) |top| top.* == .list else false;
        if (!list_open) {
            parser.container_push(.{ .list = .{
                .ordered = marker.ordered,
                .marker = marker.marker,
                .event_index = parser.event_count,
            } });
            parser.event_add(.{ .list_start = .{
                .ordered = marker.ordered,
                .start = marker.start,
                .tight = true,
            } });
        }
        parser.container_push(.{ .item = .{
            .content_indent = indent_columns + marker.content_columns,
            .event_index = parser.event_count,
            .child_count = 0,
        } });
        parser.event_add(.{ .item_start = .none });
    }

    /// Marks the innermost open list as loose when a blank line preceded this block.
    fn looseness_update(parser: *Parser) void {
        if (!parser.blank_pending) return;
        parser.blank_pending = false;
        var index = parser.container_count;
        while (index > 0) {
            index -= 1;
            switch (parser.containers[index]) {
                .list => |list| {
                    if (list.event_index >= parser.blank_event_count) return;
                    parser.storage.events[list.event_index].list_start.tight = false;
                    return;
                },
                else => {},
            }
        }
    }

    fn line_process(parser: *Parser, line: []const u8) void {
        const match = parser.containers_match(line);
        const matched_all = match.count == parser.container_count;
        if (parser.leaf == .fenced) {
            if (matched_all) return parser.fenced_line(match.rest);
            parser.leaf_close();
        }
        if (parser.leaf == .comment) {
            if (matched_all) {
                if (std.mem.indexOf(u8, match.rest, "-->") != null) parser.leaf_close();
                return;
            }
            parser.leaf_close();
        }
        const blank = is_blank(match.rest);
        if (!matched_all) {
            if (parser.leaf == .paragraph and !blank and !block_start_match(match.rest, false)) {
                // Lazy continuation: the paragraph goes on without its container prefixes.
                return parser.paragraph_line_add(std.mem.trimStart(u8, match.rest, " \t"));
            }
            parser.leaf_close();
            parser.containers_close(match.count);
        }
        if (blank) return parser.blank_process();

        const rest = parser.containers_open(match.rest);
        parser.list_dangling_close();
        parser.looseness_update();
        if (parser.quote_opened) {
            if (alert_match(rest)) |alert| {
                // The marker line is not shown: it only sets the kind of the quote.
                assert(parser.storage.events[parser.event_count - 1] == .blockquote_start);
                parser.storage.events[parser.event_count - 1] = .{ .blockquote_start = alert };
                return;
            }
        }
        parser.leaf_process(rest);
    }

    fn blank_process(parser: *Parser) void {
        switch (parser.leaf) {
            .paragraph, .table => parser.leaf_close(),
            .indented_code => |*code| code.blank_count += 1,
            .none => {},
            .fenced, .comment => unreachable,
        }
        for (parser.containers[0..parser.container_count]) |container| {
            if (container == .item and !parser.blank_pending) {
                parser.blank_pending = true;
                parser.blank_event_count = parser.event_count;
            }
        }
    }

    fn fenced_line(parser: *Parser, line: []const u8) void {
        const fenced = parser.leaf.fenced;
        const indent = indent_of(line);
        if (indent.columns < 4) {
            const content = std.mem.trimEnd(u8, line[indent.bytes..], " \t");
            const run = run_length(content, fenced.marker);
            if (run >= fenced.length and run == content.len) return parser.leaf_close();
        }
        parser.event_add(.{ .code_line = columns_skip(line, @min(indent.columns, fenced.indent)) });
    }

    fn leaf_process(parser: *Parser, line: []const u8) void {
        if (is_blank(line)) return;
        const indent = indent_of(line);
        if (parser.leaf == .indented_code) {
            if (indent.columns >= 4) return parser.indented_code_line(line);
            parser.leaf_close();
        }
        if (parser.leaf == .table) {
            if (!block_start_match(line, true)) return parser.table_row(line, false);
            parser.leaf_close();
        }
        const content = line[indent.bytes..];
        if (indent.columns >= 4) {
            if (parser.leaf == .paragraph) return parser.paragraph_line_add(content);
            parser.event_add(.{ .code_block_start = "" });
            parser.leaf = .{ .indented_code = .{ .blank_count = 0 } };
            return parser.indented_code_line(line);
        }
        if (parser.leaf == .paragraph) {
            if (setext_match(content)) |level| {
                parser.leaf.paragraph.heading_level = level;
                return parser.leaf_close();
            }
            if (parser.table_open(content)) return;
        }
        if (parser.leaf == .none and std.mem.startsWith(u8, content, "<!--")) {
            // The comment runs to the line that contains `-->`, which can be this one.
            if (std.mem.indexOf(u8, content, "-->") == null) parser.leaf = .comment;
            return;
        }
        if (atx_match(content)) |heading| {
            parser.leaf_close();
            _ = parser.child_note();
            parser.event_add(.{ .heading_start = heading.level });
            parser.inlines_add(parser.text_add(heading.content));
            return parser.event_add(.heading_end);
        }
        if (fence_open_match(content)) |fence| {
            parser.leaf_close();
            _ = parser.child_note();
            parser.event_add(.{ .code_block_start = fence.info });
            parser.leaf = .{ .fenced = .{
                .marker = fence.marker,
                .length = fence.length,
                .indent = indent.columns,
            } };
            return;
        }
        if (thematic_break_match(content)) {
            parser.leaf_close();
            _ = parser.child_note();
            return parser.event_add(.thematic_break);
        }
        parser.paragraph_line_add(content);
    }

    /// Counts a block as a child of the innermost item, and returns whether it is the first.
    fn child_note(parser: *Parser) bool {
        const top = parser.container_top() orelse return false;
        if (top.* != .item) return false;
        top.item.child_count += 1;
        return top.item.child_count == 1;
    }

    fn indented_code_line(parser: *Parser, line: []const u8) void {
        const code = &parser.leaf.indented_code;
        assert(code.blank_count <= events_max);
        // Blank lines belong to the block only when more code follows them.
        while (code.blank_count > 0 and parser.events_free() > events_reserve) {
            parser.event_add(.{ .code_line = "" });
            code.blank_count -= 1;
        }
        code.blank_count = 0;
        parser.event_add(.{ .code_line = columns_skip(line, 4) });
    }

    fn paragraph_line_add(parser: *Parser, content: []const u8) void {
        if (parser.leaf != .paragraph) {
            assert(parser.leaf == .none);
            // Link reference definitions were collected up front, and they render as nothing.
            if (definition_match(content) != null) return;
            parser.leaf = .{ .paragraph = .{
                .text_start = parser.text_count,
                .line_count = 0,
                .heading_level = 0,
                .first_in_item = parser.child_note(),
            } };
        }
        const paragraph = &parser.leaf.paragraph;
        if (paragraph.line_count > 0) _ = parser.text_add("\n");
        _ = parser.text_add(content);
        paragraph.line_count += 1;
    }

    fn leaf_close(parser: *Parser) void {
        switch (parser.leaf) {
            .none, .comment => {},
            .paragraph => |paragraph| {
                parser.leaf = .none;
                parser.paragraph_close(
                    paragraph.text_start,
                    paragraph.heading_level,
                    paragraph.first_in_item,
                );
            },
            .fenced, .indented_code => parser.event_add(.code_block_end),
            .table => parser.event_add(.table_end),
        }
        parser.leaf = .none;
    }

    fn paragraph_close(
        parser: *Parser,
        text_start: u32,
        heading_level: u8,
        first_in_item: bool,
    ) void {
        assert(text_start <= parser.text_count);
        assert(heading_level <= 2);
        var text: []u8 = parser.storage.text[text_start..parser.text_count];
        text = text[0..std.mem.trimEnd(u8, text, " \t\n").len];
        if (heading_level > 0) {
            parser.event_add(.{ .heading_start = heading_level });
            parser.inlines_add(text);
            return parser.event_add(.heading_end);
        }
        if (first_in_item and text.len >= 4 and text[0] == '[' and text[2] == ']' and
            text[3] == ' ' and (text[1] == ' ' or text[1] == 'x' or text[1] == 'X'))
        {
            const item = parser.container_top().?.item;
            parser.storage.events[item.event_index] =
                .{ .item_start = if (text[1] == ' ') .unchecked else .checked };
            text = text[4..];
        }
        parser.event_add(.paragraph_start);
        const event_count_text = parser.event_count;
        parser.inlines_add(text);
        // A paragraph that has only hidden HTML in it is not shown.
        if (parser.event_count == event_count_text) {
            parser.event_count -= 1;
            return;
        }
        parser.event_add(.paragraph_end);
    }

    /// Turns a one-line paragraph into a table header when `line` is a matching delimiter row.
    fn table_open(parser: *Parser, line: []const u8) bool {
        const paragraph = parser.leaf.paragraph;
        if (paragraph.line_count != 1) return false;
        var table: @FieldType(Leaf, "table") = .{ .column_count = 0, .aligns = undefined };
        table.column_count = table_delimiter_match(line, &table.aligns) orelse return false;
        const header: []u8 = parser.storage.text[paragraph.text_start..parser.text_count];
        var cells: CellIterator = .init(header);
        var header_count: u32 = 0;
        while (cells.next() != null) header_count += 1;
        if (header_count != table.column_count) return false;

        parser.leaf = .{ .table = table };
        parser.event_add(.{ .table_start = table.column_count });
        parser.table_row_emit(header, true);
        return true;
    }

    fn table_row(parser: *Parser, line: []const u8, header: bool) void {
        assert(parser.leaf == .table);
        parser.table_row_emit(parser.text_add(line), header);
    }

    fn table_row_emit(parser: *Parser, row: []u8, header: bool) void {
        const table = &parser.leaf.table;
        assert(table.column_count > 0);
        assert(table.column_count <= table_columns_max);
        parser.event_add(.{ .row_start = header });
        var cells: CellIterator = .init(row);
        for (table.aligns[0..table.column_count]) |cell_align| {
            parser.event_add(.{ .cell_start = cell_align });
            if (cells.next()) |cell| parser.inlines_add(cell);
            parser.event_add(.cell_end);
        }
        parser.event_add(.row_end);
    }

    /// Collects link reference definitions and footnote labels, so that references can find
    /// definitions that come later. A footnote definition starts at the first column.
    fn definitions_collect(parser: *Parser, source: []const u8) void {
        assert(parser.definition_count == 0);
        assert(parser.footnote_definition_count == 0);
        var fence: ?Fence = null;
        var comment = false;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            if (comment) {
                comment = std.mem.indexOf(u8, line, "-->") == null;
                continue;
            }
            const indent = indent_of(line);
            if (indent.columns >= 4) continue;
            const content = std.mem.trimEnd(u8, line[indent.bytes..], " \t\r");
            if (fence) |open| {
                const run = run_length(content, open.marker);
                if (run >= open.length and run == content.len) fence = null;
                continue;
            }
            if (fence_open_match(content)) |fence_open| {
                fence = fence_open;
                continue;
            }
            if (std.mem.startsWith(u8, content, "<!--")) {
                comment = std.mem.indexOf(u8, content, "-->") == null;
                continue;
            }
            if (footnote_definition_match(line)) |definition| {
                if (parser.footnote_definition_count == footnotes_max) continue;
                parser.storage.footnotes[parser.footnote_definition_count] = .{
                    .label = definition.label,
                };
                parser.footnote_definition_count += 1;
            } else if (definition_match(content)) |definition| {
                if (parser.definition_count == definitions_max) continue;
                parser.storage.definitions[parser.definition_count] = definition;
                parser.definition_count += 1;
            }
        }
    }

    /// Emits YAML front matter as a code block. Returns the size of the front matter in bytes.
    fn front_matter_add(parser: *Parser, source: []const u8) usize {
        assert(parser.event_count == 0);
        var lines = std.mem.splitScalar(u8, source, '\n');
        const first = lines.first();
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, first, "\r"), "---")) return 0;
        const body_start = lines.index orelse return 0;
        // Without a closing line there is no front matter.
        const body_end = while (lines.next()) |line| {
            const content = std.mem.trimEnd(u8, line, "\r");
            if (std.mem.eql(u8, content, "---") or std.mem.eql(u8, content, "...")) {
                break @intFromPtr(line.ptr) - @intFromPtr(source.ptr);
            }
        } else return 0;
        const end = lines.index orelse source.len;
        assert(body_start <= body_end);
        assert(body_end < end);

        parser.event_add(.{ .code_block_start = "yaml" });
        var body = std.mem.splitScalar(u8, source[body_start..body_end], '\n');
        while (body.next()) |line| {
            if (body.index == null and line.len == 0) break;
            if (parser.events_free() < 4 * events_reserve) {
                parser.truncated = true;
                break;
            }
            parser.event_add(.{ .code_line = std.mem.trimEnd(u8, line, "\r") });
        }
        parser.event_add(.code_block_end);
        return end;
    }

    /// Moves the definitions of referenced footnotes to the end, in number order, below a rule.
    /// Definitions without a reference are dropped.
    fn footnotes_finish(parser: *Parser) void {
        assert(parser.container_count == 0);
        assert(parser.footnote_count <= parser.footnote_definition_count);
        const events = &parser.storage.events;
        const footnotes = parser.storage.footnotes[0..parser.footnote_definition_count];
        const body_end = parser.event_count;
        var number: u32 = 1;
        while (number <= parser.footnote_count) : (number += 1) {
            const footnote = for (footnotes) |*footnote| {
                if (footnote.number == number) break footnote;
            } else unreachable;
            if (footnote.event_end == 0) continue;
            assert(events[footnote.event_start] == .footnote_start);
            assert(events[footnote.event_end - 1] == .footnote_end);
            const inner = events[footnote.event_start + 1 .. footnote.event_end - 1];
            if (parser.events_free() < inner.len + 3) {
                parser.truncated = true;
                break;
            }
            if (parser.event_count == body_end) parser.event_add(.thematic_break);
            parser.event_add(.{ .footnote_start = number });
            @memcpy(events[parser.event_count..][0..inner.len], inner);
            parser.event_count += @intCast(inner.len);
            parser.event_add(.footnote_end);
        }
        // Remove the definitions from where they were written.
        var write: u32 = 0;
        var read: u32 = 0;
        while (read < body_end) {
            if (events[read] == .footnote_start) {
                while (events[read] != .footnote_end) read += 1;
                read += 1;
                continue;
            }
            events[write] = events[read];
            write += 1;
            read += 1;
        }
        assert(read == body_end);
        std.mem.copyForwards(Event, events[write..], events[body_end..parser.event_count]);
        parser.event_count = write + (parser.event_count - body_end);
    }
};

pub fn parse(storage: *Storage, source: []const u8) Result {
    assert(source.len <= source_size_max);
    var parser: Parser = .{ .storage = storage };
    var line_start = parser.front_matter_add(source);
    parser.definitions_collect(source[line_start..]);

    while (line_start < source.len) {
        if (parser.events_free() < 4 * events_reserve) {
            parser.truncated = true;
            break;
        }
        const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        const line = std.mem.trimEnd(u8, source[line_start..line_end], "\r");
        parser.line_process(line);
        line_start = line_end + 1;
    }
    parser.leaf_close();
    parser.containers_close(0);
    parser.footnotes_finish();

    assert(parser.container_count == 0);
    assert(parser.event_count <= events_max);
    return .{
        .events = storage.events[0..parser.event_count],
        .truncated = parser.truncated,
        .word_count = parser.word_count,
    };
}

fn is_blank(line: []const u8) bool {
    for (line) |byte| {
        if (byte != ' ' and byte != '\t') return false;
    }
    return true;
}

/// Leading whitespace of the line. A tab advances to the next multiple of four columns.
fn indent_of(line: []const u8) Indent {
    var indent: Indent = .{ .columns = 0, .bytes = 0 };
    for (line) |byte| {
        switch (byte) {
            ' ' => indent.columns += 1,
            '\t' => indent.columns += 4 - indent.columns % 4,
            else => break,
        }
        indent.bytes += 1;
    }
    assert(indent.bytes <= line.len);
    return indent;
}

/// Removes leading whitespace up to the given number of columns.
fn columns_skip(line: []const u8, columns: u32) []const u8 {
    var indent: Indent = .{ .columns = 0, .bytes = 0 };
    for (line) |byte| {
        if (indent.columns >= columns) break;
        switch (byte) {
            ' ' => indent.columns += 1,
            '\t' => indent.columns += 4 - indent.columns % 4,
            else => break,
        }
        indent.bytes += 1;
    }
    return line[indent.bytes..];
}

fn run_length(line: []const u8, byte: u8) u32 {
    var length: u32 = 0;
    while (length < line.len and line[length] == byte) length += 1;
    return length;
}

fn thematic_break_match(line: []const u8) bool {
    if (line.len == 0) return false;
    const marker = line[0];
    if (marker != '-' and marker != '*' and marker != '_') return false;
    var count: u32 = 0;
    for (line) |byte| {
        if (byte == marker) {
            count += 1;
        } else if (byte != ' ' and byte != '\t') {
            return false;
        }
    }
    return count >= 3;
}

fn setext_match(line: []const u8) ?u8 {
    const content = std.mem.trimEnd(u8, line, " \t");
    if (content.len == 0) return null;
    if (content[0] != '=' and content[0] != '-') return null;
    if (run_length(content, content[0]) != content.len) return null;
    return if (content[0] == '=') 1 else 2;
}

fn atx_match(line: []const u8) ?struct { level: u8, content: []const u8 } {
    const level = run_length(line, '#');
    if (level == 0 or level > 6) return null;
    if (level < line.len and line[level] != ' ' and line[level] != '\t') return null;
    var content = std.mem.trim(u8, line[level..], " \t");
    // A closing run of '#' is decoration when a space precedes it.
    const closing_start = std.mem.trimEnd(u8, content, "#").len;
    if (closing_start == 0) {
        content = content[0..0];
    } else if (closing_start < content.len and content[closing_start - 1] == ' ') {
        content = std.mem.trimEnd(u8, content[0..closing_start], " \t");
    }
    return .{ .level = @intCast(level), .content = content };
}

fn fence_open_match(line: []const u8) ?Fence {
    if (line.len < 3) return null;
    const marker = line[0];
    if (marker != '`' and marker != '~') return null;
    const length = run_length(line, marker);
    if (length < 3) return null;
    const info = std.mem.trim(u8, line[length..], " \t");
    if (marker == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    return .{ .marker = marker, .length = length, .info = info };
}

fn list_marker_match(line: []const u8) ?Marker {
    if (line.len == 0) return null;
    var marker: Marker = .{
        .ordered = false,
        .start = 1,
        .marker = line[0],
        .content_offset = 0,
        .content_columns = 0,
        .empty = false,
    };
    var width: u32 = 1;
    if (std.ascii.isDigit(line[0])) {
        var digits: u32 = 0;
        marker.start = 0;
        while (digits < line.len and digits < 9 and std.ascii.isDigit(line[digits])) {
            marker.start = marker.start * 10 + (line[digits] - '0');
            digits += 1;
        }
        if (digits == line.len) return null;
        if (line[digits] != '.' and line[digits] != ')') return null;
        marker.ordered = true;
        marker.marker = line[digits];
        width = digits + 1;
    } else if (line[0] != '-' and line[0] != '*' and line[0] != '+') {
        return null;
    }
    const after = line[width..];
    if (after.len > 0 and after[0] != ' ' and after[0] != '\t') return null;
    const indent = indent_of(after);
    marker.empty = indent.bytes == after.len;
    if (marker.empty or indent.columns > 4) {
        // The content starts one column after the marker, and the rest is content.
        marker.content_offset = width + @min(1, @as(u32, @intCast(after.len)));
        marker.content_columns = width + 1;
    } else {
        marker.content_offset = width + indent.bytes;
        marker.content_columns = width + indent.columns;
    }
    assert(marker.content_offset <= line.len);
    return marker;
}

/// Matches the first line of a GFM alert, such as `[!NOTE]`, in any letter case.
fn alert_match(line: []const u8) ?Alert {
    const content = std.mem.trimEnd(u8, line, " ");
    if (content.len < 4 or content[0] != '[' or content[1] != '!') return null;
    if (content[content.len - 1] != ']') return null;
    const name = content[2 .. content.len - 1];
    for (std.enums.values(Alert)[1..]) |alert| {
        if (std.ascii.eqlIgnoreCase(name, @tagName(alert))) return alert;
    }
    return null;
}

/// Whether the line starts a block that ends the open paragraph or table. When the block would
/// be a sibling of the paragraph, only a non-empty list item that starts at 1 interrupts it.
fn block_start_match(line: []const u8, sibling: bool) bool {
    const indent = indent_of(line);
    if (indent.columns >= 4) return false;
    const content = line[indent.bytes..];
    if (content.len == 0) return false;
    if (indent.bytes == 0 and footnote_definition_match(content) != null) return true;
    if (content[0] == '>') return true;
    if (thematic_break_match(content)) return true;
    if (atx_match(content) != null) return true;
    if (fence_open_match(content) != null) return true;
    if (list_marker_match(content)) |marker| {
        return !sibling or (!marker.empty and (!marker.ordered or marker.start == 1));
    }
    return false;
}

/// Splits a table row at unescaped pipes. The outer pipes are optional.
const CellIterator = struct {
    row: []u8,
    position: usize,

    fn init(row: []u8) CellIterator {
        const trimmed = std.mem.trim(u8, row, " \t");
        const offset = @intFromPtr(trimmed.ptr) - @intFromPtr(row.ptr);
        var inner: []u8 = row[offset..][0..trimmed.len];
        if (inner.len > 0 and inner[0] == '|') inner = inner[1..];
        if (inner.len > 0 and inner[inner.len - 1] == '|') {
            const escaped = inner.len >= 2 and inner[inner.len - 2] == '\\';
            if (!escaped) inner = inner[0 .. inner.len - 1];
        }
        return .{ .row = inner, .position = 0 };
    }

    fn next(cells: *CellIterator) ?[]u8 {
        if (cells.position > cells.row.len) return null;
        const start = cells.position;
        var end = start;
        while (end < cells.row.len and cells.row[end] != '|') {
            end += if (cells.row[end] == '\\' and end + 1 < cells.row.len) 2 else 1;
        }
        end = @min(end, cells.row.len);
        cells.position = end + 1;
        const cell = std.mem.trim(u8, cells.row[start..end], " \t");
        const offset = @intFromPtr(cell.ptr) - @intFromPtr(cells.row.ptr);
        return cells.row[offset..][0..cell.len];
    }
};

/// Matches a table delimiter row such as `| :--- | ---: |`. Returns the column count.
fn table_delimiter_match(line: []const u8, aligns: *[table_columns_max]Align) ?u8 {
    if (std.mem.indexOfScalar(u8, line, '-') == null) return null;
    if (std.mem.indexOfNone(u8, line, "|-: \t") != null) return null;
    var content = std.mem.trim(u8, line, " \t");
    if (content.len > 0 and content[0] == '|') content = content[1..];
    if (content.len > 0 and content[content.len - 1] == '|') {
        content = content[0 .. content.len - 1];
    }
    var count: u8 = 0;
    var cells = std.mem.splitScalar(u8, content, '|');
    while (cells.next()) |cell_raw| {
        if (count == table_columns_max) return null;
        const cell = std.mem.trim(u8, cell_raw, " \t");
        if (cell.len == 0) return null;
        const left = cell[0] == ':';
        const right = cell.len > 1 and cell[cell.len - 1] == ':';
        const dashes = cell[@intFromBool(left) .. cell.len - @intFromBool(right)];
        if (dashes.len == 0 or run_length(dashes, '-') != dashes.len) return null;
        aligns[count] = if (left and right) .center else if (left) .left else if (right)
            .right
        else
            .default;
        count += 1;
    }
    // A lone `---` is a setext underline or a thematic break, not a table.
    if (count == 1 and std.mem.indexOfScalar(u8, line, '|') == null) return null;
    return count;
}

/// Footnote definitions continue on lines indented by this many columns.
const footnote_indent = 4;

/// Matches `[^label]:` at the start of a line. Returns the label, and where the content starts.
fn footnote_definition_match(line: []const u8) ?struct { label: []const u8, content_offset: u32 } {
    const label = inline_parser.footnote_label_match(line) orelse return null;
    const label_end: u32 = @intCast(label.len + "[^]".len);
    if (label_end >= line.len or line[label_end] != ':') return null;
    return .{ .label = label, .content_offset = label_end + 1 };
}

/// Matches `[label]: destination "optional title"`.
fn definition_match(line: []const u8) ?Definition {
    if (line.len < 4 or line[0] != '[') return null;
    const label_end = std.mem.indexOfScalar(u8, line, ']') orelse return null;
    if (label_end < 2 or label_end + 1 >= line.len or line[label_end + 1] != ':') return null;
    if (line[1] == '^') return null;
    var rest = std.mem.trim(u8, line[label_end + 2 ..], " \t");
    if (rest.len == 0) return null;
    if (rest[0] == '<') {
        const close = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
        rest = rest[1..close];
    } else {
        rest = rest[0 .. std.mem.indexOfAny(u8, rest, " \t") orelse rest.len];
    }
    return .{ .label = std.mem.trim(u8, line[1..label_end], " \t"), .destination = rest };
}

test {
    _ = @import("markdown_test.zig");
    _ = inline_parser;
}
