//! Class diagrams (`classDiagram`), laid out by the layered graph engine. Each class is a box
//! with three compartments: annotation and name, attributes, and methods.

const std = @import("std");
const assert = std.debug.assert;
const scene = @import("../scene.zig");
const graph_module = @import("graph.zig");

const Graph = graph_module.Graph;
const Label = graph_module.Label;
const Direction = graph_module.Direction;
const Statements = graph_module.Statements;
const Size = scene.Size;
const Point = scene.Point;
const Rect = scene.Rect;
const Error = scene.Error;
const none = graph_module.none;
const word_is = graph_module.word_is;

const classes_max = graph_module.nodes_max;
const relations_max = graph_module.edges_max;
const namespaces_max = graph_module.clusters_max;
const members_max: u32 = 4096;
const notes_max: u32 = 256;
const scope_depth_max = graph_module.cluster_depth_max;
/// Longest member or name that is rewritten for display (generics, annotations).
const display_length_max: u32 = 256;

const padding_horizontal: f32 = 12;
const padding_compartment: f32 = 6;
const compartment_empty_height: f32 = 10;
const class_width_min: f32 = 80;
const note_padding: f32 = 8;
const cardinality_offset_along: f32 = 10;
const cardinality_offset_across: f32 = 8;
const cardinality_step: f32 = 4;
const cardinality_steps_max: u32 = 16;

const Class = struct {
    id: []const u8,
    /// Display name: the id, or a bracketed label.
    name: []const u8,
    generic: []const u8 = "",
    annotation: []const u8 = "",
    namespace: u32,
    note: []const u8 = "",
};

const Member = struct { class: u32, text: []const u8, method: bool };
const Namespace = struct { parent: u32, name: []const u8 };

const Relation = struct {
    source: u32,
    target: u32,
    head_start: scene.Head,
    head_end: scene.Head,
    dashed: bool,
    cardinality_start: []const u8,
    cardinality_end: []const u8,
    text: []const u8,
};

const ignored_words = [_][]const u8{
    "classDef", "cssClass", "style", "click", "callback", "link", "accTitle", "accDescr",
};

