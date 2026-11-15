//! Mermaid flowcharts (`graph` and `flowchart`): node shapes, edges with labels and heads,
//! chains, `&` fan-out, and nested subgraphs. Styling statements are parsed and ignored.

const std = @import("std");
const assert = std.debug.assert;
const scene = @import("../scene.zig");
const graph_module = @import("graph.zig");

const Graph = graph_module.Graph;
const Shape = graph_module.Shape;
const Label = graph_module.Label;
const Direction = graph_module.Direction;
const Error = scene.Error;
const none = graph_module.none;

const nodes_max = graph_module.nodes_max;
const edges_max = graph_module.edges_max;
const subgraphs_max = graph_module.clusters_max;
const group_nodes_max: u32 = 64;

const LineKind = enum { solid, dotted, thick, invisible };

const FlowNode = struct {
    id: []const u8,
    text: []const u8,
    shape: Shape,
    /// Whether a statement gave this node a shape, which rules it out as a subgraph alias.
    explicit: bool,
    subgraph: u32,
};

const FlowEdge = struct {
    source: u32,
    target: u32,
    text: []const u8,
    line: LineKind,
    head_start: scene.Head,
    head_end: scene.Head,
    length: u32,
};

const Subgraph = struct {
    id: []const u8,
    title: []const u8,
    parent: u32,
};

const Link = struct {
    text: []const u8 = "",
    line: LineKind = .solid,
    head_start: scene.Head = .none,
    head_end: scene.Head = .none,
    length: u32 = 1,
};

const Opener = struct { open: []const u8, close: []const u8, shape: Shape };

/// Longer openers come first, so that `((` is not taken for `(`.
const openers = [_]Opener{
    .{ .open = "(((", .close = ")))", .shape = .circle_double },
    .{ .open = "((", .close = "))", .shape = .circle },
    .{ .open = "([", .close = "])", .shape = .stadium },
    .{ .open = "[[", .close = "]]", .shape = .subroutine },
    .{ .open = "[(", .close = ")]", .shape = .cylinder },
    .{ .open = "{{", .close = "}}", .shape = .hexagon },
    .{ .open = "[/", .close = "/]", .shape = .parallelogram },
    .{ .open = "[\\", .close = "\\]", .shape = .parallelogram_alt },
    .{ .open = "[", .close = "]", .shape = .rect },
    .{ .open = "(", .close = ")", .shape = .rect_round },
    .{ .open = "{", .close = "}", .shape = .diamond },
    .{ .open = ">", .close = "]", .shape = .flag },
};

const ignored_words = [_][]const u8{
    "classDef", "class", "style", "linkStyle", "click", "direction", "accTitle", "accDescr",
};

