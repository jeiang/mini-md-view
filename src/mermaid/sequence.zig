//! Mermaid sequence diagrams: participants with lifelines, messages, notes, activations, and
//! block frames such as `loop` and `alt`.
//!
//! Layout runs in three passes over the parsed events. The first finds the minimum distance
//! between every pair of columns from the labels that sit between them, and places the columns.
//! The second finds the horizontal extent of every block frame. The third walks down the page and
//! emits commands. Lifelines, activation bars, and backgrounds must sit under the messages drawn
//! later, so their command slots are reserved up front and filled once their extent is known.

const std = @import("std");
const assert = std.debug.assert;
const scene = @import("../scene.zig");

const participants_max = 32;
const events_max = 2048;
const blocks_max = 256;
const boxes_max = 16;
const depth_max = 16;
const activation_depth_max = 8;
const source_length_max = 1 << 24;
const box_none = std.math.maxInt(u32);

const participant_padding_x = 16;
const participant_padding_y = 10;
const participant_width_min = 88;
const participant_gap = 40;
const participant_radius = 4;
const actor_figure_width = 32;
const actor_figure_height = 40;
const actor_label_gap = 4;
const box_padding = 12;
const box_label_gap = 8;
const title_gap = 16;
const message_padding = 16;
const message_text_gap = 4;
const event_gap = 14;
const self_width = 34;
const self_height = 22;
const note_padding_x = 10;
const note_padding_y = 7;
const note_gap = 10;
const note_overhang = 14;
const frame_margin = 12;
const frame_gap = 12;
const frame_tab_padding = 8;
const frame_tab_notch = 6;
const frame_header_height_min = 22;
const frame_label_gap = 8;
const bar_width = 10;
const bar_offset = 5;
const bar_height_min = 10;
const badge_radius = 9;
const lifeline_end_gap = 16;

comptime {
    assert(bar_offset < bar_width);
    assert(participant_gap > 2 * box_padding);
    assert(note_gap < note_overhang);
    assert(events_max <= std.math.maxInt(u16));
}

const ParticipantKind = enum { participant, actor };

const Participant = struct {
    id: []const u8,
    label: []const u8,
    kind: ParticipantKind,
    box: u32 = box_none,
};

const Box = struct { label: []const u8 };

const Arrow = struct {
    dash: scene.Dash,
    head_start: scene.Head,
    head_end: scene.Head,
};

/// Arrow tokens, longest first wherever one token is a prefix of another.
const arrows = [_]struct { token: []const u8, arrow: Arrow }{
    .{ .token = "<<-->>", .arrow = .{ .dash = .dashed, .head_start = .arrow, .head_end = .arrow } },
    .{ .token = "<<->>", .arrow = .{ .dash = .solid, .head_start = .arrow, .head_end = .arrow } },
    .{ .token = "-->>", .arrow = .{ .dash = .dashed, .head_start = .none, .head_end = .arrow } },
    .{ .token = "--x", .arrow = .{ .dash = .dashed, .head_start = .none, .head_end = .cross } },
    .{ .token = "--)", .arrow = .{
        .dash = .dashed,
        .head_start = .none,
        .head_end = .arrow_open,
    } },
    .{ .token = "-->", .arrow = .{ .dash = .dashed, .head_start = .none, .head_end = .none } },
    .{ .token = "->>", .arrow = .{ .dash = .solid, .head_start = .none, .head_end = .arrow } },
    .{ .token = "-x", .arrow = .{ .dash = .solid, .head_start = .none, .head_end = .cross } },
    .{ .token = "-)", .arrow = .{ .dash = .solid, .head_start = .none, .head_end = .arrow_open } },
    .{ .token = "->", .arrow = .{ .dash = .solid, .head_start = .none, .head_end = .none } },
};

const Message = struct {
    from: u32,
    to: u32,
    text: []const u8,
    arrow: Arrow,
    activate_target: bool,
    deactivate_source: bool,
    /// Zero when autonumbering is off.
    number: u32,
};

const NotePlacement = enum { left, right, over };

const Note = struct {
    placement: NotePlacement,
    first: u32,
    /// Equal to `first` unless the note spans participants (`over A,B`).
    last: u32,
    text: []const u8,
};

const BlockKind = enum { loop, alt, opt, par, critical, @"break", rect };

/// The keyword that separates sections of a block, if the block has sections.
fn block_divider_keyword(kind: BlockKind) ?[]const u8 {
    return switch (kind) {
        .alt => "else",
        .par => "and",
        .critical => "option",
        .loop, .opt, .@"break", .rect => null,
    };
}

const Block = struct { kind: BlockKind, label: []const u8 };

const Event = union(enum) {
    message: Message,
    note: Note,
    activate: u32,
    deactivate: u32,
    block_start: u32,
    block_divider: struct { block: u32, label: []const u8 },
    block_end: u32,
};

const Diagram = struct {
    title: []const u8 = "",
    participants: [participants_max]Participant = undefined,
    participant_count: u32 = 0,
    boxes: [boxes_max]Box = undefined,
    box_count: u32 = 0,
    blocks: [blocks_max]Block = undefined,
    block_count: u32 = 0,
    events: [events_max]Event = undefined,
    event_count: u32 = 0,
    /// The number of activation bars, which is known before layout so that their command slots
    /// can be reserved.
    activation_count: u32 = 0,
};

pub fn render(
    source: []const u8,
    measurer: scene.Measurer,
    scratch: []u8,
    out: *scene.Scene,
) scene.Error!void {
    assert(out.command_count == 0);
    if (source.len > source_length_max) return error.Overflow;
    var allocator_state = std.heap.FixedBufferAllocator.init(scratch);
    const allocator = allocator_state.allocator();
    const diagram = allocator.create(Diagram) catch return error.Overflow;
    diagram.* = .{};
    try parse(source, diagram);
    const layout = allocator.create(Layout) catch return error.Overflow;
    var canvas = Canvas.init(out, measurer);
    layout.* = .{ .diagram = diagram, .canvas = &canvas };
    try layout.run();
    canvas.finish();
    assert(out.size.width > 0);
    assert(out.size.height > 0);
}

/// Iterates over statements: one per line, trimmed, without blank lines, `%%` comments, or
/// accessibility statements, which do not affect the drawing.
const Lines = struct {
    source: []const u8,
    cursor: u32 = 0,

    fn next(lines: *Lines) ?[]const u8 {
        assert(lines.source.len <= source_length_max);
        // Every iteration consumes at least one byte, so the loop is bounded by the source length.
        while (lines.cursor < lines.source.len) {
            const start = lines.cursor;
            const end = std.mem.findScalarPos(u8, lines.source, start, '\n') orelse
                lines.source.len;
            assert(end >= start);
            lines.cursor = @intCast(end + 1);
            var line = std.mem.trim(u8, lines.source[start..end], " \t\r");
            if (std.mem.endsWith(u8, line, ";")) {
                line = std.mem.trimEnd(u8, line[0 .. line.len - 1], " \t");
            }
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "%%")) continue;
            if (std.mem.startsWith(u8, line, "accTitle")) continue;
            if (std.mem.startsWith(u8, line, "accDescr")) {
                const is_block = std.mem.findScalar(u8, line, '{') != null and
                    std.mem.findScalar(u8, line, '}') == null;
                if (is_block) lines.skip_past('}');
                continue;
            }
            return line;
        }
        return null;
    }

    fn skip_past(lines: *Lines, byte: u8) void {
        assert(lines.cursor <= lines.source.len + 1);
        if (lines.cursor >= lines.source.len) return;
        const index = std.mem.findScalarPos(u8, lines.source, lines.cursor, byte) orelse
            lines.source.len;
        lines.cursor = @intCast(index + 1);
        assert(lines.cursor > 0);
    }
};

/// Returns the rest of `line` when it starts with the keyword `word`, matched without regard to
/// case as Mermaid does, and followed by whitespace or the end of the line.
fn keyword_strip(line: []const u8, word: []const u8) ?[]const u8 {
    assert(line.len <= source_length_max);
    assert(word.len > 0);
    if (!std.ascii.startsWithIgnoreCase(line, word)) return null;
    const rest = line[word.len..];
    if (rest.len > 0 and rest[0] != ' ' and rest[0] != '\t') return null;
    return std.mem.trim(u8, rest, " \t");
}

fn quotes_strip(text: []const u8) []const u8 {
    assert(text.len <= source_length_max);
    const trimmed = std.mem.trim(u8, text, " \t");
    const quoted = trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"';
    const result = if (quoted) trimmed[1 .. trimmed.len - 1] else trimmed;
    assert(result.len <= text.len);
    return result;
}

const Open = union(enum) { box: u32, block: u32 };