const Parser = struct {
    classes: []Class,
    class_count: u32 = 0,
    members: []Member,
    member_count: u32 = 0,
    relations: []Relation,
    relation_count: u32 = 0,
    namespaces: []Namespace,
    namespace_count: u32 = 0,
    direction: Direction = .top_bottom,
    scopes: [scope_depth_max]u32 = undefined,
    scope_depth: u32 = 0,
    /// The class whose `{ }` body is open, or `none`.
    body: u32 = none,

    fn init(allocator: std.mem.Allocator) Error!Parser {
        return .{
            .classes = allocator.alloc(Class, classes_max) catch return error.Overflow,
            .members = allocator.alloc(Member, members_max) catch return error.Overflow,
            .relations = allocator.alloc(Relation, relations_max) catch return error.Overflow,
            .namespaces = allocator.alloc(Namespace, namespaces_max) catch
                return error.Overflow,
        };
    }

    fn parse(parser: *Parser, source: []const u8) Error!void {
        var statements: Statements = .{ .source = source };
        const header = statements.next() orelse return error.Syntax;
        if (!word_is(header, "classDiagram") and !word_is(header, "classDiagram-v2")) {
            return error.Syntax;
        }
        var count: u32 = 0;
        while (statements.next()) |statement| : (count += 1) {
            assert(count <= source.len);
            if (parser.body != none) {
                try parser.body_parse(statement);
            } else {
                try parser.statement_parse(statement);
            }
        }
        if (parser.body != none or parser.scope_depth != 0) return error.Syntax;
        if (parser.class_count == 0) return error.Syntax;
        assert(parser.class_count <= classes_max);
    }

    fn statement_parse(parser: *Parser, text: []const u8) Error!void {
        assert(text.len > 0);
        assert(parser.body == none);
        if (std.mem.eql(u8, text, "}")) {
            if (parser.scope_depth == 0) return error.Syntax;
            parser.scope_depth -= 1;
            return;
        }
        if (word_is(text, "direction")) {
            const word = std.mem.trim(u8, text["direction".len..], " \t");
            parser.direction = Direction.parse(word) orelse return error.Syntax;
            return;
        }
        for (ignored_words) |word| if (word_is(text, word)) return;
        if (word_is(text, "namespace")) return parser.namespace_open(text["namespace".len..]);
        if (word_is(text, "class")) return parser.declaration_parse(text["class".len..]);
        if (word_is(text, "note")) return parser.note_parse(text["note".len..]);
        if (std.mem.startsWith(u8, text, "<<")) return parser.annotation_parse(text);
        const colon = colon_find(text);
        if (operator_find(text)) |operator| {
            if (operator.line < colon) return parser.relation_parse(text, operator, colon);
        }
        if (colon < text.len) {
            const class = try parser.class_get(text[0..colon]);
            return parser.member_add(class, text[colon + 1 ..]);
        }
        _ = try parser.class_get(text);
    }

    /// Lines inside `class A { }`: members, an annotation, and the closing brace.
    fn body_parse(parser: *Parser, text: []const u8) Error!void {
        assert(parser.body != none);
        var member = text;
        const closes = member.len > 0 and member[member.len - 1] == '}';
        if (closes) member = std.mem.trim(u8, member[0 .. member.len - 1], " \t");
        if (std.mem.startsWith(u8, member, "<<") and std.mem.endsWith(u8, member, ">>")) {
            parser.classes[parser.body].annotation = member[2 .. member.len - 2];
        } else if (member.len > 0) {
            try parser.member_add(parser.body, member);
        }
        if (closes) parser.body = none;
    }

    fn scope(parser: *const Parser) u32 {
        assert(parser.scope_depth <= scope_depth_max);
        return if (parser.scope_depth == 0) none else parser.scopes[parser.scope_depth - 1];
    }

    fn namespace_open(parser: *Parser, text: []const u8) Error!void {
        var name = std.mem.trim(u8, text, " \t");
        if (name.len == 0 or name[name.len - 1] != '{') return error.Syntax;
        name = std.mem.trim(u8, name[0 .. name.len - 1], " \t");
        if (name.len == 0) return error.Syntax;
        if (parser.namespace_count == namespaces_max) return error.Overflow;
        if (parser.scope_depth == scope_depth_max) return error.Overflow;
        parser.namespaces[parser.namespace_count] = .{ .parent = parser.scope(), .name = name };
        parser.scopes[parser.scope_depth] = parser.namespace_count;
        parser.scope_depth += 1;
        parser.namespace_count += 1;
        assert(parser.scope_depth <= scope_depth_max);
    }

    /// `class A`, `class A~T~`, `class A["Label"]`, each optionally opening a `{` body.
    fn declaration_parse(parser: *Parser, text: []const u8) Error!void {
        var rest = std.mem.trim(u8, text, " \t");
        var body_text: []const u8 = "";
        var opens = false;
        if (std.mem.indexOfScalar(u8, rest, '{')) |brace| {
            opens = true;
            body_text = std.mem.trim(u8, rest[brace + 1 ..], " \t");
            rest = std.mem.trimEnd(u8, rest[0..brace], " \t");
        }
        var name: ?[]const u8 = null;
        if (std.mem.indexOf(u8, rest, "[\"")) |open| {
            if (!std.mem.endsWith(u8, rest, "\"]") or rest.len < open + 4) return error.Syntax;
            name = rest[open + 2 .. rest.len - 2];
            rest = rest[0..open];
        }
        const class = try parser.class_get(rest);
        if (name) |value| parser.classes[class].name = value;
        if (!opens) return;
        parser.body = class;
        if (body_text.len > 0) try parser.body_parse(body_text);
        assert(parser.body == none or parser.body == class);
    }

    fn annotation_parse(parser: *Parser, text: []const u8) Error!void {
        assert(std.mem.startsWith(u8, text, "<<"));
        const close = std.mem.indexOf(u8, text, ">>") orelse return error.Syntax;
        const class = try parser.class_get(text[close + 2 ..]);
        parser.classes[class].annotation = text[2..close];
        assert(class < parser.class_count);
    }

    /// `note for A "text"` sits beside its class. Floating notes have no anchor: skipped.
    fn note_parse(parser: *Parser, text: []const u8) Error!void {
        const rest = std.mem.trim(u8, text, " \t");
        if (!word_is(rest, "for")) {
            if (rest.len > 0 and rest[0] == '"') return;
            return error.Syntax;
        }
        const after = std.mem.trim(u8, rest["for".len..], " \t");
        const quote = std.mem.indexOfScalar(u8, after, '"') orelse return error.Syntax;
        const class = try parser.class_get(after[0..quote]);
        const content = graph_module.unquote(after[quote..]);
        if (content.len == 0) return;
        parser.classes[class].note = content;
        assert(class < parser.class_count);
    }

    fn relation_parse(
        parser: *Parser,
        text: []const u8,
        operator: Operator,
        colon: usize,
    ) Error!void {
        assert(operator.start <= operator.line);
        assert(operator.end <= colon);
        if (parser.relation_count == relations_max) return error.Overflow;
        const left = cardinality_split(text[0..operator.start], false);
        const right = cardinality_split(text[operator.end..colon], true);
        const label = if (colon < text.len) std.mem.trim(u8, text[colon + 1 ..], " \t") else "";
        const source = try parser.class_get(left.id);
        const target = try parser.class_get(right.id);
        parser.relations[parser.relation_count] = .{
            .source = source,
            .target = target,
            .head_start = operator.head_start,
            .head_end = operator.head_end,
            .dashed = operator.dashed,
            .cardinality_start = left.cardinality,
            .cardinality_end = right.cardinality,
            .text = graph_module.unquote(label),
        };
        parser.relation_count += 1;
    }

    /// Finds a class by id, or declares it in the current namespace. A `~T~` suffix sets the
    /// generic parameter.
    fn class_get(parser: *Parser, text: []const u8) Error!u32 {
        var id = std.mem.trim(u8, text, " \t");
        if (std.mem.indexOf(u8, id, ":::")) |index| id = std.mem.trimEnd(u8, id[0..index], " \t");
        var generic: []const u8 = "";
        if (std.mem.indexOfScalar(u8, id, '~')) |tilde| {
            if (id.len < tilde + 3 or id[id.len - 1] != '~') return error.Syntax;
            generic = id[tilde + 1 .. id.len - 1];
            id = id[0..tilde];
        }
        if (id.len == 0) return error.Syntax;
        for (id) |byte| if (!graph_module.identifier_char(byte)) return error.Syntax;
        for (parser.classes[0..parser.class_count], 0..) |*class, index| {
            if (!std.mem.eql(u8, class.id, id)) continue;
            if (generic.len > 0) class.generic = generic;
            return @intCast(index);
        }
        if (parser.class_count == classes_max) return error.Overflow;
        parser.classes[parser.class_count] = .{
            .id = id,
            .name = id,
            .generic = generic,
            .namespace = parser.scope(),
        };
        parser.class_count += 1;
        return parser.class_count - 1;
    }

    fn member_add(parser: *Parser, class: u32, text: []const u8) Error!void {
        assert(class < parser.class_count);
        var member = std.mem.trim(u8, text, " \t");
        if (member.len == 0) return;
        // Static (`$`) and abstract (`*`) markers need underline and italics, which text
        // commands lack: they are dropped.
        if (member[member.len - 1] == '$' or member[member.len - 1] == '*') {
            member = std.mem.trimEnd(u8, member[0 .. member.len - 1], " \t");
        }
        if (member.len == 0) return;
        if (parser.member_count == members_max) return error.Overflow;
        parser.members[parser.member_count] = .{
            .class = class,
            .text = member,
            .method = std.mem.indexOfScalar(u8, member, '(') != null,
        };
        parser.member_count += 1;
    }
};

