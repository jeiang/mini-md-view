//! State diagrams (`stateDiagram`, `stateDiagram-v2`), laid out by the layered graph engine.
//! Composite states become clusters, notes become attachments beside their state.

const std = @import("std");
const assert = std.debug.assert;
const scene = @import("../scene.zig");
const graph_module = @import("graph.zig");

const Graph = graph_module.Graph;
const Label = graph_module.Label;
const Direction = graph_module.Direction;
const Statements = graph_module.Statements;
const Size = scene.Size;
const Error = scene.Error;
const none = graph_module.none;
const word_is = graph_module.word_is;

const states_max = graph_module.nodes_max;
const transitions_max = graph_module.edges_max;
const composites_max = graph_module.clusters_max;
const descriptions_max: u32 = 2048;
const notes_max: u32 = 256;
const note_lines_max = graph_module.label_lines_max;
const scope_depth_max = graph_module.cluster_depth_max;

const padding_horizontal: f32 = 16;
const padding_vertical: f32 = 10;
const note_padding: f32 = 8;
const state_width_min: f32 = 56;
const start_diameter: f32 = 14;
const end_diameter: f32 = 18;
const choice_diameter: f32 = 28;
const bar_length: f32 = 72;
const bar_thickness: f32 = 7;

const Kind = enum { normal, start, end, choice, fork, join };

const State = struct {
    /// Empty for the start and end pseudo-states, which are unique per scope instead.
    id: []const u8,
    /// Display text from `state "Name" as id`; the id otherwise.
    name: []const u8,
    kind: Kind,
    /// The composite that contains the state, or `none` at the top level.
    scope: u32,
    /// The composite this state is, if it has a body.
    composite: u32 = none,
    note: u32 = none,
};

const Composite = struct { state: u32, parent: u32 };
const Description = struct { state: u32, text: []const u8 };
const Transition = struct { source: u32, target: u32, text: []const u8 };

const Note = struct {
    state: u32,
    before: bool,
    lines: [note_lines_max][]const u8 = undefined,
    line_count: u32 = 0,
};

const ignored_words = [_][]const u8{
    "classDef", "class", "style", "linkStyle", "click", "hide", "scale", "accTitle", "accDescr",
};