const Parser = struct {
    diagram: *Diagram,
    stack: [depth_max]Open = undefined,
    stack_count: u32 = 0,
    box_open: u32 = box_none,
    autonumber: bool = false,
    number_next: u32 = 1,
    number_step: u32 = 1,

    fn event_add(parser: *Parser, event: Event) scene.Error!void {
        assert(parser.stack_count <= depth_max);
        const diagram = parser.diagram;
        assert(diagram.event_count <= events_max);
        if (diagram.event_count == events_max) return error.Overflow;
        diagram.events[diagram.event_count] = event;
        diagram.event_count += 1;
    }

    /// Returns the index of the participant with the given id, creating it on first use.
    fn participant_get(parser: *Parser, id_raw: []const u8) scene.Error!u32 {
        assert(parser.diagram.participant_count <= participants_max);
        const diagram = parser.diagram;
        const id = quotes_strip(id_raw);
        if (id.len == 0) return error.Syntax;
        for (diagram.participants[0..diagram.participant_count], 0..) |participant, index| {
            if (std.mem.eql(u8, participant.id, id)) return @intCast(index);
        }
        if (diagram.participant_count == participants_max) return error.Overflow;
        diagram.participants[diagram.participant_count] = .{
            .id = id,
            .label = id,
            .kind = .participant,
        };
        diagram.participant_count += 1;
        assert(diagram.participant_count <= participants_max);
        return diagram.participant_count - 1;
    }

    fn statement(parser: *Parser, line: []const u8) scene.Error!void {
        assert(parser.stack_count <= depth_max);
        assert(line.len > 0);
        if (std.ascii.startsWithIgnoreCase(line, "title")) {
            const rest = std.mem.trim(u8, line["title".len..], " \t");
            if (rest.len > 0 and rest[0] == ':') {
                parser.diagram.title = std.mem.trim(u8, rest[1..], " \t");
                return;
            }
            if (keyword_strip(line, "title")) |title| {
                parser.diagram.title = title;
                return;
            }
        }
        if (keyword_strip(line, "autonumber")) |rest| return parser.autonumber_parse(rest);
        if (keyword_strip(line, "create")) |rest| return parser.statement_declaration(rest);
        if (try parser.statement_declaration_maybe(line)) return;
        if (keyword_strip(line, "destroy") != null) return;
        if (keyword_strip(line, "box")) |rest| return parser.box_parse(rest);
        if (keyword_strip(line, "end") != null) {
            if (keyword_strip(line, "end").?.len > 0) return error.Syntax;
            return parser.end_parse();
        }
        if (keyword_strip(line, "activate")) |rest| {
            return parser.activation_add(.{ .activate = try parser.participant_get(rest) });
        }
        if (keyword_strip(line, "deactivate")) |rest| {
            return parser.event_add(.{ .deactivate = try parser.participant_get(rest) });
        }
        if (keyword_strip(line, "note")) |rest| return parser.note_parse(rest);
        if (try parser.block_parse_maybe(line)) return;
        const ignored = [_][]const u8{ "link", "links", "properties", "details" };
        for (ignored) |word| if (keyword_strip(line, word) != null) return;
        return parser.message_parse(line);
    }

    fn activation_add(parser: *Parser, event: Event) scene.Error!void {
        assert(event == .activate);
        parser.diagram.activation_count += 1;
        try parser.event_add(event);
    }

    fn statement_declaration(parser: *Parser, line: []const u8) scene.Error!void {
        if (line.len == 0) return error.Syntax;
        assert(line.len <= source_length_max);
        assert(parser.diagram.participant_count <= participants_max);
        if (!try parser.statement_declaration_maybe(line)) return error.Syntax;
    }

    /// Parses `participant A`, `participant A as Alias`, and the same with `actor`.
    fn statement_declaration_maybe(parser: *Parser, line: []const u8) scene.Error!bool {
        assert(line.len > 0);
        var kind: ParticipantKind = .participant;
        const rest = keyword_strip(line, "participant") orelse rest: {
            kind = .actor;
            break :rest keyword_strip(line, "actor") orelse return false;
        };
        var id = rest;
        var label: ?[]const u8 = null;
        if (std.mem.find(u8, rest, " as ")) |as_index| {
            id = rest[0..as_index];
            label = quotes_strip(rest[as_index + " as ".len ..]);
        }
        const index = try parser.participant_get(id);
        const participant = &parser.diagram.participants[index];
        participant.kind = kind;
        if (label) |text| participant.label = text;
        if (parser.box_open != box_none and participant.box == box_none) {
            participant.box = parser.box_open;
        }
        assert(participant.id.len > 0);
        return true;
    }

    fn autonumber_parse(parser: *Parser, rest: []const u8) scene.Error!void {
        assert(parser.number_step <= 999_999);
        if (std.ascii.eqlIgnoreCase(rest, "off")) {
            parser.autonumber = false;
            return;
        }
        parser.autonumber = true;
        var words = std.mem.tokenizeAny(u8, rest, " \t");
        if (words.next()) |start| {
            parser.number_next = std.fmt.parseInt(u32, start, 10) catch return error.Syntax;
        }
        if (words.next()) |step| {
            parser.number_step = std.fmt.parseInt(u32, step, 10) catch return error.Syntax;
        }
        if (words.next() != null) return error.Syntax;
        if (parser.number_next > 999_999 or parser.number_step > 999_999) return error.Overflow;
        assert(parser.autonumber);
    }

    fn box_parse(parser: *Parser, rest: []const u8) scene.Error!void {
        assert(parser.box_open == box_none or parser.stack_count > 0);
        if (parser.stack_count > 0) return error.Syntax;
        const diagram = parser.diagram;
        if (diagram.box_count == boxes_max) return error.Overflow;
        diagram.boxes[diagram.box_count] = .{ .label = quotes_strip(color_strip(rest)) };
        parser.box_open = diagram.box_count;
        diagram.box_count += 1;
        parser.stack[0] = .{ .box = parser.box_open };
        parser.stack_count = 1;
        assert(diagram.box_count <= boxes_max);
    }

    fn end_parse(parser: *Parser) scene.Error!void {
        assert(parser.stack_count <= depth_max);
        if (parser.stack_count == 0) return error.Syntax;
        parser.stack_count -= 1;
        switch (parser.stack[parser.stack_count]) {
            .box => |box| {
                assert(box == parser.box_open);
                parser.box_open = box_none;
            },
            .block => |block| try parser.event_add(.{ .block_end = block }),
        }
    }

    fn block_parse_maybe(parser: *Parser, line: []const u8) scene.Error!bool {
        assert(line.len > 0);
        assert(parser.stack_count <= depth_max);
        inline for (comptime std.enums.values(BlockKind)) |kind| {
            if (keyword_strip(line, @tagName(kind))) |label| {
                try parser.block_start(kind, label);
                return true;
            }
        }
        for ([_][]const u8{ "else", "and", "option" }) |keyword| {
            if (keyword_strip(line, keyword)) |label| {
                if (parser.stack_count == 0) return error.Syntax;
                const top = parser.stack[parser.stack_count - 1];
                if (top != .block) return error.Syntax;
                const kind = parser.diagram.blocks[top.block].kind;
                const expected = block_divider_keyword(kind) orelse return error.Syntax;
                if (!std.mem.eql(u8, expected, keyword)) return error.Syntax;
                try parser.event_add(.{ .block_divider = .{ .block = top.block, .label = label } });
                return true;
            }
        }
        return false;
    }

    fn block_start(parser: *Parser, kind: BlockKind, label: []const u8) scene.Error!void {
        assert(parser.diagram.block_count <= blocks_max);
        const diagram = parser.diagram;
        if (parser.stack_count == depth_max) return error.Overflow;
        if (diagram.block_count == blocks_max) return error.Overflow;
        const block = diagram.block_count;
        // A `rect` takes a color, which the semantic palette replaces.
        diagram.blocks[block] = .{ .kind = kind, .label = if (kind == .rect) "" else label };
        diagram.block_count += 1;
        parser.stack[parser.stack_count] = .{ .block = block };
        parser.stack_count += 1;
        try parser.event_add(.{ .block_start = block });
        assert(parser.stack_count <= depth_max);
    }

    fn note_parse(parser: *Parser, rest: []const u8) scene.Error!void {
        assert(parser.diagram.event_count <= events_max);
        var placement: NotePlacement = .over;
        var participants = rest;
        if (keyword_strip(rest, "left")) |after| {
            placement = .left;
            participants = keyword_strip(after, "of") orelse return error.Syntax;
        } else if (keyword_strip(rest, "right")) |after| {
            placement = .right;
            participants = keyword_strip(after, "of") orelse return error.Syntax;
        } else {
            participants = keyword_strip(rest, "over") orelse return error.Syntax;
        }
        const colon = std.mem.findScalar(u8, participants, ':') orelse return error.Syntax;
        const names = participants[0..colon];
        var note: Note = .{ .placement = placement, .first = 0, .last = 0, .text = "" };
        note.text = std.mem.trim(u8, participants[colon + 1 ..], " \t");
        if (std.mem.findScalar(u8, names, ',')) |comma| {
            if (placement != .over) return error.Syntax;
            const a = try parser.participant_get(names[0..comma]);
            const b = try parser.participant_get(names[comma + 1 ..]);
            note.first = @min(a, b);
            note.last = @max(a, b);
        } else {
            note.first = try parser.participant_get(names);
            note.last = note.first;
        }
        assert(note.first <= note.last);
        try parser.event_add(.{ .note = note });
    }

    fn message_parse(parser: *Parser, line: []const u8) scene.Error!void {
        assert(line.len > 0);
        const colon = std.mem.findScalar(u8, line, ':') orelse line.len;
        const found = arrow_find(line[0..colon]) orelse return error.Syntax;
        var target = std.mem.trim(u8, line[found.end..colon], " \t");
        var message: Message = .{
            .from = try parser.participant_get(line[0..found.start]),
            .to = 0,
            .text = if (colon < line.len) std.mem.trim(u8, line[colon + 1 ..], " \t") else "",
            .arrow = found.arrow,
            .activate_target = false,
            .deactivate_source = false,
            .number = 0,
        };
        if (target.len > 0 and (target[0] == '+' or target[0] == '-')) {
            message.activate_target = target[0] == '+';
            message.deactivate_source = target[0] == '-';
            target = target[1..];
        }
        message.to = try parser.participant_get(target);
        if (message.activate_target) parser.diagram.activation_count += 1;
        if (parser.autonumber) {
            message.number = parser.number_next;
            parser.number_next +|= parser.number_step;
            if (parser.number_next > 999_999) return error.Overflow;
        }
        try parser.event_add(.{ .message = message });
        if (message.deactivate_source) try parser.event_add(.{ .deactivate = message.from });
        assert(message.from < parser.diagram.participant_count);
    }
};