const Parser = struct {
    direction: Direction = .top_bottom,
    nodes: []FlowNode,
    node_count: u32 = 0,
    edges: []FlowEdge,
    edge_count: u32 = 0,
    subgraphs: []Subgraph,
    subgraph_count: u32 = 0,
    stack: [graph_module.cluster_depth_max]u32 = undefined,
    depth: u32 = 0,

    fn init(allocator: std.mem.Allocator) Error!Parser {
        return .{
            .nodes = allocator.alloc(FlowNode, nodes_max) catch return error.Overflow,
            .edges = allocator.alloc(FlowEdge, edges_max) catch return error.Overflow,
            .subgraphs = allocator.alloc(Subgraph, subgraphs_max) catch return error.Overflow,
        };
    }

    fn parse(parser: *Parser, source: []const u8) Error!void {
        var statements: graph_module.Statements = .{ .source = source };
        const header = statements.next() orelse return error.Syntax;
        try parser.header_parse(header);
        var count: u32 = 0;
        while (statements.next()) |statement| : (count += 1) {
            assert(count < source.len);
            try parser.statement_parse(statement);
        }
        if (parser.depth != 0) return error.Syntax;
        if (parser.node_count == 0) return error.Syntax;
        assert(parser.edge_count <= edges_max);
    }

    fn header_parse(parser: *Parser, header: []const u8) Error!void {
        var words = std.mem.tokenizeAny(u8, header, " \t");
        const keyword = words.next() orelse return error.Syntax;
        const known = std.mem.eql(u8, keyword, "graph") or std.mem.eql(u8, keyword, "flowchart");
        if (!known) return error.Syntax;
        if (words.next()) |word| {
            parser.direction = Direction.parse(word) orelse return error.Syntax;
        }
        if (words.next() != null) return error.Syntax;
    }

    fn statement_parse(parser: *Parser, statement: []const u8) Error!void {
        assert(statement.len > 0);
        if (std.mem.eql(u8, statement, "end")) {
            if (parser.depth == 0) return error.Syntax;
            parser.depth -= 1;
            return;
        }
        if (graph_module.word_is(statement, "subgraph")) {
            return parser.subgraph_open(std.mem.trim(u8, statement["subgraph".len..], " \t"));
        }
        for (ignored_words) |word| {
            if (graph_module.word_is(statement, word)) return;
        }
        if (std.mem.startsWith(u8, statement, "accTitle") or
            std.mem.startsWith(u8, statement, "accDescr")) return;
        return parser.chain_parse(statement);
    }

    fn subgraph_open(parser: *Parser, rest: []const u8) Error!void {
        if (rest.len == 0) return error.Syntax;
        if (parser.subgraph_count == subgraphs_max) return error.Overflow;
        if (parser.depth == parser.stack.len) return error.Overflow;
        var id = rest;
        var title = graph_module.unquote(rest);
        if (std.mem.findScalar(u8, rest, '[')) |open| {
            if (rest[rest.len - 1] != ']') return error.Syntax;
            id = std.mem.trim(u8, rest[0..open], " \t");
            title = graph_module.unquote(rest[open + 1 .. rest.len - 1]);
            if (id.len == 0) id = title;
        } else if (rest[0] == '"') {
            id = title;
        }
        const parent = if (parser.depth == 0) none else parser.stack[parser.depth - 1];
        parser.subgraphs[parser.subgraph_count] = .{ .id = id, .title = title, .parent = parent };
        parser.stack[parser.depth] = parser.subgraph_count;
        parser.subgraph_count += 1;
        parser.depth += 1;
        assert(parser.depth <= parser.stack.len);
    }

    /// Parses `group (link group)*`, where a group is `node (& node)*`.
    fn chain_parse(parser: *Parser, statement: []const u8) Error!void {
        var cursor: Cursor = .{ .text = statement };
        var previous: [group_nodes_max]u32 = undefined;
        var previous_count = try parser.group_parse(&cursor, &previous);
        var steps: u32 = 0;
        while (true) : (steps += 1) {
            assert(steps <= statement.len);
            cursor.spaces_skip();
            if (cursor.done()) break;
            const link = try link_parse(&cursor);
            var next: [group_nodes_max]u32 = undefined;
            const next_count = try parser.group_parse(&cursor, &next);
            for (previous[0..previous_count]) |source| {
                for (next[0..next_count]) |target| try parser.edge_add(source, target, link);
            }
            previous = next;
            previous_count = next_count;
        }
    }

    fn group_parse(parser: *Parser, cursor: *Cursor, group: *[group_nodes_max]u32) Error!u32 {
        var count: u32 = 0;
        while (count < group_nodes_max) {
            cursor.spaces_skip();
            group[count] = try parser.node_parse(cursor);
            count += 1;
            cursor.spaces_skip();
            if (cursor.peek() != '&') return count;
            cursor.index += 1;
        }
        return error.Overflow;
    }

    fn node_parse(parser: *Parser, cursor: *Cursor) Error!u32 {
        const start = cursor.index;
        while (!cursor.done() and identifier_at(cursor.text, cursor.index)) cursor.index += 1;
        const id = cursor.text[start..cursor.index];
        if (id.len == 0) return error.Syntax;
        const node = try parser.node_find_or_add(id);
        if (try shape_parse(cursor)) |shaped| {
            parser.nodes[node].text = shaped.text;
            parser.nodes[node].shape = shaped.shape;
            parser.nodes[node].explicit = true;
        }
        if (std.mem.startsWith(u8, cursor.text[cursor.index..], ":::")) {
            cursor.index += 3;
            while (!cursor.done() and identifier_at(cursor.text, cursor.index)) cursor.index += 1;
        }
        parser.membership_update(node);
        return node;
    }

    fn node_find_or_add(parser: *Parser, id: []const u8) Error!u32 {
        assert(id.len > 0);
        for (parser.nodes[0..parser.node_count], 0..) |node, index| {
            if (std.mem.eql(u8, node.id, id)) return @intCast(index);
        }
        if (parser.node_count == nodes_max) return error.Overflow;
        parser.nodes[parser.node_count] = .{
            .id = id,
            .text = id,
            .shape = .rect,
            .explicit = false,
            .subgraph = none,
        };
        parser.node_count += 1;
        return parser.node_count - 1;
    }

    /// A node belongs to the innermost subgraph that mentions it, unless an unrelated subgraph
    /// claimed it first.
    fn membership_update(parser: *Parser, node: u32) void {
        if (parser.depth == 0) return;
        const current = parser.stack[parser.depth - 1];
        const previous = parser.nodes[node].subgraph;
        if (previous == none or parser.subgraph_within(current, previous)) {
            parser.nodes[node].subgraph = current;
        }
        assert(parser.nodes[node].subgraph != none);
    }

    fn subgraph_within(parser: *const Parser, subgraph: u32, ancestor: u32) bool {
        var current = subgraph;
        var depth: u32 = 0;
        while (current != none and depth <= parser.stack.len) : (depth += 1) {
            if (current == ancestor) return true;
            current = parser.subgraphs[current].parent;
        }
        return false;
    }

    fn edge_add(parser: *Parser, source: u32, target: u32, link: Link) Error!void {
        assert(source < parser.node_count);
        assert(target < parser.node_count);
        if (parser.edge_count == edges_max) return error.Overflow;
        parser.edges[parser.edge_count] = .{
            .source = source,
            .target = target,
            .text = link.text,
            .line = link.line,
            .head_start = link.head_start,
            .head_end = link.head_end,
            .length = link.length,
        };
        parser.edge_count += 1;
    }

    fn subgraph_alias(parser: *const Parser, node: u32) u32 {
        const value = parser.nodes[node];
        if (value.explicit) return none;
        for (parser.subgraphs[0..parser.subgraph_count], 0..) |subgraph, index| {
            if (std.mem.eql(u8, subgraph.id, value.id)) return @intCast(index);
        }
        return none;
    }
};