/// The first `:` outside of quotes, or the text length.
fn colon_find(text: []const u8) usize {
    var quoted = false;
    for (text, 0..) |byte, index| {
        if (byte == '"') quoted = !quoted;
        if (byte == ':' and !quoted) return index;
    }
    return text.len;
}

const Operator = struct {
    /// Bounds of the whole operator, markers included, and where its line starts.
    start: usize,
    end: usize,
    line: usize,
    head_start: scene.Head,
    head_end: scene.Head,
    dashed: bool,
};

/// Finds a relation operator such as `<|--`, `*--`, `..>`, or `--`, outside of quotes.
fn operator_find(text: []const u8) ?Operator {
    var quoted = false;
    var index: usize = 0;
    while (index + 1 < text.len) : (index += 1) {
        if (text[index] == '"') quoted = !quoted;
        if (quoted) continue;
        const pair = text[index .. index + 2];
        if (!std.mem.eql(u8, pair, "--") and !std.mem.eql(u8, pair, "..")) continue;
        var operator: Operator = .{
            .start = index,
            .end = index + 2,
            .line = index,
            .head_start = .none,
            .head_end = .none,
            .dashed = pair[0] == '.',
        };
        marker_start(text, &operator);
        marker_end(text, &operator);
        return operator;
    }
    return null;
}