const ArrowFound = struct { start: usize, end: usize, arrow: Arrow };

/// Finds the leftmost arrow token. Participant names may contain dashes that start no arrow.
fn arrow_find(text: []const u8) ?ArrowFound {
    assert(text.len <= source_length_max);
    assert(arrows[0].token.len >= arrows[arrows.len - 1].token.len);
    for (0..text.len) |start| {
        if (text[start] != '-' and text[start] != '<') continue;
        for (arrows) |candidate| {
            if (std.mem.startsWith(u8, text[start..], candidate.token)) {
                return .{
                    .start = start,
                    .end = start + candidate.token.len,
                    .arrow = candidate.arrow,
                };
            }
        }
    }
    return null;
}

/// Box colors are replaced by the semantic palette, so a leading color is skipped.
fn color_strip(text: []const u8) []const u8 {
    assert(text.len <= source_length_max);
    const color_names = [_][]const u8{
        "transparent", "aqua",   "black",     "blue",       "gray",        "grey",
        "green",       "orange", "pink",      "purple",     "red",         "white",
        "yellow",      "teal",   "lightblue", "lightgreen", "lightyellow", "lightgrey",
        "lightgray",
    };
    const is_function = std.ascii.startsWithIgnoreCase(text, "rgb") or
        std.ascii.startsWithIgnoreCase(text, "hsl");
    if (is_function) {
        const close = std.mem.findScalar(u8, text, ')') orelse return text;
        return std.mem.trim(u8, text[close + 1 ..], " \t");
    }
    const word_end = std.mem.findAny(u8, text, " \t") orelse text.len;
    const word = text[0..word_end];
    const rest = std.mem.trim(u8, text[word_end..], " \t");
    if (word.len > 1 and word[0] == '#') return rest;
    for (color_names) |name| {
        if (std.ascii.eqlIgnoreCase(word, name)) return rest;
    }
    return text;
}

fn parse(source: []const u8, diagram: *Diagram) scene.Error!void {
    assert(diagram.event_count == 0);
    var lines: Lines = .{ .source = source };
    const header = lines.next() orelse return error.Syntax;
    const header_rest = keyword_strip(header, "sequenceDiagram") orelse return error.Syntax;
    if (header_rest.len > 0) return error.Syntax;
    var parser: Parser = .{ .diagram = diagram };
    while (lines.next()) |line| try parser.statement(line);
    if (parser.stack_count > 0) return error.Syntax;
    if (diagram.participant_count == 0) return error.Syntax;
    assert(parser.box_open == box_none);
}

/// Returns the byte length of a `<br>`, `<br/>`, or `<br />` tag at the start of `text`, or 0.
fn break_length(text: []const u8) usize {
    assert(text.len <= source_length_max);
    if (text.len < 4 or !std.ascii.startsWithIgnoreCase(text, "<br")) return 0;
    var index: usize = 3;
    while (index < text.len and text[index] == ' ') index += 1;
    if (index < text.len and text[index] == '/') index += 1;
    if (index < text.len and text[index] == '>') return index + 1;
    return 0;
}

/// Iterates over the lines of a label, which `<br>` tags separate.
const LabelLines = struct {
    text: []const u8,
    cursor: usize = 0,

    fn next(lines: *LabelLines) ?[]const u8 {
        if (lines.cursor > lines.text.len) return null;
        const start = lines.cursor;
        var index = start;
        while (index < lines.text.len) : (index += 1) {
            if (lines.text[index] != '<') continue;
            const length = break_length(lines.text[index..]);
            if (length == 0) continue;
            lines.cursor = index + length;
            assert(lines.cursor > start);
            return std.mem.trim(u8, lines.text[start..index], " \t");
        }
        lines.cursor = lines.text.len + 1;
        return std.mem.trim(u8, lines.text[start..], " \t");
    }
};

fn label_size(measurer: scene.Measurer, text: []const u8, font: scene.Font) scene.Size {
    assert(text.len <= source_length_max);
    var size: scene.Size = .{ .width = 0, .height = 0 };
    if (text.len == 0) return size;
    var lines: LabelLines = .{ .text = text };
    while (lines.next()) |line| {
        const line_size = measurer.measure(line, font);
        size.width = @max(size.width, line_size.width);
        size.height += line_size.height;
    }
    assert(size.height > 0);
    return size;
}

/// Appends lines of the label from `top` down, anchored at `x`.
fn label_emit(
    canvas: *Canvas,
    text: []const u8,
    x: f32,
    top: f32,
    anchor: scene.Anchor,
    font: scene.Font,
) scene.Error!void {
    assert(std.math.isFinite(x));
    assert(std.math.isFinite(top));
    if (text.len == 0) return;
    var lines: LabelLines = .{ .text = text };
    var y = top;
    while (lines.next()) |line| {
        const height = canvas.measurer.measure(line, font).height;
        if (line.len > 0) {
            try canvas.add(.{ .text = .{
                .origin = .{ .x = x, .y = y + height / 2 },
                .anchor = anchor,
                .font = font,
                .bytes = line,
            } });
        }
        y += height;
    }
}