const Cursor = struct {
    text: []const u8,
    index: usize = 0,

    fn done(cursor: *const Cursor) bool {
        return cursor.index >= cursor.text.len;
    }

    fn peek(cursor: *const Cursor) u8 {
        return if (cursor.done()) 0 else cursor.text[cursor.index];
    }

    fn peek_at(cursor: *const Cursor, offset: usize) u8 {
        const index = cursor.index + offset;
        return if (index >= cursor.text.len) 0 else cursor.text[index];
    }

    fn spaces_skip(cursor: *Cursor) void {
        while (cursor.peek() == ' ' or cursor.peek() == '\t') cursor.index += 1;
    }
};

/// Identifier bytes. A `-` belongs to the identifier only when a letter or digit follows, so
/// that `A-->B` splits at the link.
fn identifier_at(text: []const u8, index: usize) bool {
    const byte = text[index];
    if (byte == '-') {
        return index + 1 < text.len and std.ascii.isAlphanumeric(text[index + 1]);
    }
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte >= 0x80;
}

const Shaped = struct { text: []const u8, shape: Shape };

fn shape_parse(cursor: *Cursor) Error!?Shaped {
    const rest = cursor.text[cursor.index..];
    const opener = for (openers) |opener| {
        if (std.mem.startsWith(u8, rest, opener.open)) break opener;
    } else return null;
    var index = opener.open.len;
    var text_end: usize = undefined;
    if (index < rest.len and rest[index] == '"') {
        const close_quote = std.mem.findScalarPos(u8, rest, index + 1, '"') orelse
            return error.Syntax;
        text_end = close_quote + 1;
    } else {
        text_end = index;
    }
    var shape = opener.shape;
    var close_at = std.mem.findPos(u8, rest, text_end, opener.close);
    // Slanted shapes close with either slash, which picks the trapezoid variants.
    const other: ?[]const u8 = switch (opener.shape) {
        .parallelogram => "\\]",
        .parallelogram_alt => "/]",
        else => null,
    };
    if (other) |close| {
        if (std.mem.findPos(u8, rest, text_end, close)) |at| {
            if (close_at == null or at < close_at.?) {
                close_at = at;
                shape = if (opener.shape == .parallelogram) .trapezoid else .trapezoid_alt;
            }
        }
    }
    const close = close_at orelse return error.Syntax;
    const text = graph_module.unquote(rest[index..close]);
    index = close + opener.close.len;
    cursor.index += index;
    assert(cursor.index <= cursor.text.len);
    return .{ .text = text, .shape = shape };
}