fn marker_start(text: []const u8, operator: *Operator) void {
    const index = operator.line;
    assert(index + 2 <= text.len);
    if (index >= 2 and std.mem.eql(u8, text[index - 2 .. index], "<|")) {
        operator.head_start = .triangle;
        operator.start = index - 2;
    } else if (index >= 1 and marker_standalone(text, index - 1, true)) {
        operator.head_start = head_of(text[index - 1]);
        operator.start = index - 1;
    }
    assert(operator.start <= index);
}

fn marker_end(text: []const u8, operator: *Operator) void {
    const index = operator.line + 2;
    assert(index <= text.len);
    if (index + 2 <= text.len and std.mem.eql(u8, text[index .. index + 2], "|>")) {
        operator.head_end = .triangle;
        operator.end = index + 2;
    } else if (index < text.len and marker_standalone(text, index, false)) {
        operator.head_end = head_of(text[index]);
        operator.end = index + 1;
    }
    assert(operator.end >= index);
}

/// Whether `text[index]` is a one-character marker. Letters such as `o` only count when they
/// stand apart from a class name.
fn marker_standalone(text: []const u8, index: usize, before: bool) bool {
    const byte = text[index];
    if (byte == '<' or byte == '>' or byte == '*') return true;
    if (byte != 'o') return false;
    const at_edge = if (before) index == 0 else index + 1 >= text.len;
    const neighbor = if (at_edge) ' ' else if (before) text[index - 1] else text[index + 1];
    return neighbor == ' ' or neighbor == '\t' or neighbor == '"';
}

fn head_of(byte: u8) scene.Head {
    return switch (byte) {
        '*' => .diamond_filled,
        'o' => .diamond,
        '<', '>' => .arrow_open,
        else => .none,
    };
}

const Side = struct { id: []const u8, cardinality: []const u8 };

/// Splits `A "1"` (left of the operator) or `"*" B` (right of it).
fn cardinality_split(text: []const u8, right: bool) Side {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len < 2) return .{ .id = trimmed, .cardinality = "" };
    if (right and trimmed[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, trimmed, 1, '"') orelse
            return .{ .id = trimmed, .cardinality = "" };
        return .{ .id = trimmed[close + 1 ..], .cardinality = trimmed[1..close] };
    }
    if (!right and trimmed[trimmed.len - 1] == '"') {
        const open = std.mem.lastIndexOfScalar(u8, trimmed[0 .. trimmed.len - 1], '"') orelse
            return .{ .id = trimmed, .cardinality = "" };
        return .{ .id = trimmed[0..open], .cardinality = trimmed[open + 1 .. trimmed.len - 1] };
    }
    return .{ .id = trimmed, .cardinality = "" };
}

// Display text.

/// Rewrites generics (`List~int~` to `List<int>`) and wraps annotations in guillemets. A `~`
/// opens when an identifier follows it, and closes otherwise.
fn display_write(buffer: []u8, text: []const u8, annotation: bool) Error![]const u8 {
    var length: usize = 0;
    const extra: usize = if (annotation) 4 else 0;
    if (text.len + extra > buffer.len) return error.Overflow;
    if (annotation) {
        @memcpy(buffer[0..2], "«");
        length = 2;
    }
    for (text, 0..) |byte, index| {
        var value = byte;
        if (byte == '~') {
            const next = if (index + 1 < text.len) text[index + 1] else ' ';
            const opens = graph_module.identifier_char(next) and next != '-';
            value = if (opens) '<' else '>';
        }
        buffer[length] = value;
        length += 1;
    }
    if (annotation) {
        @memcpy(buffer[length..][0..2], "»");
        length += 2;
    }
    assert(length <= buffer.len);
    return buffer[0..length];
}

fn display_measure(
    measurer: scene.Measurer,
    text: []const u8,
    font: scene.Font,
    annotation: bool,
) Error!Size {
    var buffer: [display_length_max]u8 = undefined;
    return measurer.measure(try display_write(&buffer, text, annotation), font);
}

