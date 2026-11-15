//! Entity relationship diagrams (`erDiagram`), laid out by the layered graph engine. Entities
//! are tables (a header and one row per attribute); relationship ends carry crow's-foot
//! markers drawn with lines and circles, since `scene.Head` has no such shapes.

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

const entities_max = graph_module.nodes_max;
const relationships_max = graph_module.edges_max;
const attributes_max: u32 = 4096;
const columns_count = 4;

const header_padding_vertical: f32 = 8;
const header_padding_horizontal: f32 = 16;
const row_padding_vertical: f32 = 4;
const column_padding: f32 = 10;
const entity_width_min: f32 = 100;

/// Marker geometry, in points from the entity border along the relationship line.
const marker_spread: f32 = 7;
const bar_near: f32 = 8;
const bar_far: f32 = 14;
const foot_length: f32 = 14;
const circle_radius: f32 = 4.5;

const Cardinality = enum { zero_or_one, exactly_one, zero_or_more, one_or_more };

const Entity = struct { id: []const u8, name: []const u8 };

const Attribute = struct {
    entity: u32,
    /// Type, name, keys, and comment; the last two may be empty.
    columns: [columns_count][]const u8,
};

const Relationship = struct {
    source: u32,
    target: u32,
    cardinality_source: Cardinality,
    cardinality_target: Cardinality,
    identifying: bool,
    text: []const u8,
};