fn link_char(byte: u8) bool {
    return byte == '-' or byte == '=' or byte == '.' or byte == '~';
}

fn head_from(byte: u8) scene.Head {
    return switch (byte) {
        '>', '<' => .arrow,
        'o' => .circle,
        'x' => .cross,
        else => .none,
    };
}

/// Parses a link such as `-->`, `-.->`, `==>`, `<-->`, `--o`, `---->`, `-->|text|`,
/// `-- text -->`, `-. text .->`, or `== text ==>`.
fn link_parse(cursor: *Cursor) Error!Link {
    var link: Link = .{};
    const first = cursor.peek();
    if (first == '<' or ((first == 'o' or first == 'x') and link_char(cursor.peek_at(1)))) {
        link.head_start = head_from(first);
        cursor.index += 1;
    }
    const body_start = cursor.index;
    while (!cursor.done() and link_char(cursor.peek())) cursor.index += 1;
    const body = cursor.text[body_start..cursor.index];
    if (body.len < 2) return error.Syntax;
    const opener = std.mem.eql(u8, body, "--") or std.mem.eql(u8, body, "==") or
        std.mem.eql(u8, body, "-.");
    const head_end = head_end_parse(cursor);
    if (opener and head_end == .none and (cursor.peek() == ' ' or cursor.peek() == '\t')) {
        return link_text_parse(cursor, body, link.head_start);
    }
    link.head_end = head_end;
    try link_classify(&link, body);
    cursor.spaces_skip();
    if (cursor.peek() == '|') {
        const close = std.mem.findScalarPos(u8, cursor.text, cursor.index + 1, '|') orelse
            return error.Syntax;
        link.text = graph_module.unquote(cursor.text[cursor.index + 1 .. close]);
        cursor.index = close + 1;
    }
    return link;
}

fn head_end_parse(cursor: *Cursor) scene.Head {
    const byte = cursor.peek();
    if (byte == '>') {
        cursor.index += 1;
        return .arrow;
    }
    if (byte == 'o' or byte == 'x') {
        const after = cursor.peek_at(1);
        const identifier = std.ascii.isAlphanumeric(after) or after == '_';
        if (!identifier) {
            cursor.index += 1;
            return head_from(byte);
        }
    }
    return .none;
}