/// Text bytes for a text command: the source itself when nothing changes for display.
fn display_bytes(out: *scene.Scene, text: []const u8, annotation: bool) Error![]const u8 {
    if (!annotation and std.mem.indexOfScalar(u8, text, '~') == null) return text;
    var buffer: [display_length_max]u8 = undefined;
    return out.text_add(try display_write(&buffer, text, annotation));
}

fn name_text(class: Class, buffer: []u8) Error![]const u8 {
    if (class.generic.len == 0) return class.name;
    const printed = std.fmt.bufPrint(buffer, "{s}~{s}~", .{ class.name, class.generic }) catch
        return error.Overflow;
    return printed;
}

// Layout.

/// Heights of the three compartments of one class box.
const Box = struct {
    name: f32,
    attributes: f32,
    methods: f32,
    width: f32,

    fn height(box: Box) f32 {
        return box.name + box.attributes + box.methods;
    }
};

fn box_measure(parser: *const Parser, class: u32, measurer: scene.Measurer) Error!Box {
    const value = parser.classes[class];
    var buffer: [display_length_max]u8 = undefined;
    const name = try display_measure(measurer, try name_text(value, &buffer), .bold, false);
    var box: Box = .{
        .name = name.height + 2 * padding_compartment,
        .attributes = 2 * padding_compartment,
        .methods = 2 * padding_compartment,
        .width = name.width,
    };
    if (value.annotation.len > 0) {
        const annotation = try display_measure(measurer, value.annotation, .small, true);
        box.name += annotation.height;
        box.width = @max(box.width, annotation.width);
    }
    for (parser.members[0..parser.member_count]) |member| {
        if (member.class != class) continue;
        const size = try display_measure(measurer, member.text, .regular, false);
        box.width = @max(box.width, size.width);
        if (member.method) box.methods += size.height else box.attributes += size.height;
    }
    box.attributes = @max(box.attributes, compartment_empty_height);
    box.methods = @max(box.methods, compartment_empty_height);
    box.width = @max(class_width_min, box.width + 2 * padding_horizontal);
    assert(box.height() > 0);
    assert(box.width > 0);
    return box;
}

const Labels = struct {
    boxes: []Box,
    notes: []Label,
    relations: []Label,
    titles: []Label,
};

fn graph_build(
    parser: *const Parser,
    graph: *Graph,
    labels: *Labels,
    measurer: scene.Measurer,
) Error!void {
    for (parser.namespaces[0..parser.namespace_count], 0..) |namespace, index| {
        labels.titles[index] = try Label.init(namespace.name, measurer, .regular);
        _ = try graph.cluster_add(namespace.parent, labels.titles[index].size);
    }
    for (parser.classes[0..parser.class_count], 0..) |class, index| {
        const box = try box_measure(parser, @intCast(index), measurer);
        labels.boxes[index] = box;
        const size: Size = .{ .width = box.width, .height = box.height() };
        const node = try graph.node_add(size, .rect, class.namespace);
        assert(node == index);
        if (class.note.len == 0) continue;
        labels.notes[node] = try Label.init(class.note, measurer, .regular);
        graph.nodes[node].attachment = .{
            .width = labels.notes[node].size.width + 2 * note_padding,
            .height = labels.notes[node].size.height + 2 * note_padding,
        };
    }
    for (parser.relations[0..parser.relation_count], 0..) |relation, index| {
        var label_size: Size = .{ .width = 0, .height = 0 };
        if (relation.text.len > 0) {
            labels.relations[index] = try Label.init(relation.text, measurer, .small);
            label_size = labels.relations[index].size;
        }
        _ = try graph.edge_add(relation.source, relation.target, label_size, 1);
    }
    assert(graph.node_count == parser.class_count);
    assert(graph.edge_count == parser.relation_count);
}

// Drawing.