/// Appends commands while tracking their bounds, then moves them so that the bounds start at the
/// padding and sizes the scene to fit. Slots are commands appended now and replaced later, which
/// keeps the drawing order when an extent is only known after later commands.
const Canvas = struct {
    out: *scene.Scene,
    measurer: scene.Measurer,
    command_start: u32,
    point_start: u32,
    slots_open: u32 = 0,
    min: scene.Point = .{ .x = std.math.inf(f32), .y = std.math.inf(f32) },
    max: scene.Point = .{ .x = -std.math.inf(f32), .y = -std.math.inf(f32) },

    const padding = 16;

    fn init(out: *scene.Scene, measurer: scene.Measurer) Canvas {
        assert(out.command_count <= out.commands.len);
        assert(out.point_count <= out.points.len);
        return .{
            .out = out,
            .measurer = measurer,
            .command_start = out.command_count,
            .point_start = out.point_count,
        };
    }

    fn include(canvas: *Canvas, x: f32, y: f32) void {
        assert(std.math.isFinite(x));
        assert(std.math.isFinite(y));
        canvas.min = .{ .x = @min(canvas.min.x, x), .y = @min(canvas.min.y, y) };
        canvas.max = .{ .x = @max(canvas.max.x, x), .y = @max(canvas.max.y, y) };
    }

    fn include_rect(canvas: *Canvas, rect: scene.Rect) void {
        assert(rect.width >= 0);
        assert(rect.height >= 0);
        canvas.include(rect.x, rect.y);
        canvas.include(rect.x + rect.width, rect.y + rect.height);
    }

    fn include_command(canvas: *Canvas, command: scene.Command) void {
        assert(canvas.out.command_count >= canvas.command_start);
        switch (command) {
            .rect => |c| canvas.include_rect(c.rect),
            .ellipse => |c| canvas.include_rect(c.rect),
            .wedge => |c| canvas.include_rect(.{
                .x = c.center.x - c.radius,
                .y = c.center.y - c.radius,
                .width = 2 * c.radius,
                .height = 2 * c.radius,
            }),
            .line => |c| for (canvas.out.points_slice(c.points)) |p| canvas.include(p.x, p.y),
            .polygon => |c| for (canvas.out.points_slice(c.points)) |p| canvas.include(p.x, p.y),
            .text => |c| {
                const size = canvas.measurer.measure(c.bytes, c.font);
                const left = switch (c.anchor) {
                    .start => c.origin.x,
                    .middle => c.origin.x - size.width / 2,
                    .end => c.origin.x - size.width,
                };
                canvas.include_rect(.{
                    .x = left,
                    .y = c.origin.y - size.height / 2,
                    .width = size.width,
                    .height = size.height,
                });
            },
        }
    }

    fn add(canvas: *Canvas, command: scene.Command) scene.Error!void {
        canvas.include_command(command);
        try canvas.out.command_add(command);
    }

    fn slot_reserve(canvas: *Canvas) scene.Error!u32 {
        const slot = canvas.out.command_count;
        const empty: scene.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        try canvas.out.command_add(.{ .rect = .{ .rect = empty } });
        canvas.slots_open += 1;
        assert(slot >= canvas.command_start);
        return slot;
    }

    fn slot_fill(canvas: *Canvas, slot: u32, command: scene.Command) void {
        assert(slot >= canvas.command_start);
        assert(slot < canvas.out.command_count);
        assert(canvas.slots_open > 0);
        canvas.include_command(command);
        canvas.out.commands[slot] = command;
        canvas.slots_open -= 1;
    }

    fn line(canvas: *Canvas, points: []const scene.Point, style: LineStyle) scene.Error!void {
        assert(points.len >= 2);
        const range = try canvas.out.points_add(points);
        try canvas.add(.{ .line = .{
            .points = range,
            .stroke = style.stroke,
            .dash = style.dash,
            .head_start = style.head_start,
            .head_end = style.head_end,
        } });
    }

    fn finish(canvas: *Canvas) void {
        assert(canvas.slots_open == 0);
        assert(canvas.max.x >= canvas.min.x);
        const dx = padding - canvas.min.x;
        const dy = padding - canvas.min.y;
        const out = canvas.out;
        for (out.points[canvas.point_start..out.point_count]) |*point| {
            point.* = .{ .x = point.x + dx, .y = point.y + dy };
        }
        for (out.commands[canvas.command_start..out.command_count]) |*command| {
            switch (command.*) {
                .rect => |*c| c.rect = rect_translate(c.rect, dx, dy),
                .ellipse => |*c| c.rect = rect_translate(c.rect, dx, dy),
                .wedge => |*c| c.center = .{ .x = c.center.x + dx, .y = c.center.y + dy },
                .text => |*c| c.origin = .{ .x = c.origin.x + dx, .y = c.origin.y + dy },
                .line, .polygon => {},
            }
        }
        out.size = .{
            .width = @ceil(canvas.max.x - canvas.min.x + 2 * padding),
            .height = @ceil(canvas.max.y - canvas.min.y + 2 * padding),
        };
        assert(out.size.width > 0);
    }
};

const LineStyle = struct {
    stroke: scene.Color = .line,
    dash: scene.Dash = .solid,
    head_start: scene.Head = .none,
    head_end: scene.Head = .none,
};

fn rect_translate(rect: scene.Rect, dx: f32, dy: f32) scene.Rect {
    assert(std.math.isFinite(dx));
    assert(std.math.isFinite(dy));
    return .{ .x = rect.x + dx, .y = rect.y + dy, .width = rect.width, .height = rect.height };
}

const Activation = struct { slot: u32, top: f32 };

const ActivationStack = struct {
    items: [activation_depth_max]Activation = undefined,
    count: u32 = 0,
};

const Extent = struct {
    left: f32 = std.math.inf(f32),
    right: f32 = -std.math.inf(f32),

    fn add(extent: *Extent, left: f32, right: f32) void {
        assert(left <= right);
        extent.left = @min(extent.left, left);
        extent.right = @max(extent.right, right);
    }

    fn is_empty(extent: Extent) bool {
        return extent.left > extent.right;
    }
};