/// Sets the line kind and length from the link body: extra dashes, equals signs, or dots
/// make the edge span more ranks.
fn link_classify(link: *Link, body: []const u8) Error!void {
    assert(body.len >= 2);
    const dots: u32 = @intCast(std.mem.count(u8, body, "."));
    const tildes: u32 = @intCast(std.mem.count(u8, body, "~"));
    const thick = std.mem.findScalar(u8, body, '=') != null;
    const length_raw: u32 = @intCast(body.len);
    if (tildes > 0) {
        if (tildes != body.len or body.len < 3) return error.Syntax;
        link.line = .invisible;
        link.length = length_raw - 2;
    } else if (dots > 0) {
        if (thick) return error.Syntax;
        link.line = .dotted;
        link.length = dots;
    } else {
        link.line = if (thick) .thick else .solid;
        const base: u32 = if (link.head_end == .none) 2 else 1;
        link.length = if (length_raw > base) length_raw - base else 1;
    }
    link.length = @max(1, @min(link.length, graph_module.edge_length_max));
}

/// Parses the rest of `-- text -->`: the text runs until the closing link token.
fn link_text_parse(cursor: *Cursor, opener: []const u8, head_start: scene.Head) Error!Link {
    const close_token: []const u8 =
        if (opener[0] == '=') "==" else if (opener[1] == '.') ".-" else "--";
    const text_start = cursor.index;
    const close = std.mem.findPos(u8, cursor.text, text_start, close_token) orelse
        return error.Syntax;
    var link: Link = .{ .head_start = head_start };
    link.text = graph_module.unquote(cursor.text[text_start..close]);
    cursor.index = close;
    const body_start = cursor.index;
    while (!cursor.done() and link_char(cursor.peek())) cursor.index += 1;
    const body = cursor.text[body_start..cursor.index];
    link.head_end = head_end_parse(cursor);
    if (opener[1] == '.') {
        link.line = .dotted;
        link.length = @intCast(@max(1, std.mem.count(u8, body, ".")));
    } else {
        // The closing token carries the extra length: `-->` is 1, `--->` is 2.
        try link_classify(&link, body);
    }
    assert(link.length >= 1);
    return link;
}

// Rendering.

fn node_size(shape: Shape, label: Size) Size {
    const pad_x: f32 = 16;
    const pad_y: f32 = 10;
    const width = label.width + 2 * pad_x;
    const height = label.height + 2 * pad_y;
    return switch (shape) {
        .circle => circle_size(label, 0),
        .circle_double => circle_size(label, 10),
        .diamond => diamond_size(label),
        .stadium => .{ .width = width + height / 2, .height = height },
        .subroutine => .{ .width = width + 16, .height = height },
        .hexagon => .{ .width = width + 2 * graph_module.hexagon_inset(height), .height = height },
        .cylinder => .{ .width = width, .height = height + 16 },
        .parallelogram, .parallelogram_alt, .trapezoid, .trapezoid_alt => .{
            .width = width + height,
            .height = height,
        },
        .flag => .{ .width = width + height / 4, .height = height },
        else => .{ .width = width, .height = height },
    };
}

const Size = scene.Size;

fn circle_size(label: Size, extra: f32) Size {
    const diameter = @max(label.width, label.height) + 20 + extra;
    assert(diameter > 0);
    return .{ .width = diameter, .height = diameter };
}

/// The diamond must contain the label box: `w_label / w + h_label / h <= 1`.
fn diamond_size(label: Size) Size {
    const width = label.width + 2 * label.height + 24;
    const needed = label.height / (1 - label.width / width) + 10;
    const height = @max(needed, width * 0.5);
    assert(label.width / width + label.height / height <= 1);
    return .{ .width = width, .height = height };
}

const Labels = struct {
    nodes: []Label,
    edges: []Label,
    titles: []Label,
};

