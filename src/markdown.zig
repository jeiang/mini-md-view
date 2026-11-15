//! Markdown parser: source bytes to a flat stream of events.
//!
//! The parser handles the CommonMark block structure (containers and leaf blocks) plus the GFM
//! tables, task lists, strikethrough and autolink extensions. HTML is not interpreted: it is
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

/// Events that one line can emit outside of inline content: closing and opening every container,
/// a leaf block, and one table row.
const events_reserve = 4 * depth_max + 2 * table_columns_max + 16;
comptime {
    assert(events_reserve * 4 < events_max);
}

pub const Align = enum(u8) { default, left, center, right };
pub const Task = enum(u8) { none, unchecked, checked };
pub const List = struct { ordered: bool, start: u32, tight: bool };

pub const Event = union(enum) {
    blockquote_start,
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

    text: []const u8,
    code: []const u8,
    soft_break,
    hard_break,
    emphasis_start,
    emphasis_end,
    strong_start,
    strong_end,
    strike_start,
    strike_end,
    /// Payload is the link destination.
    link_start: []const u8,
    link_end,
    /// Payload is the image source. The events up to `image_end` are the alternative text.
    image_start: []const u8,
    image_end,
};

pub const Definition = struct { label: []const u8, destination: []const u8 };

pub const Storage = struct {
    events: [events_max]Event,
    /// Paragraph text, copied from the source with container prefixes removed. Inline events
    /// point into this buffer. It never needs more bytes than the source has.
    text: [source_size_max]u8,
    tokens: [tokens_max]inline_parser.Token,
    definitions: [definitions_max]Definition,
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
};

const Leaf = union(enum) {
    none,
    paragraph: struct { text_start: u32, line_count: u32, heading_level: u8, first_in_item: bool },
    fenced: struct { marker: u8, length: u32, indent: u32 },
    indented_code: struct { blank_count: u32 },
    table: struct { column_count: u8, aligns: [table_columns_max]Align },
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
    word_count: u32 = 0,
    truncated: bool = false,
    containers: [depth_max]Container = undefined,
    container_count: u32 = 0,
    leaf: Leaf = .none,
    /// A blank line was seen inside a list. The next block decides whether that list is loose.
    blank_pending: bool = false,
    /// The event count at that blank line. Lists that were opened later are not affected.
    blank_event_count: u32 = 0,

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
            parser.event_add(switch (parser.containers[parser.container_count]) {
                .blockquote => .blockquote_end,
                .list => .list_end,
                .item => .item_end,
            });
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
        while (iterations < depth_max) : (iterations += 1) {
            if (parser.container_count + 2 > depth_max) break;
            const indent = indent_of(rest);
            if (indent.columns >= 4) break;
            const content = rest[indent.bytes..];
            if (content.len > 0 and content[0] == '>') {
                parser.leaf_close();
                parser.list_dangling_close();
                parser.container_push(.blockquote);
                parser.event_add(.blockquote_start);
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
            rest = content[marker.content_offset..];
        }
        return rest;
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
        parser.leaf_process(rest);
    }

    fn blank_process(parser: *Parser) void {
        switch (parser.leaf) {
            .paragraph, .table => parser.leaf_close(),
            .indented_code => |*code| code.blank_count += 1,
            .none => {},
            .fenced => unreachable,
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
            .none => {},
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
        parser.inlines_add(text);
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

    /// Collects link reference definitions, so that links can refer to later definitions.
    fn definitions_collect(parser: *Parser, source: []const u8) void {
        assert(parser.definition_count == 0);
        var fence_marker: u8 = 0;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            if (parser.definition_count == definitions_max) break;
            const indent = indent_of(line);
            if (indent.columns >= 4) continue;
            const content = line[indent.bytes..];
            if (fence_open_match(content)) |fence| {
                if (fence_marker == 0) {
                    fence_marker = fence.marker;
                } else if (fence_marker == fence.marker) {
                    fence_marker = 0;
                }
                continue;
            }
            if (fence_marker != 0) continue;
            if (definition_match(std.mem.trimEnd(u8, content, " \t\r"))) |definition| {
                parser.storage.definitions[parser.definition_count] = definition;
                parser.definition_count += 1;
            }
        }
    }
};

pub fn parse(storage: *Storage, source: []const u8) Result {
    assert(source.len <= source_size_max);
    var parser: Parser = .{ .storage = storage };
    parser.definitions_collect(source);

    var line_start: usize = 0;
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

/// Whether the line starts a block that ends the open paragraph or table. When the block would
/// be a sibling of the paragraph, only a non-empty list item that starts at 1 interrupts it.
fn block_start_match(line: []const u8, sibling: bool) bool {
    const indent = indent_of(line);
    if (indent.columns >= 4) return false;
    const content = line[indent.bytes..];
    if (content.len == 0) return false;
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