const Layout = struct {
    diagram: *const Diagram,
    canvas: *Canvas,
    /// Column centers and widths.
    x: [participants_max]f32 = undefined,
    width: [participants_max]f32 = undefined,
    /// The minimum distance between the centers of columns `i < j`, at `[i][j]`.
    span: [participants_max][participants_max]f32 = undefined,
    rect_height: f32 = 0,
    header_height: f32 = 0,
    block_extent: [blocks_max]Extent = undefined,
    block_top: [blocks_max]f32 = undefined,
    block_slot: [blocks_max]u32 = undefined,
    lifeline_slot: [participants_max]u32 = undefined,
    box_slot: [boxes_max]u32 = undefined,
    bar_slot_next: u32 = 0,
    bar_slot_end: u32 = 0,
    stacks: [participants_max]ActivationStack = undefined,
    y: f32 = 0,
    line_y_last: f32 = 0,
    lifeline_top: f32 = 0,
    boxes_top: f32 = 0,
    previous_was_message: bool = false,

    fn run(layout: *Layout) scene.Error!void {
        assert(layout.diagram.participant_count > 0);
        layout.columns_measure();
        layout.spans_measure();
        layout.columns_place();
        layout.blocks_measure();
        try layout.slots_reserve();
        try layout.header_top_emit();
        for (layout.diagram.events[0..layout.diagram.event_count]) |event| {
            try layout.event_emit(event);
        }
        try layout.footer_emit();
        assert(layout.bar_slot_next == layout.bar_slot_end);
    }

    fn measurer(layout: *const Layout) scene.Measurer {
        return layout.canvas.measurer;
    }

    fn participants(layout: *const Layout) []const Participant {
        return layout.diagram.participants[0..layout.diagram.participant_count];
    }

    fn columns_measure(layout: *Layout) void {
        assert(layout.diagram.participant_count > 0);
        var rect_height: f32 = 0;
        var actor_height: f32 = 0;
        for (layout.participants(), 0..) |participant, index| {
            const size = label_size(layout.measurer(), participant.label, .regular);
            switch (participant.kind) {
                .participant => {
                    layout.width[index] = @max(
                        participant_width_min,
                        size.width + 2 * participant_padding_x,
                    );
                    rect_height = @max(rect_height, size.height + 2 * participant_padding_y);
                },
                .actor => {
                    layout.width[index] = @max(participant_width_min, size.width);
                    actor_height = @max(
                        actor_height,
                        actor_figure_height + actor_label_gap + size.height,
                    );
                },
            }
        }
        layout.rect_height = rect_height;
        layout.header_height = @max(rect_height, actor_height);
        assert(layout.header_height > 0);
    }

    fn span_require(layout: *Layout, a: u32, b: u32, distance: f32) void {
        assert(a != b);
        assert(@max(a, b) < layout.diagram.participant_count);
        const low = @min(a, b);
        const high = @max(a, b);
        layout.span[low][high] = @max(layout.span[low][high], distance);
    }

    fn spans_measure(layout: *Layout) void {
        assert(layout.diagram.participant_count > 0);
        assert(layout.diagram.participant_count <= participants_max);
        const count = layout.diagram.participant_count;
        for (0..count) |i| @memset(layout.span[i][0..count], 0);
        for (1..count) |j| {
            const i = j - 1;
            const boxes_differ = layout.diagram.participants[i].box !=
                layout.diagram.participants[j].box;
            const box_gap: f32 = if (boxes_differ) 2 * box_padding else 0;
            const gap = participant_gap + box_gap;
            layout.span[i][j] = (layout.width[i] + layout.width[j]) / 2 + gap;
        }
        for (layout.diagram.events[0..layout.diagram.event_count]) |event| {
            switch (event) {
                .message => |message| layout.span_message(message),
                .note => |note| layout.span_note(note),
                else => {},
            }
        }
    }

    fn span_message(layout: *Layout, message: Message) void {
        const count = layout.diagram.participant_count;
        assert(message.from < count);
        assert(message.to < count);
        const text = label_size(layout.measurer(), message.text, .regular);
        const badge: f32 = if (message.number > 0) 2 * badge_radius else 0;
        if (message.from != message.to) {
            const distance = text.width + 2 * message_padding + badge + bar_width;
            layout.span_require(message.from, message.to, distance);
        } else if (message.from + 1 < count) {
            const reach = @max(self_width, text.width + message_text_gap + badge);
            const distance = reach + bar_width + message_padding;
            layout.span_require(message.from, message.from + 1, distance);
        }
    }

    fn span_note(layout: *Layout, note: Note) void {
        const count = layout.diagram.participant_count;
        assert(note.last < count);
        const width = label_size(layout.measurer(), note.text, .regular).width + 2 * note_padding_x;
        switch (note.placement) {
            .right => if (note.first + 1 < count) {
                layout.span_require(note.first, note.first + 1, width + 2 * note_gap);
            },
            .left => if (note.first > 0) {
                layout.span_require(note.first - 1, note.first, width + 2 * note_gap);
            },
            .over => if (note.first == note.last) {
                const half = width / 2 + note_gap;
                if (note.first > 0) layout.span_require(note.first - 1, note.first, half);
                if (note.first + 1 < count) layout.span_require(note.first, note.first + 1, half);
            } else {
                layout.span_require(note.first, note.last, width - 2 * note_overhang);
            },
        }
    }

    /// Places columns left to right. Every requirement links a column to one on its left, so a
    /// single pass finds the narrowest placement that satisfies all of them.
    fn columns_place(layout: *Layout) void {
        const count = layout.diagram.participant_count;
        layout.x[0] = 0;
        for (1..count) |j| {
            var x: f32 = layout.x[j - 1];
            for (0..j) |i| x = @max(x, layout.x[i] + layout.span[i][j]);
            layout.x[j] = x;
            assert(layout.x[j] > layout.x[j - 1]);
        }
        assert(layout.x[0] == 0);
    }

    /// Returns the x of the side of the participant's innermost activation bar that faces
    /// `toward_x`, or the lifeline when it has no activation.
    fn edge_x(layout: *const Layout, participant: u32, toward_x: f32) f32 {
        assert(participant < layout.diagram.participant_count);
        const center = layout.x[participant];
        const depth = layout.stacks[participant].count;
        if (depth == 0) return center;
        const left = bar_left(center, depth - 1);
        return if (toward_x > center) left + bar_width else left;
    }

    fn note_rect_horizontal(layout: *const Layout, note: Note, width_text: f32) Extent {
        assert(note.last < layout.diagram.participant_count);
        assert(width_text >= 0);
        const width = width_text + 2 * note_padding_x;
        const first = layout.x[note.first];
        return switch (note.placement) {
            .right => .{ .left = first + note_gap, .right = first + note_gap + width },
            .left => .{ .left = first - note_gap - width, .right = first - note_gap },
            .over => over: {
                const last = layout.x[note.last];
                const middle = (first + last) / 2;
                const span_width = @max(width, last - first + 2 * note_overhang);
                break :over .{ .left = middle - span_width / 2, .right = middle + span_width / 2 };
            },
        };
    }

    fn message_extent(layout: *const Layout, message: Message) Extent {
        const text = label_size(layout.measurer(), message.text, .regular);
        const from = layout.x[message.from];
        const to = layout.x[message.to];
        var extent: Extent = .{};
        if (message.from == message.to) {
            const badge: f32 = if (message.number > 0) 2 * badge_radius else 0;
            const reach = @max(self_width, text.width + message_text_gap + badge);
            extent.add(from - bar_width, from + bar_width + reach);
        } else {
            const middle = (from + to) / 2;
            extent.add(@min(from, to) - bar_width, @max(from, to) + bar_width);
            extent.add(middle - text.width / 2, middle + text.width / 2);
        }
        assert(!extent.is_empty());
        return extent;
    }

    /// Finds the horizontal extent of every frame from the content inside it.
    fn blocks_measure(layout: *Layout) void {
        var stack: [depth_max]u32 = undefined;
        var contents: [depth_max]Extent = undefined;
        var dividers_width: [depth_max]f32 = undefined;
        var depth: u32 = 0;
        for (layout.diagram.events[0..layout.diagram.event_count]) |event| {
            const content: ?Extent = switch (event) {
                .message => |message| layout.message_extent(message),
                .note => |note| layout.note_rect_horizontal(
                    note,
                    label_size(layout.measurer(), note.text, .regular).width,
                ),
                else => null,
            };
            if (content) |extent| {
                if (depth > 0) contents[depth - 1].add(extent.left, extent.right);
                continue;
            }
            switch (event) {
                .block_start => |block| {
                    assert(depth < depth_max);
                    stack[depth] = block;
                    contents[depth] = .{};
                    dividers_width[depth] = 0;
                    depth += 1;
                },
                .block_divider => |divider| {
                    assert(depth > 0);
                    const width = layout.divider_label_width(divider.label);
                    dividers_width[depth - 1] = @max(dividers_width[depth - 1], width);
                },
                .block_end => |block| {
                    assert(depth > 0);
                    depth -= 1;
                    assert(stack[depth] == block);
                    const extent =
                        layout.block_frame(block, contents[depth], dividers_width[depth]);
                    layout.block_extent[block] = extent;
                    if (depth > 0) contents[depth - 1].add(extent.left, extent.right);
                },
                else => {},
            }
        }
        assert(depth == 0);
    }

    fn divider_label_width(layout: *const Layout, label: []const u8) f32 {
        assert(label.len <= source_length_max);
        if (label.len == 0) return 0;
        const width = label_size(layout.measurer(), label, .regular).width;
        return width + layout.measurer().measure("[]", .regular).width + 2 * frame_label_gap;
    }

    fn block_tab_width(layout: *const Layout, block: Block) f32 {
        if (block.kind == .rect) return 0;
        const keyword = @tagName(block.kind);
        return layout.measurer().measure(keyword, .bold).width + 2 * frame_tab_padding;
    }

    fn block_frame(layout: *const Layout, block: u32, content: Extent, dividers: f32) Extent {
        assert(block < layout.diagram.block_count);
        assert(dividers >= 0);
        var extent = content;
        if (extent.is_empty()) extent = .{ .left = layout.x[0], .right = layout.x[0] };
        extent.left -= frame_margin;
        extent.right += frame_margin;
        const data = layout.diagram.blocks[block];
        const label_width = layout.divider_label_width(data.label);
        const header = layout.block_tab_width(data) + label_width + frame_label_gap;
        const width_min = @max(header, dividers);
        if (extent.right - extent.left < width_min) extent.right = extent.left + width_min;
        assert(extent.right > extent.left);
        return extent;
    }

    fn slots_reserve(layout: *Layout) scene.Error!void {
        const canvas = layout.canvas;
        for (0..layout.diagram.box_count) |box| layout.box_slot[box] = try canvas.slot_reserve();
        for (layout.diagram.blocks[0..layout.diagram.block_count], 0..) |block, index| {
            if (block.kind == .rect) layout.block_slot[index] = try canvas.slot_reserve();
        }
        for (0..layout.diagram.participant_count) |index| {
            layout.lifeline_slot[index] = try canvas.slot_reserve();
            layout.stacks[index] = .{};
        }
        layout.bar_slot_next = canvas.out.command_count;
        for (0..layout.diagram.activation_count) |_| _ = try canvas.slot_reserve();
        layout.bar_slot_end = canvas.out.command_count;
        assert(layout.bar_slot_end - layout.bar_slot_next == layout.diagram.activation_count);
    }

    fn header_top_emit(layout: *Layout) scene.Error!void {
        assert(layout.y == 0);
        const count = layout.diagram.participant_count;
        const left = layout.x[0] - layout.width[0] / 2;
        const right = layout.x[count - 1] + layout.width[count - 1] / 2;
        const title = layout.diagram.title;
        if (title.len > 0) {
            try label_emit(layout.canvas, title, (left + right) / 2, 0, .middle, .bold);
            layout.y = label_size(layout.measurer(), title, .bold).height + title_gap;
        }
        layout.boxes_top = layout.y;
        if (layout.diagram.box_count > 0) {
            var label_height: f32 = 0;
            for (layout.diagram.boxes[0..layout.diagram.box_count]) |box| {
                const height = label_size(layout.measurer(), box.label, .bold).height;
                label_height = @max(label_height, height);
            }
            layout.y += box_padding + label_height + box_label_gap;
        }
        try layout.headers_emit(layout.y, .top);
        layout.lifeline_top = layout.y + layout.header_height;
        layout.y = layout.lifeline_top + event_gap;
        layout.line_y_last = layout.y;
        assert(layout.lifeline_top > layout.boxes_top);
    }

    fn headers_emit(layout: *Layout, top: f32, side: enum { top, bottom }) scene.Error!void {
        assert(std.math.isFinite(top));
        assert(layout.header_height > 0);
        for (layout.participants(), 0..) |participant, index| {
            const center = layout.x[index];
            const label = label_size(layout.measurer(), participant.label, .regular);
            const height = switch (participant.kind) {
                .participant => layout.rect_height,
                .actor => actor_figure_height + actor_label_gap + label.height,
            };
            // Headers align on the lifeline side: the bottom at the top, the top at the bottom.
            const header_top = if (side == .top) top + layout.header_height - height else top;
            var label_top = header_top + actor_figure_height + actor_label_gap;
            switch (participant.kind) {
                .participant => {
                    try layout.canvas.add(.{ .rect = .{
                        .rect = .{
                            .x = center - layout.width[index] / 2,
                            .y = header_top,
                            .width = layout.width[index],
                            .height = height,
                        },
                        .radius = participant_radius,
                        .fill = .node_fill,
                        .stroke = .node_stroke,
                    } });
                    label_top = header_top + (height - label.height) / 2;
                },
                .actor => try actor_emit(layout.canvas, center, header_top),
            }
            try label_emit(layout.canvas, participant.label, center, label_top, .middle, .regular);
        }
    }

    fn event_emit(layout: *Layout, event: Event) scene.Error!void {
        assert(layout.y >= layout.lifeline_top);
        assert(layout.y > 0);
        switch (event) {
            .message => |message| try layout.message_emit(message),
            .note => |note| try layout.note_emit(note),
            .activate => |participant| try layout.activate(participant, layout.activation_top()),
            .deactivate => |participant| {
                try layout.deactivate(participant, layout.activation_top());
            },
            .block_start => |block| try layout.block_start_emit(block),
            .block_divider => |divider| try layout.block_divider_emit(divider.block, divider.label),
            .block_end => |block| try layout.block_end_emit(block),
        }
        layout.previous_was_message = event == .message;
    }

    /// Activations that follow a message start or end at its line, as in Mermaid.
    fn activation_top(layout: *const Layout) f32 {
        return if (layout.previous_was_message) layout.line_y_last else layout.y;
    }

    fn activate(layout: *Layout, participant: u32, top: f32) scene.Error!void {
        assert(participant < layout.diagram.participant_count);
        assert(layout.bar_slot_next < layout.bar_slot_end);
        const stack = &layout.stacks[participant];
        if (stack.count == activation_depth_max) return error.Overflow;
        stack.items[stack.count] = .{ .slot = layout.bar_slot_next, .top = top };
        stack.count += 1;
        layout.bar_slot_next += 1;
    }

    fn deactivate(layout: *Layout, participant: u32, bottom_hint: f32) scene.Error!void {
        assert(std.math.isFinite(bottom_hint));
        assert(participant < layout.diagram.participant_count);
        const stack = &layout.stacks[participant];
        if (stack.count == 0) return error.Syntax;
        stack.count -= 1;
        const activation = stack.items[stack.count];
        const bottom = @max(bottom_hint, activation.top + bar_height_min);
        layout.y = @max(layout.y, bottom);
        layout.canvas.slot_fill(activation.slot, .{ .rect = .{
            .rect = .{
                .x = bar_left(layout.x[participant], stack.count),
                .y = activation.top,
                .width = bar_width,
                .height = bottom - activation.top,
            },
            .fill = .node_fill,
            .stroke = .node_stroke,
        } });
    }

    fn message_emit(layout: *Layout, message: Message) scene.Error!void {
        assert(message.from < layout.diagram.participant_count);
        if (message.from == message.to) return layout.self_message_emit(message);
        const text = label_size(layout.measurer(), message.text, .regular);
        const line_y = layout.y + text.height + text_gap(text.height);
        const from_center = layout.x[message.from];
        const to_center = layout.x[message.to];
        const start_x = layout.edge_x(message.from, to_center);
        if (message.activate_target) try layout.activate(message.to, line_y);
        const end_x = layout.edge_x(message.to, from_center);
        const middle = (from_center + to_center) / 2;
        try label_emit(layout.canvas, message.text, middle, layout.y, .middle, .regular);
        try layout.canvas.line(&.{
            .{ .x = start_x, .y = line_y },
            .{ .x = end_x, .y = line_y },
        }, .{
            .dash = message.arrow.dash,
            .head_start = message.arrow.head_start,
            .head_end = message.arrow.head_end,
        });
        if (message.number > 0) {
            try layout.badge_emit(message.number, .{ .x = start_x, .y = line_y });
        }
        layout.line_y_last = line_y;
        layout.y = line_y + event_gap;
        // The `-` shorthand appends its own deactivate event, which ends the bar at this line.
        assert(layout.y > line_y);
    }

    fn self_message_emit(layout: *Layout, message: Message) scene.Error!void {
        assert(message.from == message.to);
        const text = label_size(layout.measurer(), message.text, .regular);
        const loop_top = layout.y + text.height + text_gap(text.height);
        const loop_bottom = loop_top + self_height;
        const center = layout.x[message.from];
        const start_x = layout.edge_x(message.from, center + 1);
        if (message.activate_target) try layout.activate(message.to, loop_bottom);
        const end_x = layout.edge_x(message.to, center + 1);
        const badge: f32 = if (message.number > 0) 2 * badge_radius else 0;
        const text_x = start_x + message_text_gap + badge;
        try label_emit(layout.canvas, message.text, text_x, layout.y, .start, .regular);
        const reach = start_x + self_width;
        try layout.canvas.line(&.{
            .{ .x = start_x, .y = loop_top },
            .{ .x = reach, .y = loop_top },
            .{ .x = reach, .y = loop_bottom },
            .{ .x = end_x, .y = loop_bottom },
        }, .{
            .dash = message.arrow.dash,
            .head_start = message.arrow.head_start,
            .head_end = message.arrow.head_end,
        });
        if (message.number > 0) {
            try layout.badge_emit(message.number, .{ .x = start_x, .y = loop_top });
        }
        layout.line_y_last = loop_bottom;
        layout.y = loop_bottom + event_gap;
        assert(end_x >= start_x);
    }

    fn badge_emit(layout: *Layout, number: u32, center: scene.Point) scene.Error!void {
        assert(std.math.isFinite(center.x));
        assert(number > 0);
        try layout.canvas.add(.{ .ellipse = .{
            .rect = .{
                .x = center.x - badge_radius,
                .y = center.y - badge_radius,
                .width = 2 * badge_radius,
                .height = 2 * badge_radius,
            },
            .fill = .node_fill,
            .stroke = .node_stroke,
        } });
        try layout.canvas.add(.{ .text = .{
            .origin = center,
            .font = .small,
            .bytes = try layout.canvas.out.text_print("{d}", .{number}),
        } });
    }

    fn note_emit(layout: *Layout, note: Note) scene.Error!void {
        assert(note.first <= note.last);
        const text = label_size(layout.measurer(), note.text, .regular);
        const horizontal = layout.note_rect_horizontal(note, text.width);
        const height = @max(text.height, layout.measurer().measure("", .regular).height) +
            2 * note_padding_y;
        try layout.canvas.add(.{ .rect = .{
            .rect = .{
                .x = horizontal.left,
                .y = layout.y,
                .width = horizontal.right - horizontal.left,
                .height = height,
            },
            .radius = 2,
            .fill = .note_fill,
            .stroke = .note_stroke,
        } });
        const middle = (horizontal.left + horizontal.right) / 2;
        const text_top = layout.y + note_padding_y;
        try label_emit(layout.canvas, note.text, middle, text_top, .middle, .regular);
        layout.y += height + event_gap;
        assert(horizontal.right > horizontal.left);
    }

    fn block_header_height(layout: *const Layout, block: Block) f32 {
        assert(block.label.len <= source_length_max);
        if (block.kind == .rect) return 0;
        const label = label_size(layout.measurer(), block.label, .regular);
        return @max(frame_header_height_min, label.height + 6);
    }

    fn block_start_emit(layout: *Layout, block: u32) scene.Error!void {
        assert(layout.y > 0);
        assert(block < layout.diagram.block_count);
        const data = layout.diagram.blocks[block];
        const extent = layout.block_extent[block];
        const top = layout.y - event_gap + frame_gap;
        layout.block_top[block] = top;
        const header_height = layout.block_header_height(data);
        layout.y = top + header_height + event_gap;
        if (data.kind == .rect) return;
        const tab_width = layout.block_tab_width(data);
        const range = try layout.canvas.out.points_add(&.{
            .{ .x = extent.left, .y = top },
            .{ .x = extent.left + tab_width, .y = top },
            .{ .x = extent.left + tab_width, .y = top + header_height - frame_tab_notch },
            .{ .x = extent.left + tab_width - frame_tab_notch, .y = top + header_height },
            .{ .x = extent.left, .y = top + header_height },
        });
        try layout.canvas.add(.{ .polygon = .{
            .points = range,
            .fill = .group_fill,
            .stroke = .line,
        } });
        try layout.canvas.add(.{ .text = .{
            .origin = .{ .x = extent.left + tab_width / 2, .y = top + header_height / 2 },
            .font = .bold,
            .bytes = @tagName(data.kind),
        } });
        const label_x = extent.left + tab_width + frame_label_gap;
        try layout.condition_emit(data.label, label_x, top, header_height, .start);
    }

    /// Appends a block condition such as `[x > 1]`, centered vertically in a band.
    fn condition_emit(
        layout: *Layout,
        label: []const u8,
        x: f32,
        top: f32,
        band_height: f32,
        anchor: scene.Anchor,
    ) scene.Error!void {
        assert(band_height > 0);
        if (label.len == 0) return;
        const size = label_size(layout.measurer(), label, .regular);
        var lines: LabelLines = .{ .text = label };
        var y = top + (band_height - size.height) / 2;
        var first = true;
        while (lines.next()) |line| {
            const height = layout.measurer().measure(line, .regular).height;
            const done = lines.cursor > label.len;
            const bytes = try layout.canvas.out.text_print("{s}{s}{s}", .{
                if (first) "[" else "",
                line,
                if (done) "]" else "",
            });
            try layout.canvas.add(.{ .text = .{
                .origin = .{ .x = x, .y = y + height / 2 },
                .anchor = anchor,
                .color = .text_muted,
                .bytes = bytes,
            } });
            y += height;
            first = false;
        }
        assert(y > top);
    }

    fn block_divider_emit(layout: *Layout, block: u32, label: []const u8) scene.Error!void {
        assert(layout.y > 0);
        assert(block < layout.diagram.block_count);
        const extent = layout.block_extent[block];
        const divider_y = layout.y - event_gap + frame_gap;
        try layout.canvas.line(&.{
            .{ .x = extent.left, .y = divider_y },
            .{ .x = extent.right, .y = divider_y },
        }, .{ .dash = .dashed });
        const height: f32 = if (label.len > 0)
            label_size(layout.measurer(), label, .regular).height + 6
        else
            0;
        if (label.len > 0) {
            const middle = (extent.left + extent.right) / 2;
            try layout.condition_emit(label, middle, divider_y + 2, height, .middle);
        }
        layout.y = divider_y + height + event_gap;
    }

    fn block_end_emit(layout: *Layout, block: u32) scene.Error!void {
        assert(block < layout.diagram.block_count);
        const extent = layout.block_extent[block];
        const top = layout.block_top[block];
        const bottom = layout.y - event_gap + frame_gap;
        assert(bottom > top);
        const rect: scene.Rect = .{
            .x = extent.left,
            .y = top,
            .width = extent.right - extent.left,
            .height = bottom - top,
        };
        if (layout.diagram.blocks[block].kind == .rect) {
            layout.canvas.slot_fill(layout.block_slot[block], .{ .rect = .{
                .rect = rect,
                .radius = 4,
                .fill = .group_fill,
                .stroke = .group_stroke,
            } });
        } else {
            try layout.canvas.add(.{ .rect = .{ .rect = rect, .radius = 2, .stroke = .line } });
        }
        layout.y = bottom + event_gap;
    }

    fn footer_emit(layout: *Layout) scene.Error!void {
        assert(layout.canvas.slots_open >= layout.diagram.participant_count);
        const count = layout.diagram.participant_count;
        assert(layout.y > layout.lifeline_top);
        // Activations still open at the end run to the end of the lifelines.
        const open_bottom = layout.y - event_gap + lifeline_end_gap / 2;
        for (0..count) |index| {
            while (layout.stacks[index].count > 0) {
                try layout.deactivate(@intCast(index), open_bottom);
            }
        }
        const footer_top = layout.y - event_gap + lifeline_end_gap;
        for (0..count) |index| {
            const range = try layout.canvas.out.points_add(&.{
                .{ .x = layout.x[index], .y = layout.lifeline_top },
                .{ .x = layout.x[index], .y = footer_top },
            });
            layout.canvas.slot_fill(layout.lifeline_slot[index], .{ .line = .{
                .points = range,
                .dash = .dashed,
            } });
        }
        try layout.headers_emit(footer_top, .bottom);
        try layout.boxes_emit(footer_top + layout.header_height);
    }

    fn boxes_emit(layout: *Layout, bottom: f32) scene.Error!void {
        assert(layout.diagram.box_count <= boxes_max);
        assert(bottom > layout.boxes_top);
        const top = layout.boxes_top;
        for (layout.diagram.boxes[0..layout.diagram.box_count], 0..) |box, box_index| {
            var extent: Extent = .{};
            for (layout.participants(), 0..) |participant, index| {
                if (participant.box != box_index) continue;
                const half = layout.width[index] / 2;
                const reach = half + box_padding;
                extent.add(layout.x[index] - reach, layout.x[index] + reach);
            }
            // A box without participants still needs a place: it sits over the first column.
            if (extent.is_empty()) extent.add(layout.x[0] - box_padding, layout.x[0] + box_padding);
            layout.canvas.slot_fill(layout.box_slot[box_index], .{ .rect = .{
                .rect = .{
                    .x = extent.left,
                    .y = top,
                    .width = extent.right - extent.left,
                    .height = bottom + box_padding - top,
                },
                .radius = 6,
                .fill = .group_fill,
                .stroke = .group_stroke,
            } });
            const middle = (extent.left + extent.right) / 2;
            try label_emit(layout.canvas, box.label, middle, top + box_padding / 2, .middle, .bold);
        }
    }
};