/// Adds clusters, nodes, and edges to the graph. Edges that name a subgraph attach to its
/// first member as a target and to its last member as a source.
fn graph_build(
    parser: *const Parser,
    graph: *Graph,
    labels: *Labels,
    measurer: scene.Measurer,
    node_map: []u32,
) Error!void {
    for (parser.subgraphs[0..parser.subgraph_count], 0..) |subgraph, index| {
        labels.titles[index] = try Label.init(subgraph.title, measurer, .regular);
        const zero: Size = .{ .width = 0, .height = 0 };
        const title = if (labels.titles[index].empty()) zero else labels.titles[index].size;
        _ = try graph.cluster_add(subgraph.parent, title);
    }
    for (parser.nodes[0..parser.node_count], 0..) |node, index| {
        node_map[index] = none;
        if (parser.subgraph_alias(@intCast(index)) != none) continue;
        const label = try Label.init(node.text, measurer, .regular);
        const size = node_size(node.shape, label.size);
        const graph_node = try graph.node_add(size, node.shape, node.subgraph);
        labels.nodes[graph_node] = label;
        node_map[index] = graph_node;
    }
    if (graph.node_count == 0) return error.Syntax;
    for (parser.edges[0..parser.edge_count]) |edge| {
        const source = try endpoint_resolve(parser, graph, node_map, edge.source, false);
        const target = try endpoint_resolve(parser, graph, node_map, edge.target, true);
        var label_size: Size = .{ .width = 0, .height = 0 };
        if (edge.text.len > 0) {
            labels.edges[graph.edge_count] = try Label.init(edge.text, measurer, .small);
            label_size = labels.edges[graph.edge_count].size;
        }
        _ = try graph.edge_add(source, target, label_size, edge.length);
    }
}

fn endpoint_resolve(
    parser: *const Parser,
    graph: *Graph,
    node_map: []const u32,
    node: u32,
    first: bool,
) Error!u32 {
    if (node_map[node] != none) return node_map[node];
    const subgraph = parser.subgraph_alias(node);
    assert(subgraph != none);
    const chosen = graph.cluster_member(subgraph, first);
    if (chosen != none) return chosen;
    const title = graph.clusters[subgraph].title;
    return graph.node_add(.{ .width = @max(title.width, 40), .height = 16 }, .hidden, subgraph);
}

fn aliases_clip(parser: *const Parser, graph: *Graph) void {
    for (parser.edges[0..parser.edge_count], 0..) |edge, index| {
        const source = parser.subgraph_alias(edge.source);
        const target = parser.subgraph_alias(edge.target);
        const edge_index: u32 = @intCast(index);
        const graph_edge = graph.edges[edge_index];
        if (graph_edge.source == graph_edge.target) continue;
        if (source != none and !node_within(graph, graph_edge.target, source)) {
            graph_module.route_clip_to_cluster(graph, edge_index, source, false);
        }
        if (target != none and !node_within(graph, graph_edge.source, target)) {
            graph_module.route_clip_to_cluster(graph, edge_index, target, true);
        }
    }
}

fn node_within(graph: *const Graph, node: u32, cluster: u32) bool {
    const value = graph.nodes[node].cluster;
    return value != none and graph.cluster_within(value, cluster);
}

fn edge_style(edge: FlowEdge) graph_module.EdgeStyle {
    return .{
        .dash = if (edge.line == .dotted) .dashed else .solid,
        .stroke_width = if (edge.line == .thick) 3 else 1.25,
        .head_start = edge.head_start,
        .head_end = edge.head_end,
    };
}