fn class_draw(
    parser: *const Parser,
    class: u32,
    box: Box,
    rect: Rect,
    measurer: scene.Measurer,
    out: *scene.Scene,
) Error!void {
    const value = parser.classes[class];
    try out.command_add(.{ .rect = .{
        .rect = rect,
        .radius = 3,
        .fill = .node_fill,
        .stroke = .node_stroke,
    } });
    const center_x = rect.x + rect.width / 2;
    var y = rect.y + padding_compartment;
    if (value.annotation.len > 0) {
        const height = (try display_measure(measurer, value.annotation, .small, true)).height;
        try out.command_add(.{ .text = .{
            .origin = .{ .x = center_x, .y = y + height / 2 },
            .font = .small,
            .bytes = try display_bytes(out, value.annotation, true),
        } });
        y += height;
    }
    var buffer: [display_length_max]u8 = undefined;
    const name = try name_text(value, &buffer);
    const name_height = (try display_measure(measurer, name, .bold, false)).height;
    try out.command_add(.{ .text = .{
        .origin = .{ .x = center_x, .y = y + name_height / 2 },
        .font = .bold,
        .bytes = try display_bytes(out, name, false),
    } });
    const divider_first = rect.y + box.name;
    const divider_second = divider_first + box.attributes;
    try divider_draw(out, rect, divider_first);
    try divider_draw(out, rect, divider_second);
    try members_draw(parser, class, false, rect.x, divider_first, measurer, out);
    try members_draw(parser, class, true, rect.x, divider_second, measurer, out);
    assert(divider_second <= rect.y + rect.height);
}

fn divider_draw(out: *scene.Scene, rect: Rect, y: f32) Error!void {
    assert(y >= rect.y);
    assert(y <= rect.y + rect.height);
    const ends = [2]Point{ .{ .x = rect.x, .y = y }, .{ .x = rect.x + rect.width, .y = y } };
    const range = try out.points_add(&ends);
    try out.command_add(.{ .line = .{ .points = range, .stroke = .node_stroke } });
}

fn members_draw(
    parser: *const Parser,
    class: u32,
    methods: bool,
    left: f32,
    top: f32,
    measurer: scene.Measurer,
    out: *scene.Scene,
) Error!void {
    assert(class < parser.class_count);
    var y = top + padding_compartment;
    for (parser.members[0..parser.member_count]) |member| {
        if (member.class != class or member.method != methods) continue;
        const height = (try display_measure(measurer, member.text, .regular, false)).height;
        try out.command_add(.{ .text = .{
            .origin = .{ .x = left + padding_horizontal, .y = y + height / 2 },
            .anchor = .start,
            .bytes = try display_bytes(out, member.text, false),
        } });
        y += height;
    }
    assert(y >= top);
}

fn relation_style(relation: Relation) graph_module.EdgeStyle {
    return .{
        .dash = if (relation.dashed) .dashed else .solid,
        .head_start = relation.head_start,
        .head_end = relation.head_end,
    };
}

/// Places a cardinality beside the route, a little way from the end it describes, on the side
/// away from the node, and pushed along the route until it clears the node box.
fn cardinality_draw(
    out: *scene.Scene,
    measurer: scene.Measurer,
    size: Size,
    node: Rect,
    end: Point,
    toward: Point,
    text: []const u8,
) Error!void {
    const text_size = measurer.measure(text, .small);
    const dx = toward.x - end.x;
    const dy = toward.y - end.y;
    const length = @max(@sqrt(dx * dx + dy * dy), 0.001);
    const along: Point = .{ .x = dx / length, .y = dy / length };
    var across: Point = .{ .x = -along.y, .y = along.x };
    const center: Point = .{ .x = node.x + node.width / 2, .y = node.y + node.height / 2 };
    if (across.x * (end.x - center.x) + across.y * (end.y - center.y) < 0) {
        across = .{ .x = -across.x, .y = -across.y };
    }
    const distance_across = cardinality_offset_across + text_size.width / 2;
    var distance_along = cardinality_offset_along + text_size.height / 2;
    var origin: Point = undefined;
    var step: u32 = 0;
    while (step < cardinality_steps_max) : (step += 1) {
        origin = .{
            .x = end.x + along.x * distance_along + across.x * distance_across,
            .y = end.y + along.y * distance_along + across.y * distance_across,
        };
        if (!rects_overlap(graph_module.rect_centered(origin, text_size), node)) break;
        distance_along += cardinality_step;
    }
    // Keep the text inside the scene even where a route ends near the margin.
    origin.x = std.math.clamp(origin.x, text_size.width / 2, size.width - text_size.width / 2);
    origin.y = std.math.clamp(origin.y, text_size.height / 2, size.height - text_size.height / 2);
    try out.command_add(.{ .text = .{ .origin = origin, .font = .small, .bytes = text } });
    assert(origin.x >= 0);
    assert(origin.y >= 0);
}