/// The gap between a message label and its line, which only labels that exist need.
fn text_gap(height: f32) f32 {
    assert(height >= 0);
    return if (height > 0) message_text_gap else 0;
}

fn bar_left(center: f32, depth: u32) f32 {
    assert(depth < activation_depth_max);
    const depth_float: f32 = @floatFromInt(depth);
    return center - bar_width / 2 + depth_float * bar_offset;
}

/// Draws a stick figure whose bounding box is centered on `center` and starts at `top`.
fn actor_emit(canvas: *Canvas, center: f32, top: f32) scene.Error!void {
    assert(std.math.isFinite(center));
    assert(std.math.isFinite(top));
    const head = 14;
    const half: f32 = actor_figure_width / 2;
    const neck = top + head;
    const hip = top + actor_figure_height - 14;
    const foot = top + actor_figure_height;
    try canvas.add(.{ .ellipse = .{
        .rect = .{ .x = center - head / 2, .y = top, .width = head, .height = head },
        .fill = .node_fill,
        .stroke = .node_stroke,
        .stroke_width = 1.5,
    } });
    const style: LineStyle = .{ .stroke = .node_stroke };
    try canvas.line(&.{ .{ .x = center, .y = neck }, .{ .x = center, .y = hip } }, style);
    try canvas.line(&.{
        .{ .x = center - half * 0.75, .y = neck + 6 },
        .{ .x = center + half * 0.75, .y = neck + 6 },
    }, style);
    try canvas.line(&.{
        .{ .x = center - half * 0.6, .y = foot },
        .{ .x = center, .y = hip },
        .{ .x = center + half * 0.6, .y = foot },
    }, style);
}