fn draw(
    parser: *const Parser,
    graph: *const Graph,
    labels: *const Labels,
    measurer: scene.Measurer,
    out: *scene.Scene,
) Error!void {
    try graph_module.clusters_draw(out, graph, measurer, labels.titles);
    for (parser.edges[0..parser.edge_count], 0..) |edge, index| {
        if (edge.line == .invisible) continue;
        try graph_module.edge_draw(out, graph, @intCast(index), edge_style(edge));
    }
    for (graph.nodes[0..graph.node_count], 0..) |node, index| {
        if (node.shape == .hidden) continue;
        const rect = graph_module.node_rect(node);
        try graph_module.shape_draw(out, node.shape, rect);
        var center = node.center;
        if (node.shape == .cylinder) center.y += graph_module.cylinder_cap(rect) / 2;
        try labels.nodes[index].draw(out, measurer, center, .text);
    }
    for (parser.edges[0..parser.edge_count], 0..) |edge, index| {
        if (edge.text.len == 0 or edge.line == .invisible) continue;
        try labels.edges[index].draw(out, measurer, graph.edges[index].label_center, .text);
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
        .nodes = allocator.alloc(Label, nodes_max) catch return error.Overflow,
        .edges = allocator.alloc(Label, edges_max) catch return error.Overflow,
        .titles = allocator.alloc(Label, subgraphs_max) catch return error.Overflow,
    };
    const node_map = allocator.alloc(u32, nodes_max) catch return error.Overflow;
    try graph_build(&parser, &graph, &labels, measurer, node_map);
    try graph.layout(allocator);
    aliases_clip(&parser, &graph);
    try draw(&parser, &graph, &labels, measurer, out);
    out.size = graph.size;
    assert(out.size.width > 0);
    assert(out.size.height > 0);
}

// Tests.

const testing = std.testing;

fn parse_test(source: []const u8, parser: *Parser) !void {
    parser.* = try Parser.init(testing.allocator);
    try parser.parse(source);
}

fn parser_free(parser: *Parser) void {
    testing.allocator.free(parser.nodes);
    testing.allocator.free(parser.edges);
    testing.allocator.free(parser.subgraphs);
}

test {
    _ = graph_module;
}

test "flowchart: shapes and quoted labels" {
    var parser: Parser = undefined;
    try parse_test(
        \\flowchart LR
        \\  a[rect] --> b(round) --> c([stadium]) --> d[[sub]] --> e[(db)]
        \\  f((circle)) --- g{diamond} --- h{{hex}} --- i[/para/] --- j[\alt\]
        \\  k[/trap\] --> l[\inv/] --> m>flag] --> n(((double))) --> o["a [quoted] (label)"]
    , &parser);
    defer parser_free(&parser);
    const expected = [_]Shape{
        .rect,      .rect_round,    .stadium, .subroutine,    .cylinder,
        .circle,    .diamond,       .hexagon, .parallelogram, .parallelogram_alt,
        .trapezoid, .trapezoid_alt, .flag,    .circle_double, .rect,
    };
    try testing.expectEqual(@as(u32, expected.len), parser.node_count);
    for (expected, parser.nodes[0..expected.len]) |shape, node| {
        try testing.expectEqual(shape, node.shape);
    }
    try testing.expectEqualStrings("a [quoted] (label)", parser.nodes[14].text);
    try testing.expectEqual(Direction.left_right, parser.direction);
}

test "flowchart: links" {
    var parser: Parser = undefined;
    try parse_test(
        \\graph TD
        \\  A -->|yes| B
        \\  A -- no --> C
        \\  A -. maybe .-> D
        \\  A == sure ==> E
        \\  A <--> F
        \\  A --o G
        \\  A --x H
        \\  A ----> I
        \\  A-.->J
        \\  A & B --> K & L
        \\  A ~~~ M
    , &parser);
    defer parser_free(&parser);
    const edges = parser.edges[0..parser.edge_count];
    try testing.expectEqual(@as(u32, 14), parser.edge_count);
    try testing.expectEqualStrings("yes", edges[0].text);
    try testing.expectEqualStrings("no", edges[1].text);
    try testing.expectEqual(scene.Head.arrow, edges[1].head_end);
    try testing.expectEqual(LineKind.dotted, edges[2].line);
    try testing.expectEqualStrings("maybe", edges[2].text);
    try testing.expectEqual(LineKind.thick, edges[3].line);
    try testing.expectEqual(scene.Head.arrow, edges[4].head_start);
    try testing.expectEqual(scene.Head.circle, edges[5].head_end);
    try testing.expectEqual(scene.Head.cross, edges[6].head_end);
    try testing.expectEqual(@as(u32, 3), edges[7].length);
    try testing.expectEqual(LineKind.dotted, edges[8].line);
    try testing.expectEqual(LineKind.invisible, edges[13].line);
}