fn rects_overlap(a: Rect, b: Rect) bool {
    return a.x < b.x + b.width and b.x < a.x + a.width and
        a.y < b.y + b.height and b.y < a.y + a.height;
}

fn cardinalities_draw(
    relation: Relation,
    graph: *const Graph,
    edge: u32,
    measurer: scene.Measurer,
    out: *scene.Scene,
) Error!void {
    const points = graph.edge_points(edge);
    assert(points.len >= 2);
    const last = points.len - 1;
    if (relation.cardinality_start.len > 0) {
        const node = graph_module.node_rect(graph.nodes[relation.source]);
        const text = relation.cardinality_start;
        try cardinality_draw(out, measurer, graph.size, node, points[0], points[1], text);
    }
    if (relation.cardinality_end.len > 0) {
        const node = graph_module.node_rect(graph.nodes[relation.target]);
        const text = relation.cardinality_end;
        try cardinality_draw(out, measurer, graph.size, node, points[last], points[last - 1], text);
    }
}

fn draw(
    parser: *const Parser,
    graph: *const Graph,
    labels: *const Labels,
    measurer: scene.Measurer,
    out: *scene.Scene,
) Error!void {
    try graph_module.clusters_draw(out, graph, measurer, labels.titles);
    for (parser.relations[0..parser.relation_count], 0..) |relation, index| {
        try graph_module.edge_draw(out, graph, @intCast(index), relation_style(relation));
    }
    for (graph.nodes[0..graph.node_count], 0..) |node, index| {
        const rect = graph_module.node_rect(node);
        try class_draw(parser, @intCast(index), labels.boxes[index], rect, measurer, out);
        if (node.attachment.width == 0) continue;
        try out.command_add(.{ .rect = .{
            .rect = graph_module.rect_centered(node.attachment_center, node.attachment),
            .radius = 2,
            .fill = .note_fill,
            .stroke = .note_stroke,
        } });
        try labels.notes[index].draw(out, measurer, node.attachment_center, .text);
    }
    for (parser.relations[0..parser.relation_count], 0..) |relation, index| {
        if (relation.text.len > 0) {
            const center = graph.edges[index].label_center;
            try labels.relations[index].draw(out, measurer, center, .text);
        }
        try cardinalities_draw(relation, graph, @intCast(index), measurer, out);
    }
}

pub fn render(
    source: []const u8,
    measurer: scene.Measurer,
    scratch: []u8,
    out: *scene.Scene,
) scene.Error!void {
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const allocator = fixed.allocator();
    var parser = try Parser.init(allocator);
    try parser.parse(source);
    var graph = try Graph.init(allocator, parser.direction);
    var labels: Labels = .{
        .boxes = allocator.alloc(Box, classes_max) catch return error.Overflow,
        .notes = allocator.alloc(Label, classes_max) catch return error.Overflow,
        .relations = allocator.alloc(Label, relations_max) catch return error.Overflow,
        .titles = allocator.alloc(Label, namespaces_max) catch return error.Overflow,
    };
    try graph_build(&parser, &graph, &labels, measurer);
    try graph.layout(allocator);
    try draw(&parser, &graph, &labels, measurer, out);
    out.size = graph.size;
    assert(out.size.width > 0);
    assert(out.size.height > 0);
}

// Tests.

const testing = std.testing;

fn parse_test(source: []const u8, scratch: []u8) !Parser {
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    var parser = try Parser.init(fixed.allocator());
    try parser.parse(source);
    return parser;
}

const sample =
    \\classDiagram
    \\  class Animal {
    \\    <<abstract>>
    \\    +String name
    \\    +int age
    \\    +makeSound() void
    \\  }
    \\  class Duck {
    \\    +String beakColor
    \\    +swim()
    \\    +quack()
    \\  }
    \\  class Fish { -int sizeInFeet; -canEat() }
    \\  class Zebra
    \\  Zebra : +bool is_wild
    \\  Zebra : +run()
    \\  Animal <|-- Duck
    \\  Animal <|-- Fish
    \\  Animal <|-- Zebra
    \\  class Repository~T~
    \\  <<interface>> Repository
    \\  Repository : +find(id) List~T~
    \\  Zoo "1" *-- "many" Animal : houses
    \\  Zoo o-- Keeper
    \\  Keeper ..> Repository : uses
    \\  Zoo ..|> Repository
    \\  Keeper --> Duck
    \\  Keeper -- Fish
    \\  Keeper .. Zebra
    \\  note for Zoo "Open daily"