const testing = std.testing;

const Fixture = struct {
    commands: [4096]scene.Command = undefined,
    points: [8192]scene.Point = undefined,
    text: [8192]u8 = undefined,
    scratch: [512 * 1024]u8 = undefined,
    out: scene.Scene = undefined,

    fn run(fixture: *Fixture, source: []const u8) scene.Error!void {
        fixture.out = scene.Scene.init(&fixture.commands, &fixture.points, &fixture.text);
        try render(source, scene.Measurer.fixed, &fixture.scratch, &fixture.out);
    }
};

/// Checks that every command lies inside the scene, measuring text with the fixed measurer.
fn expect_inside(out: *const scene.Scene) !void {
    const measurer = scene.Measurer.fixed;
    for (out.commands_slice()) |command| {
        switch (command) {
            .rect => |c| try expect_rect_inside(out, c.rect),
            .ellipse => |c| try expect_rect_inside(out, c.rect),
            .wedge => |c| try expect_rect_inside(out, .{
                .x = c.center.x - c.radius,
                .y = c.center.y - c.radius,
                .width = 2 * c.radius,
                .height = 2 * c.radius,
            }),
            .text => |c| {
                const size = measurer.measure(c.bytes, c.font);
                const x = switch (c.anchor) {
                    .start => c.origin.x,
                    .middle => c.origin.x - size.width / 2,
                    .end => c.origin.x - size.width,
                };
                try expect_rect_inside(out, .{
                    .x = x,
                    .y = c.origin.y - size.height / 2,
                    .width = size.width,
                    .height = size.height,
                });
            },
            .line => |c| for (out.points_slice(c.points)) |p| try expect_point_inside(out, p),
            .polygon => |c| for (out.points_slice(c.points)) |p| try expect_point_inside(out, p),
        }
    }
}

fn expect_point_inside(out: *const scene.Scene, point: scene.Point) !void {
    try expect_rect_inside(out, .{ .x = point.x, .y = point.y, .width = 0, .height = 0 });
}

fn expect_rect_inside(out: *const scene.Scene, rect: scene.Rect) !void {
    try testing.expect(rect.x >= 0);
    try testing.expect(rect.y >= 0);
    try testing.expect(rect.x + rect.width <= out.size.width);
    try testing.expect(rect.y + rect.height <= out.size.height);
}