const Parser = struct {
    entities: []Entity,
    entity_count: u32 = 0,
    attributes: []Attribute,
    attribute_count: u32 = 0,
    relationships: []Relationship,
    relationship_count: u32 = 0,
    direction: Direction = .top_bottom,
    /// The entity whose `{ }` attribute block is open, or `none`.
    body: u32 = none,

    fn init(allocator: std.mem.Allocator) Error!Parser {
        return .{
            .entities = allocator.alloc(Entity, entities_max) catch return error.Overflow,
            .attributes = allocator.alloc(Attribute, attributes_max) catch
                return error.Overflow,
            .relationships = allocator.alloc(Relationship, relationships_max) catch
                return error.Overflow,
        };
    }

    fn parse(parser: *Parser, source: []const u8) Error!void {
        var statements: Statements = .{ .source = source };
        const header = statements.next() orelse return error.Syntax;
        if (!word_is(header, "erDiagram")) return error.Syntax;
        var count: u32 = 0;
        while (statements.next()) |statement| : (count += 1) {
            assert(count <= source.len);
            if (parser.body != none) {
                try parser.body_parse(statement);
            } else {
                try parser.statement_parse(statement);
            }
        }
        if (parser.body != none) return error.Syntax;
        if (parser.entity_count == 0) return error.Syntax;
        assert(parser.entity_count <= entities_max);
    }

    fn statement_parse(parser: *Parser, text: []const u8) Error!void {
        assert(text.len > 0);
        assert(parser.body == none);
        if (word_is(text, "direction")) {
            const word = std.mem.trim(u8, text["direction".len..], " \t");
            parser.direction = Direction.parse(word) orelse return error.Syntax;
            return;
        }
        if (word_is(text, "classDef") or word_is(text, "class") or word_is(text, "style")) return;
        if (word_is(text, "accTitle") or word_is(text, "accDescr")) return;
        if (operator_find(text)) |operator| return parser.relationship_parse(text, operator);
        if (std.mem.indexOfScalar(u8, text, '{')) |brace| {
            const entity = try parser.entity_get(text[0..brace]);
            parser.body = entity;
            const rest = std.mem.trim(u8, text[brace + 1 ..], " \t");
            if (rest.len > 0) try parser.body_parse(rest);
            return;
        }
        _ = try parser.entity_get(text);
    }

    fn body_parse(parser: *Parser, text: []const u8) Error!void {
        assert(parser.body != none);
        var line = text;
        const closes = line.len > 0 and line[line.len - 1] == '}';
        if (closes) line = std.mem.trim(u8, line[0 .. line.len - 1], " \t");
        if (line.len > 0) try parser.attribute_parse(line);
        if (closes) parser.body = none;
    }

    /// `type name [PK, FK] ["comment"]`.
    fn attribute_parse(parser: *Parser, text: []const u8) Error!void {
        assert(text.len > 0);
        if (parser.attribute_count == attributes_max) return error.Overflow;
        var tokens = std.mem.tokenizeAny(u8, text, " \t");
        const kind = tokens.next() orelse return error.Syntax;
        const name = tokens.next() orelse return error.Syntax;
        if (kind[0] == '"' or name[0] == '"') return error.Syntax;
        const rest = std.mem.trim(u8, tokens.rest(), " \t");
        const quote = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
        const keys = std.mem.trim(u8, rest[0..quote], " \t");
        const comment = graph_module.unquote(rest[quote..]);
        if (quote < rest.len and rest[rest.len - 1] != '"') return error.Syntax;
        parser.attributes[parser.attribute_count] = .{
            .entity = parser.body,
            .columns = .{ kind, name, keys, comment },
        };
        parser.attribute_count += 1;
        assert(parser.attribute_count <= attributes_max);
    }

    fn relationship_parse(parser: *Parser, text: []const u8, operator: Operator) Error!void {
        assert(operator.start >= 2);
        if (parser.relationship_count == relationships_max) return error.Overflow;
        const rest = text[operator.start + 4 ..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
        const source = try parser.entity_get(text[0 .. operator.start - 2]);
        const target = try parser.entity_get(rest[0..colon]);
        const label = if (colon < rest.len) rest[colon + 1 ..] else "";
        parser.relationships[parser.relationship_count] = .{
            .source = source,
            .target = target,
            .cardinality_source = operator.source,
            .cardinality_target = operator.target,
            .identifying = operator.identifying,
            .text = graph_module.unquote(label),
        };
        parser.relationship_count += 1;
        assert(parser.relationship_count <= relationships_max);
    }

    /// Finds an entity by name, or declares it. Accepts `"quoted names"` and an alias in
    /// brackets: `p[Person]` or `p["Person"]`.
    fn entity_get(parser: *Parser, text: []const u8) Error!u32 {
        var id = std.mem.trim(u8, text, " \t");
        var name: ?[]const u8 = null;
        if (id.len > 0 and id[id.len - 1] == ']') {
            const open = std.mem.indexOfScalar(u8, id, '[') orelse return error.Syntax;
            name = graph_module.unquote(id[open + 1 .. id.len - 1]);
            id = std.mem.trimEnd(u8, id[0..open], " \t");
        }
        if (id.len >= 2 and id[0] == '"' and id[id.len - 1] == '"') {
            id = id[1 .. id.len - 1];
        } else {
            for (id) |byte| if (!graph_module.identifier_char(byte)) return error.Syntax;
        }
        if (id.len == 0) return error.Syntax;
        for (parser.entities[0..parser.entity_count], 0..) |*entity, index| {
            if (!std.mem.eql(u8, entity.id, id)) continue;
            if (name) |value| entity.name = value;
            return @intCast(index);
        }
        if (parser.entity_count == entities_max) return error.Overflow;
        parser.entities[parser.entity_count] = .{ .id = id, .name = name orelse id };
        parser.entity_count += 1;
        return parser.entity_count - 1;
    }
};

const Operator = struct {
    /// Index of the line (`--` or `..`), which sits between two two-character markers.
    start: usize,
    source: Cardinality,
    target: Cardinality,
    identifying: bool,
};

/// Finds `||--o{` and its kin outside of quotes. Single hyphens in names never match, since
/// both markers must be valid around the line.
fn operator_find(text: []const u8) ?Operator {
    var quoted = false;
    var index: usize = 0;
    while (index + 4 <= text.len) : (index += 1) {
        if (text[index] == '"') quoted = !quoted;
        if (quoted or index < 2) continue;
        const line = text[index .. index + 2];
        const identifying = std.mem.eql(u8, line, "--");
        if (!identifying and !std.mem.eql(u8, line, "..")) continue;
        const source = cardinality_left(text[index - 2 .. index]) orelse continue;
        const target = cardinality_right(text[index + 2 .. index + 4]) orelse continue;
        return .{
            .start = index,
            .source = source,
            .target = target,
            .identifying = identifying,
        };
    }
    return null;
}

fn cardinality_left(marker: []const u8) ?Cardinality {
    assert(marker.len == 2);
    if (std.mem.eql(u8, marker, "|o")) return .zero_or_one;
    if (std.mem.eql(u8, marker, "||")) return .exactly_one;
    if (std.mem.eql(u8, marker, "}o")) return .zero_or_more;
    if (std.mem.eql(u8, marker, "}|")) return .one_or_more;
    return null;
}

fn cardinality_right(marker: []const u8) ?Cardinality {
    assert(marker.len == 2);
    if (std.mem.eql(u8, marker, "o|")) return .zero_or_one;
    if (std.mem.eql(u8, marker, "||")) return .exactly_one;
    if (std.mem.eql(u8, marker, "o{")) return .zero_or_more;
    if (std.mem.eql(u8, marker, "|{")) return .one_or_more;
    return null;
}

// Layout.

/// Column widths and row heights of one entity table.
const Table = struct {
    header: f32,
    row: f32,
    rows: u32,
    columns: [columns_count]f32,
    width: f32,

    fn height(table: Table) f32 {
        return table.header + table.row * @as(f32, @floatFromInt(table.rows));
    }
};

const column_fonts = [columns_count]scene.Font{ .regular, .regular, .small, .small };

fn table_measure(parser: *const Parser, entity: u32, measurer: scene.Measurer) Table {
    const name = measurer.measure(parser.entities[entity].name, .bold);
    const line_height = measurer.measure("Mg", .regular).height;
    var table: Table = .{
        .header = name.height + 2 * header_padding_vertical,
        .row = line_height + 2 * row_padding_vertical,
        .rows = 0,
        .columns = @splat(0),
        .width = 0,
    };
    for (parser.attributes[0..parser.attribute_count]) |attribute| {
        if (attribute.entity != entity) continue;
        table.rows += 1;
        for (attribute.columns, column_fonts, &table.columns) |text, font, *width| {
            if (text.len > 0) width.* = @max(width.*, measurer.measure(text, font).width);
        }
    }
    var columns_width: f32 = column_padding;
    for (table.columns) |width| {
        if (width > 0) columns_width += width + column_padding;
    }
    table.width = @max(entity_width_min, name.width + 2 * header_padding_horizontal);
    table.width = @max(table.width, columns_width);
    assert(table.height() > 0);
    assert(table.width > 0);
    return table;
}

const Labels = struct {
    tables: []Table,
    relationships: []Label,
};

fn graph_build(
    parser: *const Parser,
    graph: *Graph,
    labels: *Labels,
    measurer: scene.Measurer,
) Error!void {
    var entity: u32 = 0;
    while (entity < parser.entity_count) : (entity += 1) {
        const table = table_measure(parser, entity, measurer);
        labels.tables[entity] = table;
        const size: Size = .{ .width = table.width, .height = table.height() };
        _ = try graph.node_add(size, .rect, none);
    }
    for (parser.relationships[0..parser.relationship_count], 0..) |relationship, index| {
        var label_size: Size = .{ .width = 0, .height = 0 };
        if (relationship.text.len > 0) {
            labels.relationships[index] = try Label.init(relationship.text, measurer, .small);
            label_size = labels.relationships[index].size;
        }
        _ = try graph.edge_add(relationship.source, relationship.target, label_size, 1);
    }
    assert(graph.node_count == parser.entity_count);
    assert(graph.edge_count == parser.relationship_count);
}

// Drawing.

fn entity_draw(
    parser: *const Parser,
    entity: u32,
    table: Table,
    rect: Rect,
    out: *scene.Scene,
) Error!void {
    var header = rect;
    header.height = table.header;
    try out.command_add(.{ .rect = .{ .rect = rect, .radius = 3, .fill = .group_fill } });
    try out.command_add(.{ .rect = .{ .rect = header, .radius = 3, .fill = .node_fill } });
    try out.command_add(.{ .text = .{
        .origin = .{ .x = rect.x + rect.width / 2, .y = rect.y + table.header / 2 },
        .font = .bold,
        .bytes = parser.entities[entity].name,
    } });
    var row: u32 = 0;
    for (parser.attributes[0..parser.attribute_count]) |attribute| {
        if (attribute.entity != entity) continue;
        const top = rect.y + table.header + table.row * @as(f32, @floatFromInt(row));
        try row_draw(out, table, attribute, rect.x, top, rect.width);
        row += 1;
    }
    assert(row == table.rows);
    try out.command_add(.{ .rect = .{ .rect = rect, .radius = 3, .stroke = .node_stroke } });
}

fn row_draw(
    out: *scene.Scene,
    table: Table,
    attribute: Attribute,
    left: f32,
    top: f32,
    width: f32,
) Error!void {
    assert(width > 0);
    const ends = [2]Point{ .{ .x = left, .y = top }, .{ .x = left + width, .y = top } };
    const range = try out.points_add(&ends);
    try out.command_add(.{ .line = .{ .points = range, .stroke = .node_stroke } });
    var x = left + column_padding;
    for (attribute.columns, column_fonts, table.columns, 0..) |text, font, column, index| {
        if (column == 0) continue;
        if (text.len > 0) try out.command_add(.{ .text = .{
            .origin = .{ .x = x, .y = top + table.row / 2 },
            .anchor = .start,
            .font = font,
            .color = if (index == 3) .text_muted else .text,
            .bytes = text,
        } });
        x += column + column_padding;
    }
    assert(x <= left + width + 0.5);
}

/// Draws the marker for one relationship end. `end` lies on the entity border and `toward`
/// is the next route point, which gives the direction of the line near the entity.
fn marker_draw(out: *scene.Scene, cardinality: Cardinality, end: Point, toward: Point) Error!void {
    const dx = toward.x - end.x;
    const dy = toward.y - end.y;
    const length = @max(@sqrt(dx * dx + dy * dy), 0.001);
    const frame: Frame = .{
        .origin = end,
        .along = .{ .x = dx / length, .y = dy / length },
        .across = .{ .x = -dy / length, .y = dx / length },
    };
    switch (cardinality) {
        .exactly_one => {
            try bar_draw(out, frame, bar_near);
            try bar_draw(out, frame, bar_far);
        },
        .zero_or_one => {
            try bar_draw(out, frame, bar_near);
            try circle_draw(out, frame, bar_far + circle_radius + 2);
        },
        .one_or_more => {
            try foot_draw(out, frame);
            try bar_draw(out, frame, foot_length + 4);
        },
        .zero_or_more => {
            try foot_draw(out, frame);
            try circle_draw(out, frame, foot_length + circle_radius + 2);
        },
    }
}

/// A local frame at a relationship end: `along` points away from the entity.
const Frame = struct {
    origin: Point,
    along: Point,
    across: Point,

    fn at(frame: Frame, distance_along: f32, distance_across: f32) Point {
        return .{
            .x = frame.origin.x + frame.along.x * distance_along + frame.across.x * distance_across,
            .y = frame.origin.y + frame.along.y * distance_along + frame.across.y * distance_across,
        };
    }
};

fn segment_draw(out: *scene.Scene, from: Point, to: Point) Error!void {
    const points = [2]Point{ from, to };
    try out.command_add(.{ .line = .{
        .points = try out.points_add(&points),
        .stroke = .line,
        .stroke_width = 1.25,
    } });
}

fn bar_draw(out: *scene.Scene, frame: Frame, distance: f32) Error!void {
    assert(distance > 0);
    try segment_draw(out, frame.at(distance, -marker_spread), frame.at(distance, marker_spread));
}

/// Three toes that meet on the line and spread out to the entity border.
fn foot_draw(out: *scene.Scene, frame: Frame) Error!void {
    const apex = frame.at(foot_length, 0);
    try segment_draw(out, apex, frame.at(0, -marker_spread));
    try segment_draw(out, apex, frame.at(0, marker_spread));
    try segment_draw(out, apex, frame.at(0, 0));
}

fn circle_draw(out: *scene.Scene, frame: Frame, distance: f32) Error!void {
    assert(distance > circle_radius);
    const center = frame.at(distance, 0);
    // The fill hides the relationship line inside the circle.
    try out.command_add(.{ .ellipse = .{
        .rect = .{
            .x = center.x - circle_radius,
            .y = center.y - circle_radius,
            .width = 2 * circle_radius,
            .height = 2 * circle_radius,
        },
        .fill = .node_fill,
        .stroke = .line,
        .stroke_width = 1.25,
    } });
}

fn draw(
    parser: *const Parser,
    graph: *const Graph,
    labels: *const Labels,
    measurer: scene.Measurer,
    out: *scene.Scene,
) Error!void {
    for (parser.relationships[0..parser.relationship_count], 0..) |relationship, index| {
        const edge: u32 = @intCast(index);
        const dash: scene.Dash = if (relationship.identifying) .solid else .dashed;
        try graph_module.edge_draw(out, graph, edge, .{ .dash = dash });
        const points = graph.edge_points(edge);
        const last = points.len - 1;
        try marker_draw(out, relationship.cardinality_source, points[0], points[1]);
        try marker_draw(out, relationship.cardinality_target, points[last], points[last - 1]);
    }
    for (graph.nodes[0..graph.node_count], 0..) |node, index| {
        const rect = graph_module.node_rect(node);
        try entity_draw(parser, @intCast(index), labels.tables[index], rect, out);
    }
    for (parser.relationships[0..parser.relationship_count], 0..) |relationship, index| {
        if (relationship.text.len == 0) continue;
        const center = graph.edges[index].label_center;
        try labels.relationships[index].draw(out, measurer, center, .text);
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
        .tables = allocator.alloc(Table, entities_max) catch return error.Overflow,
        .relationships = allocator.alloc(Label, relationships_max) catch return error.Overflow,
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
    \\erDiagram
    \\  CUSTOMER ||--o{ ORDER : places
    \\  ORDER ||--|{ LINE-ITEM : contains
    \\  CUSTOMER }|..|{ DELIVERY-ADDRESS : uses
    \\  PRODUCT |o--o| LINE-ITEM : "appears in"
    \\  CUSTOMER {
    \\    string name
    \\    string custNumber PK "unique per region"
    \\    string sector
    \\  }
    \\  ORDER {
    \\    int orderNumber PK
    \\    string deliveryAddress FK
    \\    date placed
    \\  }
    \\  LINE-ITEM {
    \\    string productCode PK, FK
    \\    int quantity
    \\    float pricePerUnit
    \\  }
    \\  p[Product] { string sku UK }
    \\  p }o--|| PRODUCT : variant
    \\  ORDER ||--|| ORDER : "follows"
;

test "er: parse entities, attributes, and relationships" {
    const scratch = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(scratch);
    const parser = try parse_test(sample, scratch);
    try testing.expectEqualStrings("LINE-ITEM", parser.entities[2].id);
    const places = parser.relationships[0];
    try testing.expectEqual(Cardinality.exactly_one, places.cardinality_source);
    try testing.expectEqual(Cardinality.zero_or_more, places.cardinality_target);
    try testing.expect(places.identifying);
    try testing.expectEqual(Cardinality.one_or_more, parser.relationships[1].cardinality_target);
    const uses = parser.relationships[2];
    try testing.expect(!uses.identifying);
    try testing.expectEqual(Cardinality.one_or_more, uses.cardinality_source);
    try testing.expectEqual(Cardinality.zero_or_one, parser.relationships[3].cardinality_source);
    try testing.expectEqualStrings("appears in", parser.relationships[3].text);
    const comment = parser.attributes[1].columns;
    try testing.expectEqualStrings("PK", comment[2]);
    try testing.expectEqualStrings("unique per region", comment[3]);
    try testing.expectEqualStrings("PK, FK", parser.attributes[6].columns[2]);
    const product = parser.entities[parser.attributes[9].entity];
    try testing.expectEqualStrings("Product", product.name);
    try testing.expectEqual(Cardinality.zero_or_more, parser.relationships[4].cardinality_source);
}

test "er: malformed input" {
    const scratch = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(scratch);
    const bad = [_][]const u8{
        "erDiagram",
        "erDiagram\n  A {\n  string name",
        "erDiagram\n  A {\n  string\n  }",
        "erDiagram\n  A ||--o{ : x",
        "erDiagram\n  A <>--<> B",
        "erDiagram\n  A {\n  string name \"open\n  }",
    };
    for (bad) |source| try testing.expectError(error.Syntax, parse_test(source, scratch));
}

test "er: too many attributes overflow" {
    const source = try testing.allocator.alloc(u8, 96 * 1024);
    defer testing.allocator.free(source);
    var writer = std.Io.Writer.fixed(source);
    try writer.writeAll("erDiagram\n  A {\n");
    var index: u32 = 0;
    while (index < attributes_max + 1) : (index += 1) try writer.print("int a{d}\n", .{index});
    try writer.writeAll("}\n");
    const scratch = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(scratch);
    try testing.expectError(error.Overflow, parse_test(writer.buffered(), scratch));
}

test "er: render sample inside the scene without overlaps" {
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
        .tables = try allocator.alloc(Table, entities_max),
        .relationships = try allocator.alloc(Label, relationships_max),
    };
    try graph_build(&parser, &graph, &labels, scene.Measurer.fixed);
    try graph.layout(allocator);
    try graph_module.testing.nodes_disjoint(&graph);
}

test "er: every prefix renders or fails cleanly" {
    try graph_module.testing.prefixes_render(sample, render);
}