test "flowchart: subgraphs and ignored statements" {
    var parser: Parser = undefined;
    try parse_test(
        \\flowchart TB
        \\  classDef red fill:#f00
        \\  c1-->a2
        \\  subgraph one [First]
        \\    direction LR
        \\    a1-->a2:::red
        \\    subgraph two
        \\      b1
        \\    end
        \\  end
        \\  style a1 fill:#fff
        \\  click a1 callback
        \\  one --> c1
    , &parser);
    defer parser_free(&parser);
    try testing.expectEqual(@as(u32, 2), parser.subgraph_count);
    try testing.expectEqualStrings("First", parser.subgraphs[0].title);
    try testing.expectEqual(@as(u32, 0), parser.subgraphs[1].parent);
    try testing.expectEqual(@as(u32, 0), parser.nodes[1].subgraph);
    try testing.expectEqual(none, parser.nodes[0].subgraph);
    try testing.expect(parser.subgraph_alias(4) == 0);
}

test "flowchart: malformed input" {
    var parser = try Parser.init(testing.allocator);
    defer parser_free(&parser);
    const bad = [_][]const u8{
        "flowchart XY\nA-->B",
        "flowchart\nA-->",
        "flowchart\nA[unclosed",
        "flowchart\nsubgraph x\nA",
        "flowchart\nend",
        "flowchart\nA -- text B",
        "flowchart",
        "graph LR\nA -> B",
    };
    for (bad) |source| {
        parser = .{ .nodes = parser.nodes, .edges = parser.edges, .subgraphs = parser.subgraphs };
        try testing.expectError(error.Syntax, parser.parse(source));
    }
}

const sample_large =
    \\flowchart TB
    \\  start([Start]) --> input[/Read input/]
    \\  input --> valid{Valid?}
    \\  valid -->|no| error[Show error] --> input
    \\  valid -->|yes| subgraph_a
    \\  subgraph subgraph_a [Processing]
    \\    parse[Parse] --> transform[[Transform]]
    \\    subgraph inner [Storage]
    \\      cache[(Cache)] --> db[(Database)]
    \\    end
    \\    transform --> cache
    \\  end
    \\  db --> report{{Report}}
    \\  transform --> notify>Notify]
    \\  report --> done((Done))
    \\  notify --> done
    \\  report -.-> audit[Audit log]
    \\  audit ==> archive[(Archive)]
    \\  archive --> done
    \\  lonely[Isolated node]
;

test "flowchart: large sample renders without overlaps" {
    const scratch = try testing.allocator.alloc(u8, 8 << 20);
    defer testing.allocator.free(scratch);
    var commands: [4096]scene.Command = undefined;
    var points: [16384]scene.Point = undefined;
    var text: [1024]u8 = undefined;
    var out = scene.Scene.init(&commands, &points, &text);
    try render(sample_large, scene.Measurer.fixed, scratch, &out);
    try graph_module.testing.scene_check(&out);

    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const allocator = fixed.allocator();
    var parser = try Parser.init(allocator);
    try parser.parse(sample_large);
    var graph = try Graph.init(allocator, parser.direction);
    var labels: Labels = .{
        .nodes = try allocator.alloc(Label, nodes_max),
        .edges = try allocator.alloc(Label, edges_max),
        .titles = try allocator.alloc(Label, subgraphs_max),
    };
    const node_map = try allocator.alloc(u32, nodes_max);
    try graph_build(&parser, &graph, &labels, scene.Measurer.fixed, node_map);
    try graph.layout(allocator);
    try graph_module.testing.nodes_disjoint(&graph);
}

test "flowchart: every prefix of a sample renders or fails cleanly" {
    try graph_module.testing.prefixes_render(sample_large, render);
}