const sample_full =
    \\sequenceDiagram
    \\    title Checkout
    \\    autonumber
    \\    actor User
    \\    box Aqua Frontend
    \\    participant Web as Web app
    \\    end
    \\    participant API
    \\    participant DB as Database
    \\    participant Pay as Payments<br/>provider
    \\    User->>+Web: Open cart
    \\    Web->>+API: GET /cart
    \\    API->>DB: SELECT items
    \\    DB-->>API: rows
    \\    API-->>-Web: cart JSON
    \\    Note over Web,API: Cached for 30 s
    \\    loop Every item
    \\        Web->>Web: Render line
    \\    end
    \\    alt Card on file
    \\        Web->>Pay: Charge
    \\        Pay--)Web: Accepted
    \\    else New card
    \\        Web-xPay: Tokenize
    \\        opt 3-D Secure
    \\            Pay->>User: Challenge
    \\        end
    \\    end
    \\    Note right of Pay: Async webhook
    \\    deactivate Web
    \\    User<<->>Web: Done
;

test "sequence: parse participants, messages, and blocks" {
    var diagram: Diagram = .{};
    try parse(sample_full, &diagram);
    try testing.expectEqualStrings("Checkout", diagram.title);
    try testing.expectEqual(@as(u32, 5), diagram.participant_count);
    const participants = diagram.participants[0..diagram.participant_count];
    try testing.expectEqual(ParticipantKind.actor, participants[0].kind);
    try testing.expectEqualStrings("Web app", participants[1].label);
    try testing.expectEqual(@as(u32, 0), participants[1].box);
    try testing.expectEqual(box_none, participants[2].box);
    try testing.expectEqualStrings("Frontend", diagram.boxes[0].label);
    try testing.expectEqual(@as(u32, 3), diagram.block_count);
    try testing.expectEqual(BlockKind.alt, diagram.blocks[1].kind);
    try testing.expectEqual(@as(u32, 2), diagram.activation_count);
    const first = diagram.events[0].message;
    try testing.expect(first.activate_target);
    try testing.expectEqual(@as(u32, 1), first.number);
    try testing.expectEqual(scene.Head.arrow, first.arrow.head_end);
}

test "sequence: arrow forms" {
    const Case = struct { text: []const u8, dash: scene.Dash, start: scene.Head, end: scene.Head };
    const cases = [_]Case{
        .{ .text = "A->B", .dash = .solid, .start = .none, .end = .none },
        .{ .text = "A-->B", .dash = .dashed, .start = .none, .end = .none },
        .{ .text = "A->>B", .dash = .solid, .start = .none, .end = .arrow },
        .{ .text = "A-->>B", .dash = .dashed, .start = .none, .end = .arrow },
        .{ .text = "A-xB", .dash = .solid, .start = .none, .end = .cross },
        .{ .text = "A--xB", .dash = .dashed, .start = .none, .end = .cross },
        .{ .text = "A-)B", .dash = .solid, .start = .none, .end = .arrow_open },
        .{ .text = "A--)B", .dash = .dashed, .start = .none, .end = .arrow_open },
        .{ .text = "A<<->>B", .dash = .solid, .start = .arrow, .end = .arrow },
        .{ .text = "A<<-->>B", .dash = .dashed, .start = .arrow, .end = .arrow },
        .{ .text = "x-ray->>B", .dash = .solid, .start = .none, .end = .arrow },
    };
    for (cases) |case| {
        const found = arrow_find(case.text).?;
        try testing.expectEqual(case.dash, found.arrow.dash);
        try testing.expectEqual(case.start, found.arrow.head_start);
        try testing.expectEqual(case.end, found.arrow.head_end);
        try testing.expectEqualStrings("B", case.text[found.end..]);
    }
    try testing.expect(arrow_find("A B") == null);
}

test "sequence: malformed input" {
    var fixture: Fixture = .{};
    try testing.expectError(error.Syntax, fixture.run("sequenceDiagram\n"));
    try testing.expectError(error.Syntax, fixture.run("sequenceDiagram\nA B\n"));
    try testing.expectError(error.Syntax, fixture.run("sequenceDiagram\nloop x\nA->>B: y\n"));
    try testing.expectError(error.Syntax, fixture.run("sequenceDiagram\nA->>B: y\nend\n"));
    try testing.expectError(error.Syntax, fixture.run("sequenceDiagram\nloop\nelse\nend\n"));
    try testing.expectError(error.Syntax, fixture.run("sequenceDiagram\nNote over A B\n"));
    try testing.expectError(error.Syntax, fixture.run("sequenceDiagram\nNote left of A,B: x\n"));
    try testing.expectError(error.Syntax, fixture.run("sequenceDiagram\nA->>B: x\ndeactivate B\n"));
    try testing.expectError(error.Syntax, fixture.run("sequenceDiagram\n->>B: x\n"));
    try testing.expectError(error.Syntax, fixture.run("sequenceDiagram\nloop\nbox\nend\nend\n"));
    const odd_statements = [_][]const u8{
        "create",           "note",        "Note over",  "Note left of :", "box",
        "autonumber 1 2 3", "activate",    "end",        "title",          "A->>+",
        "A->>-B",           "participant", "actor A as", "else",           "destroy",
    };
    for (odd_statements) |statement| {
        var buffer: [64]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "sequenceDiagram\n{s}\n", .{statement});
        fixture.run(source) catch continue;
        try expect_inside(&fixture.out);
    }
}

test "sequence: limits overflow" {
    var source: [participants_max * 16 + 32]u8 = undefined;
    var length: usize = (try std.fmt.bufPrint(&source, "sequenceDiagram\n", .{})).len;
    for (0..participants_max + 1) |index| {
        length += (try std.fmt.bufPrint(source[length..], "participant P{d}\n", .{index})).len;
    }
    var fixture: Fixture = .{};
    try testing.expectError(error.Overflow, fixture.run(source[0..length]));

    var nested: [depth_max * 8 + 64]u8 = undefined;
    length = (try std.fmt.bufPrint(&nested, "sequenceDiagram\n", .{})).len;
    for (0..depth_max + 1) |_| {
        length += (try std.fmt.bufPrint(nested[length..], "loop\n", .{})).len;
    }
    try testing.expectError(error.Overflow, fixture.run(nested[0..length]));
}

test "sequence: layout geometry" {
    var fixture: Fixture = .{};
    try fixture.run(sample_full);
    try expect_inside(&fixture.out);
    // Participant boxes appear at the top and bottom, and never overlap.
    var rects: [64]scene.Rect = undefined;
    var rect_count: u32 = 0;
    for (fixture.out.commands_slice()) |command| {
        if (command != .rect or command.rect.fill != .node_fill) continue;
        if (command.rect.rect.width < participant_width_min) continue;
        rects[rect_count] = command.rect.rect;
        rect_count += 1;
    }
    try testing.expectEqual(@as(u32, 8), rect_count);
    for (rects[0..rect_count], 0..) |a, i| {
        for (rects[i + 1 .. rect_count]) |b| {
            const apart_x = a.x + a.width <= b.x or b.x + b.width <= a.x;
            const apart_y = a.y + a.height <= b.y or b.y + b.height <= a.y;
            try testing.expect(apart_x or apart_y);
        }
    }
}

test "sequence: columns widen for long labels" {
    var fixture: Fixture = .{};
    const long = "A->>B: a message label that is much wider than the participant boxes";
    try fixture.run("sequenceDiagram\n" ++ long ++ "\nB->>C: short\n");
    try expect_inside(&fixture.out);
    var lifelines: [3]f32 = undefined;
    var lifeline_count: u32 = 0;
    for (fixture.out.commands_slice()) |command| {
        if (command != .line or command.line.dash != .dashed) continue;
        if (command.line.head_end != .none) continue;
        const points = fixture.out.points_slice(command.line.points);
        if (points[0].x != points[1].x) continue;
        lifelines[lifeline_count] = points[0].x;
        lifeline_count += 1;
    }
    try testing.expectEqual(@as(u32, 3), lifeline_count);
    const label_width = scene.Measurer.fixed.measure(long[7..], .regular).width;
    try testing.expect(lifelines[1] - lifelines[0] >= label_width + 2 * message_padding);
    try testing.expect(lifelines[2] - lifelines[1] < label_width);
}

test "sequence: truncated prefixes never crash" {
    var fixture: Fixture = .{};
    for (0..sample_full.len + 1) |length| {
        fixture.run(sample_full[0..length]) catch continue;
        try expect_inside(&fixture.out);
    }
    // Deleting any single byte must not crash either.
    var mutated: [sample_full.len]u8 = undefined;
    for (0..sample_full.len) |index| {
        @memcpy(mutated[0..index], sample_full[0..index]);
        @memcpy(mutated[index .. sample_full.len - 1], sample_full[index + 1 ..]);
        fixture.run(mutated[0 .. sample_full.len - 1]) catch continue;
        try expect_inside(&fixture.out);
    }
}