;

test "class: parse classes, members, and relations" {
    const scratch = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(scratch);
    const parser = try parse_test(sample, scratch);
    try testing.expectEqualStrings("Animal", parser.classes[0].id);
    try testing.expectEqualStrings("abstract", parser.classes[0].annotation);
    try testing.expectEqual(@as(u32, 1), parser.relations[0].target);
    try testing.expectEqual(scene.Head.triangle, parser.relations[0].head_start);
    var methods: u32 = 0;
    for (parser.members[0..parser.member_count]) |member| {
        if (member.class == 2 and member.method) methods += 1;
    }
    try testing.expectEqual(@as(u32, 1), methods);
    const repository = parser.classes[4];
    try testing.expectEqualStrings("T", repository.generic);
    try testing.expectEqualStrings("interface", repository.annotation);
    const houses = parser.relations[3];
    try testing.expectEqual(scene.Head.diamond_filled, houses.head_start);
    try testing.expectEqualStrings("1", houses.cardinality_start);
    try testing.expectEqualStrings("many", houses.cardinality_end);
    try testing.expectEqualStrings("houses", houses.text);
    try testing.expectEqual(scene.Head.diamond, parser.relations[4].head_start);
    try testing.expect(parser.relations[5].dashed);
    try testing.expectEqual(scene.Head.arrow_open, parser.relations[5].head_end);
    try testing.expectEqual(scene.Head.triangle, parser.relations[6].head_end);
    try testing.expectEqual(scene.Head.none, parser.relations[8].head_end);
    try testing.expect(parser.relations[9].dashed);
}

test "class: display text rewrites generics" {
    var buffer: [64]u8 = undefined;
    const nested = try display_write(&buffer, "List~List~int~~", false);
    try testing.expectEqualStrings("List<List<int>>", nested);
    try testing.expectEqualStrings("«interface»", try display_write(&buffer, "interface", true));
    try testing.expectError(error.Overflow, display_write(buffer[0..4], "abcdef", false));
}

test "class: malformed input" {
    const scratch = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(scratch);
    const bad = [_][]const u8{
        "classDiagram",
        "classDiagram\n  class A {\n  +x",
        "classDiagram\n  }",
        "classDiagram\n  A <|-- ",
        "classDiagram\n  class A~T",
        "classDiagram\n  note over A",
        "classDiagram\n  a b c",
    };
    for (bad) |source| try testing.expectError(error.Syntax, parse_test(source, scratch));
}

test "class: too many members overflow" {
    const source = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(source);
    var writer = std.Io.Writer.fixed(source);
    try writer.writeAll("classDiagram\n");
    var index: u32 = 0;
    while (index < members_max + 1) : (index += 1) try writer.print("A : +m{d}\n", .{index});
    const scratch = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(scratch);
    try testing.expectError(error.Overflow, parse_test(writer.buffered(), scratch));
}

test "class: render sample inside the scene without overlaps" {
    const scratch = try testing.allocator.alloc(u8, 8 << 20);
    defer testing.allocator.free(scratch);
    var commands: [4096]scene.Command = undefined;
    var points: [16384]Point = undefined;
    var text: [4096]u8 = undefined;
    var out = scene.Scene.init(&commands, &points, &text);
    try render(sample, scene.Measurer.fixed, scratch, &out);
    try graph_module.testing.scene_check(&out);
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const allocator = fixed.allocator();
    var parser = try Parser.init(allocator);
    try parser.parse(sample);
    var graph = try Graph.init(allocator, parser.direction);
    var labels: Labels = .{
        .boxes = try allocator.alloc(Box, classes_max),
        .notes = try allocator.alloc(Label, classes_max),
        .relations = try allocator.alloc(Label, relations_max),
        .titles = try allocator.alloc(Label, namespaces_max),
    };
    try graph_build(&parser, &graph, &labels, scene.Measurer.fixed);
    try graph.layout(allocator);
    try graph_module.testing.nodes_disjoint(&graph);
}

test "class: every prefix renders or fails cleanly" {
    try graph_module.testing.prefixes_render(sample, render);
}