const Parser = struct {
    states: []State,
    state_count: u32 = 0,
    transitions: []Transition,
    transition_count: u32 = 0,
    composites: []Composite,
    composite_count: u32 = 0,
    descriptions: []Description,
    description_count: u32 = 0,
    notes: []Note,
    note_count: u32 = 0,
    direction: Direction = .top_bottom,
    scopes: [scope_depth_max]u32 = undefined,
    scope_depth: u32 = 0,

    fn init(allocator: std.mem.Allocator) Error!Parser {
        return .{
            .states = allocator.alloc(State, states_max) catch return error.Overflow,
            .transitions = allocator.alloc(Transition, transitions_max) catch
                return error.Overflow,
            .composites = allocator.alloc(Composite, composites_max) catch
                return error.Overflow,
            .descriptions = allocator.alloc(Description, descriptions_max) catch
                return error.Overflow,
            .notes = allocator.alloc(Note, notes_max) catch return error.Overflow,
        };
    }

    fn parse(parser: *Parser, source: []const u8) Error!void {
        var statements: Statements = .{ .source = source };
        const header = statements.next() orelse return error.Syntax;
        if (!word_is(header, "stateDiagram") and !word_is(header, "stateDiagram-v2")) {
            return error.Syntax;
        }
        var count: u32 = 0;
        while (statements.next()) |statement| : (count += 1) {
            assert(count <= source.len);
            try parser.statement_parse(statement, &statements);
        }
        if (parser.scope_depth != 0) return error.Syntax;
        if (parser.state_count == 0) return error.Syntax;
        assert(parser.state_count <= states_max);
    }

    fn scope(parser: *const Parser) u32 {
        assert(parser.scope_depth <= scope_depth_max);
        return if (parser.scope_depth == 0) none else parser.scopes[parser.scope_depth - 1];
    }

    fn statement_parse(parser: *Parser, text: []const u8, statements: *Statements) Error!void {
        assert(text.len > 0);
        if (std.mem.eql(u8, text, "}")) {
            if (parser.scope_depth == 0) return error.Syntax;
            parser.scope_depth -= 1;
            return;
        }
        if (word_is(text, "direction")) {
            const word = std.mem.trim(u8, text["direction".len..], " \t");
            const direction = Direction.parse(word) orelse return error.Syntax;
            // Composite states share the diagram direction: the engine lays out one graph.
            if (parser.scope_depth == 0) parser.direction = direction;
            return;
        }
        for (ignored_words) |word| if (word_is(text, word)) return;
        if (std.mem.eql(u8, text, "--")) return;
        if (word_is(text, "note")) return parser.note_parse(text["note".len..], statements);
        if (word_is(text, "state")) return parser.declaration_parse(text["state".len..]);
        if (std.mem.indexOf(u8, text, "-->")) |arrow| return parser.transition_parse(text, arrow);
        if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
            if (colon + 2 < text.len and text[colon + 1] == ':' and text[colon + 2] == ':') {
                _ = try parser.state_get(text);
                return;
            }
            const state = try parser.state_get(text[0..colon]);
            const description = std.mem.trim(u8, text[colon + 1 ..], " \t");
            if (description.len == 0) return;
            if (parser.description_count == descriptions_max) return error.Overflow;
            parser.descriptions[parser.description_count] = .{
                .state = state,
                .text = description,
            };
            parser.description_count += 1;
            return;
        }
        _ = try parser.state_get(text);
    }

    fn transition_parse(parser: *Parser, text: []const u8, arrow: usize) Error!void {
        assert(arrow + 3 <= text.len);
        const rest = text[arrow + 3 ..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
        const source = try parser.endpoint_get(text[0..arrow], false);
        const target = try parser.endpoint_get(rest[0..colon], true);
        const label = if (colon < rest.len) std.mem.trim(u8, rest[colon + 1 ..], " \t") else "";
        if (parser.transition_count == transitions_max) return error.Overflow;
        parser.transitions[parser.transition_count] = .{
            .source = source,
            .target = target,
            .text = graph_module.unquote(label),
        };
        parser.transition_count += 1;
        assert(source < parser.state_count);
        assert(target < parser.state_count);
    }

    /// `[*]` is the start of the current scope as a source, and its end as a target.
    fn endpoint_get(parser: *Parser, text: []const u8, target: bool) Error!u32 {
        const trimmed = std.mem.trim(u8, text, " \t");
        if (!std.mem.eql(u8, trimmed, "[*]")) return parser.state_get(trimmed);
        const kind: Kind = if (target) .end else .start;
        const scope_current = parser.scope();
        for (parser.states[0..parser.state_count], 0..) |state, index| {
            if (state.kind == kind and state.scope == scope_current) return @intCast(index);
        }
        return parser.state_add(.{ .id = "", .name = "", .kind = kind, .scope = scope_current });
    }

    /// Finds a state by id, or declares it in the current scope.
    fn state_get(parser: *Parser, text: []const u8) Error!u32 {
        const id = try identifier_parse(text);
        assert(id.len > 0);
        for (parser.states[0..parser.state_count], 0..) |state, index| {
            if (std.mem.eql(u8, state.id, id)) return @intCast(index);
        }
        return parser.state_add(.{
            .id = id,
            .name = id,
            .kind = .normal,
            .scope = parser.scope(),
        });
    }

    fn state_add(parser: *Parser, state: State) Error!u32 {
        assert(state.scope == none or state.scope < parser.composite_count);
        if (parser.state_count == states_max) return error.Overflow;
        parser.states[parser.state_count] = state;
        parser.state_count += 1;
        return parser.state_count - 1;
    }

    /// `state "Name" as id`, `state id <<choice>>`, and `state id {` to open a composite.
    fn declaration_parse(parser: *Parser, text: []const u8) Error!void {
        var rest = std.mem.trim(u8, text, " \t");
        const opens = rest.len > 0 and rest[rest.len - 1] == '{';
        if (opens) rest = std.mem.trimEnd(u8, rest[0 .. rest.len - 1], " \t");
        var name: ?[]const u8 = null;
        if (rest.len > 0 and rest[0] == '"') {
            const close = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return error.Syntax;
            name = rest[1..close];
            rest = std.mem.trim(u8, rest[close + 1 ..], " \t");
            if (!word_is(rest, "as")) return error.Syntax;
            rest = std.mem.trim(u8, rest["as".len..], " \t");
        }
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const state = try parser.state_get(rest[0..end]);
        const kind = try stereotype_parse(std.mem.trim(u8, rest[end..], " \t"));
        if (name) |value| parser.states[state].name = value;
        if (kind != .normal) parser.states[state].kind = kind;
        if (opens) try parser.composite_open(state);
    }

    fn composite_open(parser: *Parser, state: u32) Error!void {
        assert(state < parser.state_count);
        if (parser.states[state].kind != .normal) return error.Syntax;
        if (parser.states[state].composite == none) {
            if (parser.composite_count == composites_max) return error.Overflow;
            parser.composites[parser.composite_count] = .{
                .state = state,
                .parent = parser.scope(),
            };
            parser.states[state].composite = parser.composite_count;
            parser.composite_count += 1;
        }
        if (parser.scope_depth == scope_depth_max) return error.Overflow;
        parser.scopes[parser.scope_depth] = parser.states[state].composite;
        parser.scope_depth += 1;
        assert(parser.scope_depth <= scope_depth_max);
    }

    /// `note left of id : text`, or a block of lines that ends at `end note`.
    fn note_parse(parser: *Parser, text: []const u8, statements: *Statements) Error!void {
        var rest = std.mem.trim(u8, text, " \t");
        // Floating notes (`note "text" as N`) have no state to sit beside: they are skipped.
        if (rest.len > 0 and rest[0] == '"') return;
        const before = word_is(rest, "left");
        if (!before and !word_is(rest, "right")) return error.Syntax;
        rest = std.mem.trim(u8, rest[if (before) "left".len else "right".len..], " \t");
        if (!word_is(rest, "of")) return error.Syntax;
        rest = rest["of".len..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
        const state = try parser.state_get(rest[0..colon]);
        const note = try parser.note_get(state, before);
        if (colon < rest.len) return note_line_add(note, rest[colon + 1 ..]);
        var count: u32 = 0;
        while (statements.next()) |line| : (count += 1) {
            assert(count <= statements.source.len);
            if (std.mem.eql(u8, line, "end note")) return;
            try note_line_add(note, line);
        }
        return error.Syntax;
    }

    /// Several notes on one state merge into one, since a state has a single attachment.
    fn note_get(parser: *Parser, state: u32, before: bool) Error!*Note {
        assert(state < parser.state_count);
        if (parser.states[state].note != none) return &parser.notes[parser.states[state].note];
        if (parser.note_count == notes_max) return error.Overflow;
        parser.notes[parser.note_count] = .{ .state = state, .before = before };
        parser.states[state].note = parser.note_count;
        parser.note_count += 1;
        assert(parser.note_count <= notes_max);
        return &parser.notes[parser.note_count - 1];
    }
};

fn note_line_add(note: *Note, text: []const u8) Error!void {
    assert(note.line_count <= note_lines_max);
    if (note.line_count == note_lines_max) return error.Overflow;
    note.lines[note.line_count] = std.mem.trim(u8, text, " \t");
    note.line_count += 1;
}

/// A state id, with any `:::class` suffix removed.
fn identifier_parse(text: []const u8) Error![]const u8 {
    var id = std.mem.trim(u8, text, " \t");
    if (std.mem.indexOf(u8, id, ":::")) |index| id = std.mem.trimEnd(u8, id[0..index], " \t");
    if (id.len == 0) return error.Syntax;
    for (id) |byte| {
        if (!graph_module.identifier_char(byte) and byte != '.') return error.Syntax;
    }
    assert(id.len > 0);
    return id;
}

fn stereotype_parse(text: []const u8) Error!Kind {
    var rest = text;
    if (std.mem.indexOf(u8, rest, ":::")) |index| rest = std.mem.trimEnd(u8, rest[0..index], " \t");
    if (rest.len == 0) return .normal;
    if (std.mem.eql(u8, rest, "<<choice>>")) return .choice;
    if (std.mem.eql(u8, rest, "<<fork>>")) return .fork;
    if (std.mem.eql(u8, rest, "<<join>>")) return .join;
    return error.Syntax;
}

// Layout.

const Labels = struct {
    states: []Label,
    notes: []Label,
    transitions: []Label,
    titles: []Label,
};

/// Appends the lines of `text` to `label`, so that one label can gather several sources.
fn label_append(label: *Label, text: []const u8, measurer: scene.Measurer) Error!void {
    const part = try Label.init(text, measurer, label.font);
    assert(part.line_count >= 1);
    if (label.line_count + part.line_count > graph_module.label_lines_max) return error.Overflow;
    for (part.lines[0..part.line_count]) |line| {
        label.lines[label.line_count] = line;
        label.line_count += 1;
    }
    label.size.width = @max(label.size.width, part.size.width);
    label.size.height += part.size.height;
}

fn state_label(parser: *const Parser, state: u32, measurer: scene.Measurer) Error!Label {
    var label: Label = .{ .font = .regular };
    for (parser.descriptions[0..parser.description_count]) |description| {
        if (description.state == state) try label_append(&label, description.text, measurer);
    }
    if (label.line_count == 0) try label_append(&label, parser.states[state].name, measurer);
    assert(label.line_count >= 1);
    return label;
}

fn state_size(kind: Kind, label: Size, direction: Direction) Size {
    assert(label.width >= 0);
    const bar_across: Size = .{ .width = bar_length, .height = bar_thickness };
    const bar_along: Size = .{ .width = bar_thickness, .height = bar_length };
    return switch (kind) {
        .normal => .{
            .width = @max(state_width_min, label.width + 2 * padding_horizontal),
            .height = label.height + 2 * padding_vertical,
        },
        .start => .{ .width = start_diameter, .height = start_diameter },
        .end => .{ .width = end_diameter, .height = end_diameter },
        .choice => .{ .width = choice_diameter, .height = choice_diameter },
        // Bars lie across the flow, so that every branch meets them head-on.
        .fork, .join => if (direction.horizontal()) bar_along else bar_across,
    };
}

fn shape_of(kind: Kind) graph_module.Shape {
    return switch (kind) {
        .normal => .rect_round,
        .start => .start,
        .end => .end,
        .choice => .diamond,
        .fork, .join => .bar,
    };
}

fn graph_build(
    parser: *const Parser,
    graph: *Graph,
    labels: *Labels,
    measurer: scene.Measurer,
    node_map: []u32,
) Error!void {
    for (parser.composites[0..parser.composite_count], 0..) |composite, index| {
        labels.titles[index] = try state_label(parser, composite.state, measurer);
        _ = try graph.cluster_add(composite.parent, labels.titles[index].size);
    }
    for (parser.states[0..parser.state_count], 0..) |state, index| {
        node_map[index] = none;
        if (state.composite != none) continue;
        const label = try state_label(parser, @intCast(index), measurer);
        const size = state_size(state.kind, label.size, parser.direction);
        const node = try graph.node_add(size, shape_of(state.kind), state.scope);
        labels.states[node] = label;
        node_map[index] = node;
        if (state.note != none) try note_attach(parser, graph, labels, measurer, node, state.note);
    }
    if (graph.node_count == 0) return error.Syntax;
    for (parser.transitions[0..parser.transition_count], 0..) |transition, index| {
        const source = try endpoint_resolve(parser, graph, node_map, transition.source, false);
        const target = try endpoint_resolve(parser, graph, node_map, transition.target, true);
        var label_size: Size = .{ .width = 0, .height = 0 };
        if (transition.text.len > 0) {
            labels.transitions[index] = try Label.init(transition.text, measurer, .small);
            label_size = labels.transitions[index].size;
        }
        _ = try graph.edge_add(source, target, label_size, 1);
    }
    assert(graph.edge_count == parser.transition_count);
}

fn note_attach(
    parser: *const Parser,
    graph: *Graph,
    labels: *Labels,
    measurer: scene.Measurer,
    node: u32,
    note_index: u32,
) Error!void {
    const note = &parser.notes[note_index];
    assert(note.line_count >= 1);
    var label: Label = .{ .font = .regular };
    for (note.lines[0..note.line_count]) |line| try label_append(&label, line, measurer);
    labels.notes[node] = label;
    graph.nodes[node].attachment = .{
        .width = label.size.width + 2 * note_padding,
        .height = label.size.height + 2 * note_padding,
    };
    graph.nodes[node].attachment_before = note.before;
    assert(graph.nodes[node].attachment.width > 0);
}

/// A transition that names a composite attaches to its first member as a target and its last
/// member as a source; the route is clipped to the composite box after layout.
fn endpoint_resolve(
    parser: *const Parser,
    graph: *Graph,
    node_map: []const u32,
    state: u32,
    first: bool,
) Error!u32 {
    if (node_map[state] != none) return node_map[state];
    const composite = parser.states[state].composite;
    assert(composite != none);
    const member = graph.cluster_member(composite, first);
    if (member != none) return member;
    const title = graph.clusters[composite].title;
    return graph.node_add(.{ .width = @max(title.width, 40), .height = 16 }, .hidden, composite);
}

fn composites_clip(parser: *const Parser, graph: *Graph) void {
    for (parser.transitions[0..parser.transition_count], 0..) |transition, index| {
        const edge: u32 = @intCast(index);
        const source = parser.states[transition.source].composite;
        const target = parser.states[transition.target].composite;
        const routed = graph.edges[edge];
        if (routed.source == routed.target) continue;
        if (source != none and !node_within(graph, routed.target, source)) {
            graph_module.route_clip_to_cluster(graph, edge, source, false);
        }
        if (target != none and !node_within(graph, routed.source, target)) {
            graph_module.route_clip_to_cluster(graph, edge, target, true);
        }
    }
}

fn node_within(graph: *const Graph, node: u32, cluster: u32) bool {
    assert(node < graph.node_count);
    const value = graph.nodes[node].cluster;
    return value != none and graph.cluster_within(value, cluster);
}

// Drawing.

fn draw(
    parser: *const Parser,
    graph: *const Graph,
    labels: *const Labels,
    measurer: scene.Measurer,
    out: *scene.Scene,
) Error!void {
    try graph_module.clusters_draw(out, graph, measurer, labels.titles);
    var edge: u32 = 0;
    while (edge < graph.edge_count) : (edge += 1) {
        try graph_module.edge_draw(out, graph, edge, .{ .head_end = .arrow });
    }
    for (graph.nodes[0..graph.node_count], 0..) |node, index| {
        if (node.shape == .hidden) continue;
        try graph_module.shape_draw(out, node.shape, graph_module.node_rect(node));
        if (node.shape == .rect_round) {
            try labels.states[index].draw(out, measurer, node.center, .text);
        }
        if (node.attachment.width == 0) continue;
        try out.command_add(.{ .rect = .{
            .rect = graph_module.rect_centered(node.attachment_center, node.attachment),
            .radius = 2,
            .fill = .note_fill,
            .stroke = .note_stroke,
        } });
        try labels.notes[index].draw(out, measurer, node.attachment_center, .text);
    }
    for (parser.transitions[0..parser.transition_count], 0..) |transition, index| {
        if (transition.text.len == 0) continue;
        const center = graph.edges[index].label_center;
        try labels.transitions[index].draw(out, measurer, center, .text);
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
        .states = allocator.alloc(Label, states_max) catch return error.Overflow,
        .notes = allocator.alloc(Label, states_max) catch return error.Overflow,
        .transitions = allocator.alloc(Label, transitions_max) catch return error.Overflow,
        .titles = allocator.alloc(Label, composites_max) catch return error.Overflow,
    };
    const node_map = allocator.alloc(u32, states_max) catch return error.Overflow;
    try graph_build(&parser, &graph, &labels, measurer, node_map);
    try graph.layout(allocator);
    composites_clip(&parser, &graph);
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

fn state_index(parser: *const Parser, id: []const u8) u32 {
    for (parser.states[0..parser.state_count], 0..) |state, index| {
        if (std.mem.eql(u8, state.id, id)) return @intCast(index);
    }
    return none;
}

const sample =
    \\stateDiagram-v2
    \\  [*] --> Idle
    \\  Idle --> Moving : start
    \\  state Moving {
    \\    [*] --> Accelerating
    \\    Accelerating --> Cruising : speed reached
    \\    Cruising --> Braking
    \\    Braking --> [*]
    \\  }
    \\  Moving --> Idle : stop
    \\  state check <<choice>>
    \\  Idle --> check
    \\  check --> Error : fault
    \\  check --> Idle : ok
    \\  state "Error state" as Error
    \\  Error : Needs a reset<br>by hand
    \\  note right of Error : Logged
    \\  state split <<fork>>
    \\  Error --> split
    \\  split --> Repair
    \\  split --> Report
    \\  state merge <<join>>
    \\  Repair --> merge
    \\  Report --> merge
    \\  merge --> [*]
    \\  note left of Idle
    \\    Waits for
    \\    a command
    \\  end note
;

test "state: parse states, scopes, and pseudo-states" {
    const scratch = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(scratch);
    const parser = try parse_test(sample, scratch);
    const moving = state_index(&parser, "Moving");
    try testing.expect(parser.states[moving].composite != none);
    const cruising = state_index(&parser, "Cruising");
    try testing.expectEqual(parser.states[moving].composite, parser.states[cruising].scope);
    try testing.expectEqual(Kind.choice, parser.states[state_index(&parser, "check")].kind);
    try testing.expectEqual(Kind.fork, parser.states[state_index(&parser, "split")].kind);
    try testing.expectEqual(Kind.join, parser.states[state_index(&parser, "merge")].kind);
    const error_state = parser.states[state_index(&parser, "Error")];
    try testing.expectEqualStrings("Error state", error_state.name);
    var starts: u32 = 0;
    var ends: u32 = 0;
    for (parser.states[0..parser.state_count]) |state| {
        if (state.kind == .start) starts += 1;
        if (state.kind == .end) ends += 1;
    }
    // One start and one end at the top level, and one of each inside `Moving`.
    try testing.expectEqual(@as(u32, 2), starts);
    try testing.expectEqual(@as(u32, 2), ends);
    try testing.expectEqual(@as(u32, 2), parser.note_count);
    try testing.expectEqual(@as(u32, 2), parser.notes[1].line_count);
    try testing.expect(parser.notes[1].before);
    try testing.expectEqualStrings("speed reached", parser.transitions[3].text);
}

test "state: malformed input" {
    const scratch = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(scratch);
    const bad = [_][]const u8{
        "stateDiagram-v2",
        "flowchart TD\n  A --> B",
        "stateDiagram-v2\n  A -->",
        "stateDiagram-v2\n  }",
        "stateDiagram-v2\n  state A {\n  B",
        "stateDiagram-v2\n  note right of A\n  text",
        "stateDiagram-v2\n  state A <<weird>>",
        "stateDiagram-v2\n  A b --> C",
        "stateDiagram-v2\n  note above A : x",
    };
    for (bad) |source| try testing.expectError(error.Syntax, parse_test(source, scratch));
}

test "state: too many states overflow" {
    const source = try testing.allocator.alloc(u8, 32 * 1024);
    defer testing.allocator.free(source);
    var writer = std.Io.Writer.fixed(source);
    try writer.writeAll("stateDiagram\n");
    var index: u32 = 0;
    while (index < states_max + 1) : (index += 1) try writer.print("s{d}\n", .{index});
    const scratch = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(scratch);
    try testing.expectError(error.Overflow, parse_test(writer.buffered(), scratch));
}

test "state: layout keeps nodes and notes apart and inside the scene" {
    const scratch = try testing.allocator.alloc(u8, 8 << 20);
    defer testing.allocator.free(scratch);
    const sample_horizontal = "stateDiagram\n  direction LR\n" ++ sample["stateDiagram-v2\n".len..];
    for ([_][]const u8{ sample, sample_horizontal }) |source| {
        var fixed = std.heap.FixedBufferAllocator.init(scratch);
        const allocator = fixed.allocator();
        var parser = try Parser.init(allocator);
        try parser.parse(source);
        var graph = try Graph.init(allocator, parser.direction);
        var labels: Labels = .{
            .states = try allocator.alloc(Label, states_max),
            .notes = try allocator.alloc(Label, states_max),
            .transitions = try allocator.alloc(Label, transitions_max),
            .titles = try allocator.alloc(Label, composites_max),
        };
        const node_map = try allocator.alloc(u32, states_max);
        try graph_build(&parser, &graph, &labels, scene.Measurer.fixed, node_map);
        try graph.layout(allocator);
        try graph_module.testing.nodes_disjoint(&graph);
        for (graph.nodes[0..graph.node_count]) |owner| {
            if (owner.attachment.width == 0) continue;
            const note = graph_module.rect_centered(owner.attachment_center, owner.attachment);
            for (graph.nodes[0..graph.node_count]) |node| {
                const rect = graph_module.node_rect(node);
                const apart = note.x + note.width <= rect.x or rect.x + rect.width <= note.x or
                    note.y + note.height <= rect.y or rect.y + rect.height <= note.y;
                try testing.expect(apart);
            }
        }
    }
}

test "state: render sample" {
    const scratch = try testing.allocator.alloc(u8, 8 << 20);
    defer testing.allocator.free(scratch);
    var commands: [4096]scene.Command = undefined;
    var points: [16384]scene.Point = undefined;
    var text: [4096]u8 = undefined;
    var out = scene.Scene.init(&commands, &points, &text);
    try render(sample, scene.Measurer.fixed, scratch, &out);
    try graph_module.testing.scene_check(&out);
}

test "state: every prefix renders or fails cleanly" {
    try graph_module.testing.prefixes_render(sample, render);
}
