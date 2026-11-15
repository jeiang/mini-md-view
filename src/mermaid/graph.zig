//! Layered layout for directed graphs, shared by flowchart, state, class, and ER diagrams.
//!
//! The layout follows the Sugiyama framework: break cycles, assign ranks, split long edges into
//! chains of virtual nodes, order every rank to reduce crossings, and assign coordinates. It works
//! in a layout space where ranks grow along +y and the cross axis is x; horizontal directions swap
//! the axes at the end. Clusters (nested groups) stay contiguous within every rank, and their
//! boxes take part in the separation constraints, so that non-members stay outside of them.
//! Disconnected components become hidden clusters, which places them side by side.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const scene = @import("../scene.zig");

const Point = scene.Point;
const Size = scene.Size;
const Rect = scene.Rect;
const Error = scene.Error;

pub const none: u32 = std.math.maxInt(u32);
pub const nodes_max: u32 = 1024;
pub const edges_max: u32 = 2048;
pub const clusters_max: u32 = 128;
pub const cluster_depth_max: u32 = 16;
pub const edge_length_max: u32 = 8;
pub const points_max: u32 = 65536;
pub const label_lines_max: u32 = 16;
const layout_nodes_max: u32 = 16384;
const ranks_max: u32 = 512;
const sweeps_max: u32 = 24;
const coordinate_iterations: u32 = 40;
const clusters_internal_max: u32 = clusters_max + nodes_max;

comptime {
    assert(layout_nodes_max >= nodes_max);
    assert(ranks_max >= edge_length_max * 2);
    assert(points_max >= layout_nodes_max * 2);
    assert(clusters_internal_max < none);
}

const spacing_node_vertical: f32 = 40;
const spacing_node_horizontal: f32 = 26;
const spacing_rank_vertical: f32 = 50;
const spacing_rank_horizontal: f32 = 64;
const spacing_virtual: f32 = 16;
const spacing_cluster: f32 = 24;
const spacing_component: f32 = 48;
pub const cluster_padding: f32 = 14;
const cluster_title_gap: f32 = 8;
const label_clearance: f32 = 6;
const loop_extent: f32 = 24;
const attachment_gap: f32 = 14;
const loop_step: f32 = 14;
pub const margin: f32 = 16;

pub const Direction = enum {
    top_bottom,
    bottom_top,
    left_right,
    right_left,

    /// Parses the Mermaid direction keywords `TB`, `TD`, `BT`, `LR`, and `RL`.
    pub fn parse(word: []const u8) ?Direction {
        if (std.mem.eql(u8, word, "TB") or std.mem.eql(u8, word, "TD")) return .top_bottom;
        if (std.mem.eql(u8, word, "BT")) return .bottom_top;
        if (std.mem.eql(u8, word, "LR")) return .left_right;
        if (std.mem.eql(u8, word, "RL")) return .right_left;
        return null;
    }

    pub fn horizontal(direction: Direction) bool {
        return direction == .left_right or direction == .right_left;
    }
};

/// Node outlines. The layout uses the shape to clip edges at the border; `shape_draw` draws it.
pub const Shape = enum(u8) {
    rect,
    rect_round,
    stadium,
    subroutine,
    cylinder,
    circle,
    circle_double,
    diamond,
    hexagon,
    parallelogram,
    parallelogram_alt,
    trapezoid,
    trapezoid_alt,
    flag,
    /// Filled circle, the initial pseudo-state.
    start,
    /// Bullseye, the final pseudo-state.
    end,
    /// Filled bar, the fork and join pseudo-states.
    bar,
    /// Not drawn: placeholders, such as the content of an empty cluster.
    hidden,

    fn clip(shape: Shape) Clip {
        return switch (shape) {
            .circle, .circle_double, .start, .end => .ellipse,
            .diamond => .diamond,
            .hexagon => .hexagon,
            else => .box,
        };
    }
};

const Clip = enum { box, ellipse, diamond, hexagon };

pub const Node = struct {
    size: Size,
    shape: Shape,
    cluster: u32,
    /// An optional box, such as a note, kept beside the node on the cross axis: before it
    /// (left, or above in horizontal layouts) or after it. Zero width means none.
    attachment: Size = .{ .width = 0, .height = 0 },
    attachment_before: bool = false,
    /// Output: center in scene coordinates.
    center: Point = .{ .x = 0, .y = 0 },
    /// Output: center of the attachment box.
    attachment_center: Point = .{ .x = 0, .y = 0 },
};

pub const Edge = struct {
    source: u32,
    target: u32,
    /// Size of the label box, or zero for none.
    label: Size,
    /// Minimum number of ranks between source and target.
    length: u32,
    /// Output: route from the source border to the target border, in `Graph.points`.
    points: scene.PointRange = .{ .start = 0, .count = 0 },
    /// Output: center of the label box.
    label_center: Point = .{ .x = 0, .y = 0 },
};

pub const Cluster = struct {
    parent: u32,
    title: Size,
    /// Output: box in scene coordinates, and the center of its title line.
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    title_center: Point = .{ .x = 0, .y = 0 },
};

fn alloc(allocator: Allocator, comptime T: type, count: u32) Error![]T {
    return allocator.alloc(T, count) catch return error.Overflow;
}

fn alloc_fill(allocator: Allocator, comptime T: type, count: u32, value: T) Error![]T {
    const slice = try alloc(allocator, T, count);
    @memset(slice, value);
    return slice;
}

pub const Graph = struct {
    direction: Direction,
    nodes: []Node,
    node_count: u32 = 0,
    edges: []Edge,
    edge_count: u32 = 0,
    clusters: []Cluster,
    cluster_count: u32 = 0,
    points: []Point,
    point_count: u32 = 0,
    /// Output: scene size, including the margin.
    size: Size = .{ .width = 0, .height = 0 },

    pub fn init(allocator: Allocator, direction: Direction) Error!Graph {
        return .{
            .direction = direction,
            .nodes = try alloc(allocator, Node, nodes_max),
            .edges = try alloc(allocator, Edge, edges_max),
            .clusters = try alloc(allocator, Cluster, clusters_max),
            .points = try alloc(allocator, Point, points_max),
        };
    }

    pub fn node_add(graph: *Graph, size: Size, shape: Shape, cluster: u32) Error!u32 {
        assert(size.width >= 0);
        assert(size.height >= 0);
        if (cluster != none) assert(cluster < graph.cluster_count);
        if (graph.node_count == nodes_max) return error.Overflow;
        graph.nodes[graph.node_count] = .{ .size = size, .shape = shape, .cluster = cluster };
        graph.node_count += 1;
        return graph.node_count - 1;
    }

    pub fn edge_add(graph: *Graph, source: u32, target: u32, label: Size, length: u32) Error!u32 {
        assert(source < graph.node_count);
        assert(target < graph.node_count);
        assert(length >= 1);
        if (graph.edge_count == edges_max) return error.Overflow;
        graph.edges[graph.edge_count] = .{
            .source = source,
            .target = target,
            .label = label,
            .length = @min(length, edge_length_max),
        };
        graph.edge_count += 1;
        return graph.edge_count - 1;
    }

    /// Parents must be added before their children, which keeps the hierarchy acyclic.
    pub fn cluster_add(graph: *Graph, parent: u32, title: Size) Error!u32 {
        if (parent != none) assert(parent < graph.cluster_count);
        if (graph.cluster_count == clusters_max) return error.Overflow;
        var depth: u32 = 1;
        var ancestor = parent;
        while (ancestor != none) : (depth += 1) {
            if (depth == cluster_depth_max) return error.Overflow;
            ancestor = graph.clusters[ancestor].parent;
        }
        graph.clusters[graph.cluster_count] = .{ .parent = parent, .title = title };
        graph.cluster_count += 1;
        return graph.cluster_count - 1;
    }

    /// Whether `cluster` is `ancestor` or nested inside it.
    pub fn cluster_within(graph: *const Graph, cluster: u32, ancestor: u32) bool {
        assert(ancestor < graph.cluster_count);
        var current = cluster;
        var depth: u32 = 0;
        while (current != none and depth <= cluster_depth_max) : (depth += 1) {
            if (current == ancestor) return true;
            current = graph.clusters[current].parent;
        }
        return false;
    }

    /// The first or last node inside `cluster`, at any depth, or `none`. Edges that name a
    /// cluster attach to such a member and are then clipped to the cluster box.
    pub fn cluster_member(graph: *const Graph, cluster: u32, first: bool) u32 {
        assert(cluster < graph.cluster_count);
        var chosen: u32 = none;
        for (graph.nodes[0..graph.node_count], 0..) |value, index| {
            if (value.cluster == none or !graph.cluster_within(value.cluster, cluster)) continue;
            if (chosen == none or !first) chosen = @intCast(index);
        }
        assert(chosen == none or chosen < graph.node_count);
        return chosen;
    }

    pub fn edge_points(graph: *const Graph, edge: u32) []const Point {
        assert(edge < graph.edge_count);
        const range = graph.edges[edge].points;
        assert(range.start + range.count <= graph.point_count);
        return graph.points[range.start..][0..range.count];
    }

    /// Computes every output field. `allocator` provides working memory that is not used after
    /// the call returns.
    pub fn layout(graph: *Graph, allocator: Allocator) Error!void {
        assert(graph.node_count > 0);
        assert(graph.point_count == 0);
        try clusters_fill_empty(graph);
        var state = try Layout.init(graph, allocator);
        try state.components_assign(allocator);
        try state.cycles_break(allocator);
        try state.ranks_assign(allocator);
        try state.layered_build(allocator);
        try state.order(allocator);
        try state.coordinates_cross(allocator);
        try state.coordinates_rank(allocator);
        try state.output(allocator);
        assert(graph.size.width > 0);
        assert(graph.size.height > 0);
    }
};

/// Gives every empty cluster a hidden placeholder node, so that it still takes up room.
fn clusters_fill_empty(graph: *Graph) Error!void {
    var used: [clusters_max]bool = @splat(false);
    for (graph.nodes[0..graph.node_count]) |node| {
        var cluster = node.cluster;
        var depth: u32 = 0;
        while (cluster != none and depth < cluster_depth_max) : (depth += 1) {
            used[cluster] = true;
            cluster = graph.clusters[cluster].parent;
        }
    }
    var cluster: u32 = 0;
    while (cluster < graph.cluster_count) : (cluster += 1) {
        if (used[cluster]) continue;
        const title = graph.clusters[cluster].title;
        const size: Size = .{ .width = @max(title.width, 40), .height = 16 };
        _ = try graph.node_add(size, .hidden, cluster);
        var ancestor = cluster;
        var depth: u32 = 0;
        while (ancestor != none and depth < cluster_depth_max) : (depth += 1) {
            used[ancestor] = true;
            ancestor = graph.clusters[ancestor].parent;
        }
    }
}

/// Compressed adjacency: the items of key `k` are `items[start[k]..start[k + 1]]`.
const Csr = struct {
    start: []u32,
    items: []u32,

    fn build(allocator: Allocator, key_count: u32, keys: []const u32) Error!Csr {
        assert(keys.len <= std.math.maxInt(u32));
        const start = try alloc_fill(allocator, u32, key_count + 1, 0);
        for (keys) |key| {
            if (key != none) start[key + 1] += 1;
        }
        var key: u32 = 0;
        while (key < key_count) : (key += 1) start[key + 1] += start[key];
        const items = try alloc(allocator, u32, start[key_count]);
        const fill = try alloc_fill(allocator, u32, key_count, 0);
        for (keys, 0..) |item_key, item| {
            if (item_key == none) continue;
            items[start[item_key] + fill[item_key]] = @intCast(item);
            fill[item_key] += 1;
        }
        assert(start[0] == 0);
        return .{ .start = start, .items = items };
    }

    fn slice(csr: *const Csr, key: u32) []const u32 {
        assert(key + 1 < csr.start.len);
        return csr.items[csr.start[key]..csr.start[key + 1]];
    }
};

const Kind = enum(u8) { real, virtual, label, filler };

/// An entry in the cluster hierarchy: either a layered node or a cluster.
const Item = struct { cluster: bool, index: u32 };

/// A separation constraint between two layout variables: `x[to] - x[from] >= distance`.
const Constraint = struct { from: u32, to: u32, distance: f32 };

/// A route point in layout space, and the virtual node it belongs to, if any.
const Waypoint = struct { point: Point, node: u32 };

const Layout = struct {
    graph: *Graph,
    horizontal: bool,
    label_mode: bool = false,
    reversed: []bool,
    length: []u32,

    // Layered nodes: real nodes first (same index as in the graph), then virtual nodes and
    // cluster fillers.
    count: u32 = 0,
    kind: []Kind,
    rank: []u32,
    cluster: []u32,
    edge: []u32,
    extent_left: []f32,
    extent_right: []f32,
    extent_rank: []f32,
    x: []f32,
    y: []f32,
    key: []f32,
    position: []u32,

    rank_count: u32 = 0,
    ranks: Csr = undefined,
    down: Csr = undefined,
    up: Csr = undefined,
    segment_from: []u32,
    segment_to: []u32,
    segment_count: u32 = 0,
    chain_start: []u32,
    chain_count: []u32,
    chains: []u32,
    chain_total: u32 = 0,

    // Clusters: the graph's clusters, then one hidden cluster per component when there are
    // several components.
    cluster_count: u32 = 0,
    cluster_parent: []u32,
    cluster_depth: []u32,
    cluster_hidden: []bool,
    cluster_rank_min: []u32,
    cluster_rank_max: []u32,
    cluster_key: []f32,
    cluster_by_depth: []u32,

    constraints: []Constraint,
    constraint_count: u32 = 0,
    constraint_order: []u32,
    constraint_pred: Csr = undefined,
    constraint_succ: Csr = undefined,
    rank_center: []f32,
    rank_extent: []f32,

    fn init(graph: *Graph, allocator: Allocator) Error!Layout {
        const nodes = layout_nodes_max;
        const clusters = clusters_internal_max;
        return .{
            .graph = graph,
            .horizontal = graph.direction.horizontal(),
            .reversed = try alloc_fill(allocator, bool, graph.edge_count, false),
            .length = try alloc_fill(allocator, u32, graph.edge_count, 1),
            .kind = try alloc(allocator, Kind, nodes),
            .rank = try alloc_fill(allocator, u32, nodes, 0),
            .cluster = try alloc_fill(allocator, u32, nodes, none),
            .edge = try alloc_fill(allocator, u32, nodes, none),
            .extent_left = try alloc_fill(allocator, f32, nodes, 0),
            .extent_right = try alloc_fill(allocator, f32, nodes, 0),
            .extent_rank = try alloc_fill(allocator, f32, nodes, 0),
            .x = try alloc_fill(allocator, f32, nodes + 2 * clusters, 0),
            .y = try alloc_fill(allocator, f32, nodes, 0),
            .key = try alloc_fill(allocator, f32, nodes, 0),
            .position = try alloc_fill(allocator, u32, nodes, 0),
            .segment_from = try alloc(allocator, u32, nodes + edges_max),
            .segment_to = try alloc(allocator, u32, nodes + edges_max),
            .chain_start = try alloc_fill(allocator, u32, graph.edge_count, 0),
            .chain_count = try alloc_fill(allocator, u32, graph.edge_count, 0),
            .chains = try alloc(allocator, u32, nodes),
            .cluster_parent = try alloc_fill(allocator, u32, clusters, none),
            .cluster_depth = try alloc_fill(allocator, u32, clusters, 0),
            .cluster_hidden = try alloc_fill(allocator, bool, clusters, false),
            .cluster_rank_min = try alloc_fill(allocator, u32, clusters, none),
            .cluster_rank_max = try alloc_fill(allocator, u32, clusters, 0),
            .cluster_key = try alloc_fill(allocator, f32, clusters, 0),
            .cluster_by_depth = try alloc(allocator, u32, clusters),
            .constraints = try alloc(allocator, Constraint, 4 * nodes + 3 * clusters),
            .constraint_order = try alloc(allocator, u32, nodes + 2 * clusters),
            .rank_center = try alloc_fill(allocator, f32, ranks_max, 0),
            .rank_extent = try alloc_fill(allocator, f32, ranks_max, 0),
        };
    }

    // Components.

    fn components_assign(layout: *Layout, allocator: Allocator) Error!void {
        const graph = layout.graph;
        const component = try alloc(allocator, u32, graph.node_count);
        const component_count = try components_find(graph, allocator, component);
        assert(component_count >= 1);
        layout.cluster_count = graph.cluster_count;
        for (graph.clusters[0..graph.cluster_count], 0..) |cluster, index| {
            layout.cluster_parent[index] = cluster.parent;
        }
        for (graph.nodes[0..graph.node_count], 0..) |node, index| {
            layout.cluster[index] = node.cluster;
        }
        if (component_count > 1) {
            const first = graph.cluster_count;
            layout.cluster_count += component_count;
            assert(layout.cluster_count <= clusters_internal_max);
            for (layout.cluster_hidden[first..layout.cluster_count]) |*hidden| hidden.* = true;
            for (graph.nodes[0..graph.node_count], 0..) |node, index| {
                const top = cluster_top(graph, node.cluster);
                if (top == none) {
                    layout.cluster[index] = first + component[index];
                } else {
                    layout.cluster_parent[top] = first + component[index];
                }
            }
        }
        try layout.clusters_depth(allocator);
    }

    fn clusters_depth(layout: *Layout, allocator: Allocator) Error!void {
        _ = allocator;
        var count: u32 = 0;
        var depth_max: u32 = 0;
        var cluster: u32 = 0;
        while (cluster < layout.cluster_count) : (cluster += 1) {
            var depth: u32 = 0;
            var ancestor = cluster;
            while (ancestor != none) : (depth += 1) {
                assert(depth <= cluster_depth_max);
                ancestor = layout.cluster_parent[ancestor];
            }
            layout.cluster_depth[cluster] = depth;
            depth_max = @max(depth_max, depth);
        }
        // Deepest first, so that children are visited before their parents.
        var depth = depth_max;
        while (depth > 0) : (depth -= 1) {
            cluster = 0;
            while (cluster < layout.cluster_count) : (cluster += 1) {
                if (layout.cluster_depth[cluster] != depth) continue;
                layout.cluster_by_depth[count] = cluster;
                count += 1;
            }
        }
        assert(count == layout.cluster_count);
    }

    // Cycles.

    /// Reverses the back edges of a depth-first search, which makes the graph acyclic.
    fn cycles_break(layout: *Layout, allocator: Allocator) Error!void {
        const graph = layout.graph;
        const node_count = graph.node_count;
        const keys = try alloc(allocator, u32, graph.edge_count);
        for (graph.edges[0..graph.edge_count], keys) |edge, *key| {
            key.* = if (edge.source == edge.target) none else edge.source;
        }
        const out = try Csr.build(allocator, node_count, keys);
        const state = try alloc_fill(allocator, u8, node_count, 0);
        const stack_node = try alloc(allocator, u32, node_count);
        const stack_cursor = try alloc(allocator, u32, node_count);
        var root: u32 = 0;
        while (root < node_count) : (root += 1) {
            if (state[root] != 0) continue;
            var depth: u32 = 1;
            stack_node[0] = root;
            stack_cursor[0] = out.start[root];
            state[root] = 1;
            var steps: u32 = 0;
            while (depth > 0) : (steps += 1) {
                assert(steps <= 2 * (node_count + graph.edge_count));
                const node = stack_node[depth - 1];
                const cursor = stack_cursor[depth - 1];
                if (cursor == out.start[node + 1]) {
                    state[node] = 2;
                    depth -= 1;
                    continue;
                }
                stack_cursor[depth - 1] += 1;
                const edge = out.items[cursor];
                const target = graph.edges[edge].target;
                if (state[target] == 1) layout.reversed[edge] = true;
                if (state[target] != 0) continue;
                state[target] = 1;
                stack_node[depth] = target;
                stack_cursor[depth] = out.start[target];
                depth += 1;
            }
        }
    }

    fn dag_source(layout: *const Layout, edge: u32) u32 {
        const value = layout.graph.edges[edge];
        return if (layout.reversed[edge]) value.target else value.source;
    }

    fn dag_target(layout: *const Layout, edge: u32) u32 {
        const value = layout.graph.edges[edge];
        return if (layout.reversed[edge]) value.source else value.target;
    }

    fn edge_self(layout: *const Layout, edge: u32) bool {
        const value = layout.graph.edges[edge];
        return value.source == value.target;
    }

    // Ranks.

    /// Labels and parallel edges need a virtual node of their own on every edge, so that mode
    /// doubles all edge lengths.
    fn label_mode_detect(layout: *const Layout) bool {
        const edges = layout.graph.edges[0..layout.graph.edge_count];
        for (edges, 0..) |edge, index| {
            if (edge.source == edge.target) continue;
            if (edge.label.width > 0) return true;
            for (edges[index + 1 ..]) |other| {
                const same = other.source == edge.source and other.target == edge.target;
                const opposite = other.source == edge.target and other.target == edge.source;
                if (same or opposite) return true;
            }
        }
        return false;
    }

    /// Longest-path ranking, followed by pulling sources down next to their successors.
    fn ranks_assign(layout: *Layout, allocator: Allocator) Error!void {
        const graph = layout.graph;
        const node_count = graph.node_count;
        layout.label_mode = layout.label_mode_detect();
        const keys = try alloc(allocator, u32, graph.edge_count);
        const indegree = try alloc_fill(allocator, u32, node_count, 0);
        for (keys, 0..) |*key, index| {
            const edge: u32 = @intCast(index);
            const scale: u32 = if (layout.label_mode) 2 else 1;
            layout.length[edge] = graph.edges[edge].length * scale;
            key.* = if (layout.edge_self(edge)) none else layout.dag_source(edge);
            if (key.* != none) indegree[layout.dag_target(edge)] += 1;
        }
        const out = try Csr.build(allocator, node_count, keys);
        const queue = try alloc(allocator, u32, node_count);
        var queue_count: u32 = 0;
        for (indegree, 0..) |degree, node| {
            if (degree == 0) queue[queue_count] = @intCast(node);
            if (degree == 0) queue_count += 1;
        }
        var head: u32 = 0;
        while (head < queue_count) : (head += 1) {
            const node = queue[head];
            for (out.slice(node)) |edge| {
                const target = layout.dag_target(edge);
                const reach = layout.rank[node] + layout.length[edge];
                layout.rank[target] = @max(layout.rank[target], reach);
                indegree[target] -= 1;
                if (indegree[target] == 0) queue[queue_count] = target;
                if (indegree[target] == 0) queue_count += 1;
            }
        }
        assert(queue_count == node_count);
        layout.sources_pull(&out, indegree);
        for (layout.rank[0..node_count]) |rank| {
            if (rank >= ranks_max) return error.Overflow;
            layout.rank_count = @max(layout.rank_count, rank + 1);
        }
    }

    fn sources_pull(layout: *Layout, out: *const Csr, indegree: []u32) void {
        const graph = layout.graph;
        @memset(indegree, 0);
        for (graph.edges[0..graph.edge_count], 0..) |edge, index| {
            if (edge.source != edge.target) indegree[layout.dag_target(@intCast(index))] += 1;
        }
        var node: u32 = 0;
        while (node < graph.node_count) : (node += 1) {
            const edges = out.slice(node);
            if (indegree[node] != 0 or edges.len == 0) continue;
            var rank_min: u32 = none;
            for (edges) |edge| {
                const rank_target = layout.rank[layout.dag_target(edge)];
                rank_min = @min(rank_min, rank_target - layout.length[edge]);
            }
            assert(rank_min >= layout.rank[node]);
            layout.rank[node] = rank_min;
        }
    }

    // Layered graph.

    fn layered_build(layout: *Layout, allocator: Allocator) Error!void {
        const graph = layout.graph;
        layout.count = graph.node_count;
        for (graph.nodes[0..graph.node_count], 0..) |node, index| {
            layout.kind[index] = .real;
            const cross = if (layout.horizontal) node.size.height else node.size.width;
            layout.extent_left[index] = cross / 2;
            layout.extent_right[index] = cross / 2;
            const along = if (layout.horizontal) node.size.width else node.size.height;
            layout.extent_rank[index] = along;
            layout.attachment_reserve(@intCast(index));
        }
        layout.loops_reserve();
        var edge: u32 = 0;
        while (edge < graph.edge_count) : (edge += 1) {
            if (!layout.edge_self(edge)) try layout.chain_build(edge);
        }
        try layout.clusters_span(allocator);
        layout.ranks = try Csr.build(allocator, layout.rank_count, layout.rank[0..layout.count]);
        try layout.segments_build(allocator);
    }

    /// An attachment widens its node on one side, so that separation keeps it clear.
    fn attachment_reserve(layout: *Layout, node: u32) void {
        const attachment = layout.graph.nodes[node].attachment;
        assert(attachment.width >= 0);
        assert(attachment.height >= 0);
        if (attachment.width == 0) return;
        const cross = if (layout.horizontal) attachment.height else attachment.width;
        const along = if (layout.horizontal) attachment.width else attachment.height;
        if (layout.graph.nodes[node].attachment_before) {
            layout.extent_left[node] += attachment_gap + cross;
        } else {
            layout.extent_right[node] += attachment_gap + cross;
        }
        layout.extent_rank[node] = @max(layout.extent_rank[node], along);
    }

    /// Self-loops are drawn on the cross-axis end side of their node: reserve that room.
    fn loops_reserve(layout: *Layout) void {
        const graph = layout.graph;
        var loops: [nodes_max]u8 = @splat(0);
        for (graph.edges[0..graph.edge_count]) |edge| {
            if (edge.source != edge.target) continue;
            const label = if (layout.horizontal) edge.label.height else edge.label.width;
            const index = loops[edge.source];
            const extent = loop_extent + loop_step * @as(f32, @floatFromInt(index));
            const right = graph.nodes[edge.source].size;
            const half = (if (layout.horizontal) right.height else right.width) / 2;
            const needed = half + extent + label_clearance + label;
            layout.extent_right[edge.source] = @max(layout.extent_right[edge.source], needed);
            loops[edge.source] +|= 1;
        }
    }

    fn chain_build(layout: *Layout, edge: u32) Error!void {
        const source = layout.dag_source(edge);
        const target = layout.dag_target(edge);
        assert(layout.rank[target] >= layout.rank[source] + layout.length[edge]);
        const span = layout.rank[target] - layout.rank[source];
        const label = layout.graph.edges[edge].label;
        const cluster = layout.cluster_common(layout.cluster[source], layout.cluster[target]);
        layout.chain_start[edge] = layout.chain_total;
        layout.chain_count[edge] = span - 1;
        if (layout.count + span - 1 > layout_nodes_max) return error.Overflow;
        var step: u32 = 1;
        while (step < span) : (step += 1) {
            const node = layout.count;
            layout.count += 1;
            layout.chains[layout.chain_total] = node;
            layout.chain_total += 1;
            layout.rank[node] = layout.rank[source] + step;
            layout.cluster[node] = cluster;
            layout.edge[node] = edge;
            layout.kind[node] = .virtual;
            layout.extent_left[node] = 0;
            layout.extent_right[node] = 0;
            layout.extent_rank[node] = 0;
            if (layout.label_mode and label.width > 0 and step == span / 2) {
                layout.kind[node] = .label;
                const cross = if (layout.horizontal) label.height else label.width;
                layout.extent_right[node] = label_clearance + cross;
                layout.extent_rank[node] = if (layout.horizontal) label.width else label.height;
            }
        }
    }

    fn cluster_parent_of(layout: *const Layout, cluster: u32) u32 {
        return layout.cluster_parent[cluster];
    }

    fn cluster_depth_of(layout: *const Layout, cluster: u32) u32 {
        return if (cluster == none) 0 else layout.cluster_depth[cluster];
    }

    /// The innermost cluster that contains both clusters, or `none` for the root.
    fn cluster_common(layout: *const Layout, a: u32, b: u32) u32 {
        var left = a;
        var right = b;
        var steps: u32 = 0;
        while (left != right) : (steps += 1) {
            assert(steps <= 2 * cluster_depth_max + 2);
            if (layout.cluster_depth_of(left) >= layout.cluster_depth_of(right)) {
                left = layout.cluster_parent[left];
            } else {
                right = layout.cluster_parent[right];
            }
        }
        return left;
    }

    /// Computes the rank span of every cluster, and adds a filler node on every rank inside the
    /// span where the cluster has no node, so that its box is protected on every rank.
    fn clusters_span(layout: *Layout, allocator: Allocator) Error!void {
        const ranks = layout.rank_count;
        const present = try alloc_fill(allocator, bool, layout.cluster_count * ranks, false);
        var node: u32 = 0;
        while (node < layout.count) : (node += 1) {
            layout.cluster_mark(node, present);
        }
        var cluster: u32 = 0;
        while (cluster < layout.cluster_count) : (cluster += 1) {
            const rank_min = layout.cluster_rank_min[cluster];
            assert(rank_min != none);
            var rank = rank_min;
            while (rank <= layout.cluster_rank_max[cluster]) : (rank += 1) {
                if (present[cluster * ranks + rank]) continue;
                if (layout.count == layout_nodes_max) return error.Overflow;
                const filler = layout.count;
                layout.count += 1;
                layout.kind[filler] = .filler;
                layout.rank[filler] = rank;
                layout.cluster[filler] = cluster;
                layout.cluster_mark(filler, present);
            }
        }
    }

    fn cluster_mark(layout: *Layout, node: u32, present: []bool) void {
        const rank = layout.rank[node];
        var cluster = layout.cluster[node];
        var depth: u32 = 0;
        while (cluster != none) : (depth += 1) {
            assert(depth <= cluster_depth_max);
            present[cluster * layout.rank_count + rank] = true;
            layout.cluster_rank_min[cluster] = @min(layout.cluster_rank_min[cluster], rank);
            layout.cluster_rank_max[cluster] = @max(layout.cluster_rank_max[cluster], rank);
            cluster = layout.cluster_parent[cluster];
        }
    }

    fn segments_build(layout: *Layout, allocator: Allocator) Error!void {
        const graph = layout.graph;
        var edge: u32 = 0;
        while (edge < graph.edge_count) : (edge += 1) {
            if (layout.edge_self(edge)) continue;
            var previous = layout.dag_source(edge);
            const chain = layout.chains[layout.chain_start[edge]..][0..layout.chain_count[edge]];
            for (chain) |node| {
                layout.segment_add(previous, node);
                previous = node;
            }
            layout.segment_add(previous, layout.dag_target(edge));
        }
        const segments = layout.segment_count;
        layout.down = try Csr.build(allocator, layout.count, layout.segment_from[0..segments]);
        layout.up = try Csr.build(allocator, layout.count, layout.segment_to[0..segments]);
    }

    fn segment_add(layout: *Layout, from: u32, to: u32) void {
        assert(layout.rank[to] == layout.rank[from] + 1);
        assert(layout.segment_count < layout.segment_from.len);
        layout.segment_from[layout.segment_count] = from;
        layout.segment_to[layout.segment_count] = to;
        layout.segment_count += 1;
    }

    /// Straight long edges matter more than short ones, so virtual segments weigh more.
    fn segment_weight(layout: *const Layout, segment: u32) f32 {
        const from_virtual = layout.kind[layout.segment_from[segment]] != .real;
        const to_virtual = layout.kind[layout.segment_to[segment]] != .real;
        if (from_virtual and to_virtual) return 8;
        if (from_virtual or to_virtual) return 2;
        return 1;
    }

    // Ordering.

    fn rank_nodes(layout: *const Layout, rank: u32) []u32 {
        assert(rank < layout.rank_count);
        return layout.ranks.items[layout.ranks.start[rank]..layout.ranks.start[rank + 1]];
    }

    fn order(layout: *Layout, allocator: Allocator) Error!void {
        try layout.order_initial(allocator);
        layout.positions_update();
        layout.cluster_keys_update(false);
        var rank: u32 = 0;
        while (rank < layout.rank_count) : (rank += 1) {
            for (layout.rank_nodes(rank)) |node| {
                layout.key[node] = @floatFromInt(layout.position[node]);
            }
            layout.rank_sort(rank);
        }
        const best = try alloc(allocator, u32, layout.count);
        const tree = try alloc(allocator, u32, layout.count + 1);
        @memcpy(best, layout.ranks.items[0..layout.count]);
        var crossings_best = layout.crossings_count(tree);
        var sweep_index: u32 = 0;
        while (sweep_index < sweeps_max and crossings_best > 0) : (sweep_index += 1) {
            layout.sweep(sweep_index % 2 == 0);
            layout.cluster_keys_update(true);
            const crossings = layout.crossings_count(tree);
            if (crossings < crossings_best) {
                crossings_best = crossings;
                @memcpy(best, layout.ranks.items[0..layout.count]);
            }
        }
        @memcpy(layout.ranks.items[0..layout.count], best);
        layout.positions_update();
    }

    /// Depth-first order from the top ranks, which keeps connected nodes together initially.
    fn order_initial(layout: *Layout, allocator: Allocator) Error!void {
        const visited = try alloc_fill(allocator, bool, layout.count, false);
        const fill = try alloc_fill(allocator, u32, layout.rank_count, 0);
        const stack_node = try alloc(allocator, u32, layout.count);
        const stack_cursor = try alloc(allocator, u32, layout.count);
        const roots = try alloc(allocator, u32, layout.count);
        @memcpy(roots, layout.ranks.items[0..layout.count]);
        for (roots) |root| {
            if (visited[root]) continue;
            var depth: u32 = 1;
            stack_node[0] = root;
            stack_cursor[0] = layout.down.start[root];
            layout.order_place(root, visited, fill);
            var steps: u32 = 0;
            while (depth > 0) : (steps += 1) {
                assert(steps <= 2 * (layout.count + layout.segment_count));
                const node = stack_node[depth - 1];
                const cursor = stack_cursor[depth - 1];
                if (cursor == layout.down.start[node + 1]) {
                    depth -= 1;
                    continue;
                }
                stack_cursor[depth - 1] += 1;
                const target = layout.segment_to[layout.down.items[cursor]];
                if (visited[target]) continue;
                layout.order_place(target, visited, fill);
                stack_node[depth] = target;
                stack_cursor[depth] = layout.down.start[target];
                depth += 1;
            }
        }
    }

    fn order_place(layout: *Layout, node: u32, visited: []bool, fill: []u32) void {
        assert(!visited[node]);
        const rank = layout.rank[node];
        visited[node] = true;
        layout.ranks.items[layout.ranks.start[rank] + fill[rank]] = node;
        fill[rank] += 1;
        assert(layout.ranks.start[rank] + fill[rank] <= layout.ranks.start[rank + 1]);
    }

    fn positions_update(layout: *Layout) void {
        var rank: u32 = 0;
        while (rank < layout.rank_count) : (rank += 1) {
            for (layout.rank_nodes(rank), 0..) |node, position| {
                layout.position[node] = @intCast(position);
            }
        }
    }

    /// Mean position of the neighbors in the reference rank, or the current position when the
    /// node has no neighbors there.
    fn barycenter(layout: *const Layout, node: u32, upward: bool, downward: bool) f32 {
        var sum: f32 = 0;
        var count: f32 = 0;
        if (upward) for (layout.up.slice(node)) |segment| {
            sum += @floatFromInt(layout.position[layout.segment_from[segment]]);
            count += 1;
        };
        if (downward) for (layout.down.slice(node)) |segment| {
            sum += @floatFromInt(layout.position[layout.segment_to[segment]]);
            count += 1;
        };
        if (count == 0) return @floatFromInt(layout.position[node]);
        return sum / count;
    }

    /// The cluster sort key is shared by all ranks, so sibling clusters have the same order on
    /// every rank. That keeps the separation constraints acyclic.
    fn cluster_keys_update(layout: *Layout, barycentric: bool) void {
        var sums: [clusters_internal_max]f32 = undefined;
        var counts: [clusters_internal_max]f32 = undefined;
        @memset(sums[0..layout.cluster_count], 0);
        @memset(counts[0..layout.cluster_count], 0);
        var node: u32 = 0;
        while (node < layout.count) : (node += 1) {
            const value = if (barycentric)
                layout.barycenter(node, true, true)
            else
                @as(f32, @floatFromInt(layout.position[node]));
            var cluster = layout.cluster[node];
            var depth: u32 = 0;
            while (cluster != none) : (depth += 1) {
                assert(depth <= cluster_depth_max);
                sums[cluster] += value;
                counts[cluster] += 1;
                cluster = layout.cluster_parent[cluster];
            }
        }
        for (0..layout.cluster_count) |cluster| {
            assert(counts[cluster] > 0);
            layout.cluster_key[cluster] = sums[cluster] / counts[cluster];
        }
    }

    fn sweep(layout: *Layout, downward: bool) void {
        assert(layout.rank_count > 0);
        var step: u32 = 0;
        while (step < layout.rank_count) : (step += 1) {
            const rank = if (downward) step else layout.rank_count - 1 - step;
            for (layout.rank_nodes(rank)) |node| {
                layout.key[node] = layout.barycenter(node, downward, !downward);
            }
            layout.rank_sort(rank);
            for (layout.rank_nodes(rank), 0..) |node, position| {
                layout.position[node] = @intCast(position);
            }
        }
    }

    fn rank_sort(layout: *Layout, rank: u32) void {
        const nodes = layout.rank_nodes(rank);
        std.sort.insertion(u32, nodes, @as(*const Layout, layout), node_less);
        if (nodes.len > 0) assert(layout.rank[nodes[0]] == rank);
    }

    fn item_parent(layout: *const Layout, item: Item) u32 {
        return if (item.cluster) layout.cluster_parent[item.index] else layout.cluster[item.index];
    }

    fn item_depth(layout: *const Layout, item: Item) u32 {
        return layout.cluster_depth_of(layout.item_parent(item)) + 1;
    }

    /// The cluster that contains the item. Builds the result in a separate value, because
    /// assigning a struct literal to the item it reads from would alias.
    fn item_lift(layout: *const Layout, item: Item) Item {
        const parent = layout.item_parent(item);
        assert(parent != none);
        return .{ .cluster = true, .index = parent };
    }

    /// Lifts two nodes to the children of their innermost common cluster.
    fn items_diverge(layout: *const Layout, a: u32, b: u32) [2]Item {
        var left: Item = .{ .cluster = false, .index = a };
        var right: Item = .{ .cluster = false, .index = b };
        var steps: u32 = 0;
        while (layout.item_depth(left) > layout.item_depth(right)) : (steps += 1) {
            assert(steps <= cluster_depth_max);
            left = layout.item_lift(left);
        }
        while (layout.item_depth(right) > layout.item_depth(left)) : (steps += 1) {
            assert(steps <= cluster_depth_max);
            right = layout.item_lift(right);
        }
        while (layout.item_parent(left) != layout.item_parent(right)) : (steps += 1) {
            assert(steps <= 2 * cluster_depth_max);
            left = layout.item_lift(left);
            right = layout.item_lift(right);
        }
        return .{ left, right };
    }

    /// A strict total order on items: by key, then clusters before nodes, then by position or
    /// index. Every member of a cluster compares alike against outsiders, so the members end
    /// up contiguous.
    fn node_less(layout: *const Layout, a: u32, b: u32) bool {
        if (a == b) return false;
        const items = layout.items_diverge(a, b);
        const left = items[0];
        const right = items[1];
        const key_left =
            if (left.cluster) layout.cluster_key[left.index] else layout.key[left.index];
        const key_right =
            if (right.cluster) layout.cluster_key[right.index] else layout.key[right.index];
        if (key_left != key_right) return key_left < key_right;
        if (left.cluster != right.cluster) return left.cluster;
        if (left.cluster) return left.index < right.index;
        return layout.position[left.index] < layout.position[right.index];
    }

    /// Counts crossings between adjacent ranks with a Fenwick tree over lower positions.
    fn crossings_count(layout: *const Layout, tree: []u32) u64 {
        var crossings: u64 = 0;
        var rank: u32 = 0;
        while (rank + 1 < layout.rank_count) : (rank += 1) {
            const size: u32 = @intCast(layout.rank_nodes(rank + 1).len);
            @memset(tree[0 .. size + 1], 0);
            var inserted: u64 = 0;
            for (layout.rank_nodes(rank)) |node| {
                for (layout.down.slice(node)) |segment| {
                    const position = layout.position[layout.segment_to[segment]];
                    crossings += inserted - fenwick_prefix(tree, position + 1);
                }
                for (layout.down.slice(node)) |segment| {
                    const position = layout.position[layout.segment_to[segment]];
                    fenwick_add(tree[0 .. size + 1], position + 1);
                    inserted += 1;
                }
            }
        }
        return crossings;
    }

    // Cross-axis coordinates.

    fn variable_left(layout: *const Layout, cluster: u32) u32 {
        assert(cluster < layout.cluster_count);
        return layout.count + 2 * cluster;
    }

    fn variable_right(layout: *const Layout, cluster: u32) u32 {
        assert(cluster < layout.cluster_count);
        return layout.count + 2 * cluster + 1;
    }

    fn cluster_pad(layout: *const Layout, cluster: u32) f32 {
        return if (layout.cluster_hidden[cluster]) 0 else cluster_padding;
    }

    /// Room for the title on the cross-axis start side: the title sits at the top of the scene,
    /// which is the cross-axis start in horizontal layouts.
    fn cluster_title_cross(layout: *const Layout, cluster: u32) f32 {
        if (layout.cluster_hidden[cluster] or !layout.horizontal) return 0;
        const title = layout.graph.clusters[cluster].title;
        return if (title.height > 0) title.height + cluster_title_gap else 0;
    }

    /// Room for the title on a rank-axis side: the start for top-to-bottom, the end for
    /// bottom-to-top, whose end becomes the top of the scene.
    fn cluster_title_rank(layout: *const Layout, cluster: u32, start: bool) f32 {
        if (layout.cluster_hidden[cluster] or layout.horizontal) return 0;
        if (start != (layout.graph.direction == .top_bottom)) return 0;
        const title = layout.graph.clusters[cluster].title;
        return if (title.height > 0) title.height + cluster_title_gap else 0;
    }

    fn constraint_add(layout: *Layout, from: u32, to: u32, distance: f32) void {
        assert(from != to);
        assert(layout.constraint_count < layout.constraints.len);
        layout.constraints[layout.constraint_count] = .{
            .from = from,
            .to = to,
            .distance = distance,
        };
        layout.constraint_count += 1;
    }

    fn constraints_build(layout: *Layout, allocator: Allocator) Error!void {
        var node: u32 = 0;
        while (node < layout.count) : (node += 1) {
            const cluster = layout.cluster[node];
            if (cluster == none) continue;
            const pad = layout.cluster_pad(cluster);
            const title = layout.cluster_title_cross(cluster);
            const left = layout.variable_left(cluster);
            const right = layout.variable_right(cluster);
            layout.constraint_add(left, node, layout.extent_left[node] + pad + title);
            layout.constraint_add(node, right, layout.extent_right[node] + pad);
        }
        var cluster: u32 = 0;
        while (cluster < layout.cluster_count) : (cluster += 1) {
            const parent = layout.cluster_parent[cluster];
            if (parent != none) {
                const pad = layout.cluster_pad(parent);
                const title = layout.cluster_title_cross(parent);
                const left = layout.variable_left(cluster);
                const right = layout.variable_right(cluster);
                layout.constraint_add(layout.variable_left(parent), left, pad + title);
                layout.constraint_add(right, layout.variable_right(parent), pad);
            }
            const width = layout.cluster_title_width(cluster);
            if (width > 0) {
                const left = layout.variable_left(cluster);
                layout.constraint_add(left, layout.variable_right(cluster), width);
            }
        }
        var rank: u32 = 0;
        while (rank < layout.rank_count) : (rank += 1) {
            const nodes = layout.rank_nodes(rank);
            if (nodes.len < 2) continue;
            for (nodes[0 .. nodes.len - 1], nodes[1..]) |a, b| layout.constraint_adjacent(a, b);
        }
        try layout.constraints_sort(allocator);
    }

    fn cluster_title_width(layout: *const Layout, cluster: u32) f32 {
        if (layout.cluster_hidden[cluster] or layout.horizontal) return 0;
        const title = layout.graph.clusters[cluster].title;
        return if (title.width > 0) title.width + 2 * cluster_padding else 0;
    }

    fn constraint_adjacent(layout: *Layout, a: u32, b: u32) void {
        const items = layout.items_diverge(a, b);
        const left = items[0];
        const right = items[1];
        const from = if (left.cluster) layout.variable_right(left.index) else a;
        const to = if (right.cluster) layout.variable_left(right.index) else b;
        var gap: f32 = spacing_virtual;
        if (left.cluster or right.cluster) {
            const hidden_left = left.cluster and layout.cluster_hidden[left.index];
            const hidden_right = right.cluster and layout.cluster_hidden[right.index];
            gap = if (hidden_left or hidden_right) spacing_component else spacing_cluster;
        } else if (layout.kind[a] == .real and layout.kind[b] == .real) {
            gap = if (layout.horizontal) spacing_node_horizontal else spacing_node_vertical;
        } else if (layout.kind[a] == .real or layout.kind[b] == .real) {
            gap = spacing_virtual * 1.5;
        }
        const distance_left = if (left.cluster) 0 else layout.extent_right[a];
        const distance_right = if (right.cluster) 0 else layout.extent_left[b];
        layout.constraint_add(from, to, distance_left + gap + distance_right);
    }

    /// Topological order of the constraint graph (Kahn). The ordering step keeps it acyclic;
    /// should a cycle slip through anyway, its variables are appended so that nothing is lost.
    fn constraints_sort(layout: *Layout, allocator: Allocator) Error!void {
        const variables = layout.count + 2 * layout.cluster_count;
        const constraints = layout.constraints[0..layout.constraint_count];
        const froms = try alloc(allocator, u32, layout.constraint_count);
        const tos = try alloc(allocator, u32, layout.constraint_count);
        for (constraints, froms, tos) |constraint, *from, *to| {
            from.* = constraint.from;
            to.* = constraint.to;
        }
        layout.constraint_succ = try Csr.build(allocator, variables, froms);
        layout.constraint_pred = try Csr.build(allocator, variables, tos);
        const indegree = try alloc_fill(allocator, u32, variables, 0);
        const placed = try alloc_fill(allocator, bool, variables, false);
        for (tos) |to| indegree[to] += 1;
        var count: u32 = 0;
        for (indegree, 0..) |degree, variable| {
            if (degree != 0) continue;
            layout.constraint_order[count] = @intCast(variable);
            placed[variable] = true;
            count += 1;
        }
        var head: u32 = 0;
        while (head < count) : (head += 1) {
            for (layout.constraint_succ.slice(layout.constraint_order[head])) |index| {
                const to = constraints[index].to;
                indegree[to] -= 1;
                if (indegree[to] != 0 or placed[to]) continue;
                layout.constraint_order[count] = to;
                placed[to] = true;
                count += 1;
            }
        }
        for (placed, 0..) |done, variable| {
            if (done) continue;
            layout.constraint_order[count] = @intCast(variable);
            count += 1;
        }
        assert(count == variables);
    }

    fn push_right(layout: *const Layout, x: []f32) void {
        const variables = layout.count + 2 * layout.cluster_count;
        for (layout.constraint_order[0..variables]) |variable| {
            for (layout.constraint_pred.slice(variable)) |index| {
                const constraint = layout.constraints[index];
                x[variable] = @max(x[variable], x[constraint.from] + constraint.distance);
            }
        }
    }

    fn push_left(layout: *const Layout, x: []f32) void {
        const variables = layout.count + 2 * layout.cluster_count;
        var step: u32 = variables;
        while (step > 0) : (step -= 1) {
            const variable = layout.constraint_order[step - 1];
            for (layout.constraint_succ.slice(variable)) |index| {
                const constraint = layout.constraints[index];
                x[variable] = @min(x[variable], x[constraint.to] - constraint.distance);
            }
        }
    }

    /// Alternates pulling every node toward the weighted mean of its neighbors with projecting
    /// the result back onto the separation constraints, which minimizes the squared horizontal
    /// edge lengths: parents end up centered over children, and long edges straight.
    fn coordinates_cross(layout: *Layout, allocator: Allocator) Error!void {
        try layout.constraints_build(allocator);
        const variables = layout.count + 2 * layout.cluster_count;
        const x = layout.x[0..variables];
        var solver = try Solver.init(allocator, variables);
        @memset(x, 0);
        layout.push_right(x);
        var iteration: u32 = 0;
        while (iteration < coordinate_iterations) : (iteration += 1) {
            layout.neighbors_pull(iteration % 2 == 0);
            layout.borders_tighten();
            solver.project(layout, x);
        }
        layout.components_pack();
        var minimum: f32 = std.math.inf(f32);
        for (x) |value| minimum = @min(minimum, value);
        for (x) |*value| value.* -= minimum;
        assert(minimum != std.math.inf(f32));
    }

    /// Components never pull on each other, so they are packed side by side at the end, in
    /// their current order, without changing their inner layout.
    fn components_pack(layout: *Layout) void {
        const first = layout.graph.cluster_count;
        if (layout.cluster_count == first) return;
        var shifts: [clusters_internal_max]f32 = @splat(0);
        var placed_already: [clusters_internal_max]bool = @splat(false);
        var cursor: f32 = 0;
        var placed: u32 = 0;
        while (placed < layout.cluster_count - first) : (placed += 1) {
            var best: u32 = none;
            var cluster = first;
            while (cluster < layout.cluster_count) : (cluster += 1) {
                if (placed_already[cluster]) continue;
                const left = layout.x[layout.variable_left(cluster)];
                if (best == none or left < layout.x[layout.variable_left(best)]) best = cluster;
            }
            assert(best != none);
            const left = layout.x[layout.variable_left(best)];
            shifts[best] = cursor - left;
            cursor += layout.x[layout.variable_right(best)] - left + spacing_component;
            placed_already[best] = true;
        }
        layout.shifts_apply(shifts[0..layout.cluster_count]);
    }

    /// Moves every variable by the shift of its top-level cluster.
    fn shifts_apply(layout: *Layout, shifts: []const f32) void {
        const variables = layout.count + 2 * layout.cluster_count;
        var variable: u32 = 0;
        while (variable < variables) : (variable += 1) {
            var cluster = if (variable < layout.count)
                layout.cluster[variable]
            else
                (variable - layout.count) / 2;
            var depth: u32 = 0;
            while (layout.cluster_parent[cluster] != none) : (depth += 1) {
                assert(depth <= cluster_depth_max);
                cluster = layout.cluster_parent[cluster];
            }
            assert(cluster >= layout.graph.cluster_count);
            layout.x[variable] += shifts[cluster];
        }
    }

    fn neighbors_pull(layout: *Layout, downward: bool) void {
        var step: u32 = 0;
        while (step < layout.rank_count) : (step += 1) {
            const rank = if (downward) step else layout.rank_count - 1 - step;
            for (layout.rank_nodes(rank)) |node| {
                var sum: f32 = 0;
                var weight: f32 = 0;
                for (layout.up.slice(node)) |segment| {
                    const value = layout.segment_weight(segment);
                    sum += value * layout.x[layout.segment_from[segment]];
                    weight += value;
                }
                for (layout.down.slice(node)) |segment| {
                    const value = layout.segment_weight(segment);
                    sum += value * layout.x[layout.segment_to[segment]];
                    weight += value;
                }
                if (weight > 0) {
                    layout.x[node] = sum / weight;
                } else if (layout.kind[node] == .filler) {
                    const cluster = layout.cluster[node];
                    const border_left = layout.x[layout.variable_left(cluster)];
                    layout.x[node] = (border_left + layout.x[layout.variable_right(cluster)]) / 2;
                }
            }
        }
    }

    /// Moves every cluster border tight around its members, deepest clusters first.
    fn borders_tighten(layout: *Layout) void {
        var low: [clusters_internal_max]f32 = undefined;
        var high: [clusters_internal_max]f32 = undefined;
        @memset(low[0..layout.cluster_count], std.math.inf(f32));
        @memset(high[0..layout.cluster_count], -std.math.inf(f32));
        var node: u32 = 0;
        while (node < layout.count) : (node += 1) {
            const cluster = layout.cluster[node];
            if (cluster == none) continue;
            const pad = layout.cluster_pad(cluster);
            const title = layout.cluster_title_cross(cluster);
            const reach = layout.x[node] - layout.extent_left[node] - pad - title;
            low[cluster] = @min(low[cluster], reach);
            high[cluster] = @max(high[cluster], layout.x[node] + layout.extent_right[node] + pad);
        }
        for (layout.cluster_by_depth[0..layout.cluster_count]) |cluster| {
            assert(low[cluster] <= high[cluster]);
            const deficit = layout.cluster_title_width(cluster) - (high[cluster] - low[cluster]);
            if (deficit > 0) {
                low[cluster] -= deficit / 2;
                high[cluster] += deficit / 2;
            }
            layout.x[layout.variable_left(cluster)] = low[cluster];
            layout.x[layout.variable_right(cluster)] = high[cluster];
            const parent = layout.cluster_parent[cluster];
            if (parent == none) continue;
            const pad = layout.cluster_pad(parent);
            const title = layout.cluster_title_cross(parent);
            low[parent] = @min(low[parent], low[cluster] - pad - title);
            high[parent] = @max(high[parent], high[cluster] + pad);
        }
    }

    // Rank-axis coordinates.

    fn coordinates_rank(layout: *Layout, allocator: Allocator) Error!void {
        const extra_start = try alloc_fill(allocator, f32, layout.rank_count, 0);
        const extra_end = try alloc_fill(allocator, f32, layout.rank_count, 0);
        var node: u32 = 0;
        while (node < layout.count) : (node += 1) {
            const rank = layout.rank[node];
            layout.rank_extent[rank] = @max(layout.rank_extent[rank], layout.extent_rank[node]);
            var start: f32 = 0;
            var end: f32 = 0;
            var cluster = layout.cluster[node];
            var depth: u32 = 0;
            while (cluster != none) : (depth += 1) {
                assert(depth <= cluster_depth_max);
                const pad = layout.cluster_pad(cluster);
                if (layout.cluster_rank_min[cluster] == rank) {
                    start += pad + layout.cluster_title_rank(cluster, true);
                }
                if (layout.cluster_rank_max[cluster] == rank) {
                    end += pad + layout.cluster_title_rank(cluster, false);
                }
                cluster = layout.cluster_parent[cluster];
            }
            extra_start[rank] = @max(extra_start[rank], start);
            extra_end[rank] = @max(extra_end[rank], end);
        }
        const spacing_full =
            if (layout.horizontal) spacing_rank_horizontal else spacing_rank_vertical;
        const spacing = if (layout.label_mode) spacing_full / 2 else spacing_full;
        var cursor: f32 = 0;
        var rank: u32 = 0;
        while (rank < layout.rank_count) : (rank += 1) {
            cursor += extra_start[rank];
            layout.rank_center[rank] = cursor + layout.rank_extent[rank] / 2;
            cursor += layout.rank_extent[rank] + extra_end[rank] + spacing;
        }
        node = 0;
        while (node < layout.count) : (node += 1) {
            layout.y[node] = layout.rank_center[layout.rank[node]];
        }
        assert(cursor > 0);
    }

    // Output.

    fn screen(layout: *const Layout, point: Point) Point {
        return switch (layout.graph.direction) {
            .top_bottom => point,
            .bottom_top => .{ .x = point.x, .y = -point.y },
            .left_right => .{ .x = point.y, .y = point.x },
            .right_left => .{ .x = -point.y, .y = point.x },
        };
    }

    fn screen_rect(layout: *const Layout, low: Point, high: Point) Rect {
        const a = layout.screen(low);
        const b = layout.screen(high);
        return .{
            .x = @min(a.x, b.x),
            .y = @min(a.y, b.y),
            .width = @abs(a.x - b.x),
            .height = @abs(a.y - b.y),
        };
    }

    fn output(layout: *Layout, allocator: Allocator) Error!void {
        const graph = layout.graph;
        for (graph.nodes[0..graph.node_count], 0..) |*node, index| {
            node.center = layout.screen(.{ .x = layout.x[index], .y = layout.y[index] });
            node.attachment_center = layout.screen(layout.attachment_point(@intCast(index)));
        }
        try layout.clusters_output(allocator);
        var loops: [nodes_max]u8 = @splat(0);
        var edge: u32 = 0;
        while (edge < graph.edge_count) : (edge += 1) {
            if (layout.edge_self(edge)) {
                const source = graph.edges[edge].source;
                try layout.loop_route(edge, loops[source]);
                loops[source] +|= 1;
            } else {
                try layout.edge_route(edge);
            }
        }
        layout.translate();
    }

    fn attachment_point(layout: *const Layout, node: u32) Point {
        const value = layout.graph.nodes[node];
        const cross = if (layout.horizontal) value.size.height else value.size.width;
        const cross_attachment =
            if (layout.horizontal) value.attachment.height else value.attachment.width;
        const distance = cross / 2 + attachment_gap + cross_attachment / 2;
        const sign: f32 = if (value.attachment_before) -1 else 1;
        assert(distance >= 0);
        assert(node < layout.graph.node_count);
        return .{ .x = layout.x[node] + sign * distance, .y = layout.y[node] };
    }

    fn clusters_output(layout: *Layout, allocator: Allocator) Error!void {
        const graph = layout.graph;
        const low = try alloc_fill(allocator, f32, layout.cluster_count, std.math.inf(f32));
        const high = try alloc_fill(allocator, f32, layout.cluster_count, -std.math.inf(f32));
        var node: u32 = 0;
        while (node < layout.count) : (node += 1) {
            const cluster = layout.cluster[node];
            if (cluster == none) continue;
            const rank = layout.rank[node];
            const half = layout.rank_extent[rank] / 2;
            low[cluster] = @min(low[cluster], layout.rank_center[rank] - half);
            high[cluster] = @max(high[cluster], layout.rank_center[rank] + half);
        }
        for (layout.cluster_by_depth[0..layout.cluster_count]) |cluster| {
            const pad = layout.cluster_pad(cluster);
            low[cluster] -= pad + layout.cluster_title_rank(cluster, true);
            high[cluster] += pad + layout.cluster_title_rank(cluster, false);
            const parent = layout.cluster_parent[cluster];
            if (parent != none) low[parent] = @min(low[parent], low[cluster]);
            if (parent != none) high[parent] = @max(high[parent], high[cluster]);
            if (cluster >= graph.cluster_count) continue;
            const corner_low: Point = .{
                .x = layout.x[layout.variable_left(cluster)],
                .y = low[cluster],
            };
            const corner_high: Point = .{
                .x = layout.x[layout.variable_right(cluster)],
                .y = high[cluster],
            };
            var rect = layout.screen_rect(corner_low, corner_high);
            const title = graph.clusters[cluster].title;
            if (rect.width < title.width + 2 * cluster_padding) {
                const width = title.width + 2 * cluster_padding;
                rect.x -= (width - rect.width) / 2;
                rect.width = width;
            }
            graph.clusters[cluster].rect = rect;
            graph.clusters[cluster].title_center = .{
                .x = rect.x + rect.width / 2,
                .y = rect.y + cluster_padding / 2 + title.height / 2 + 2,
            };
        }
    }

    fn point_add(layout: *Layout, point: Point) Error!void {
        const graph = layout.graph;
        assert(std.math.isFinite(point.x));
        assert(std.math.isFinite(point.y));
        if (graph.point_count == points_max) return error.Overflow;
        graph.points[graph.point_count] = point;
        graph.point_count += 1;
    }

    fn edge_route(layout: *Layout, edge: u32) Error!void {
        const graph = layout.graph;
        var waypoints: [2 * ranks_max + 2]Waypoint = undefined;
        const count = layout.waypoints_collect(edge, &waypoints);
        const start = graph.point_count;
        var anchor: u32 = 0;
        try layout.point_add(layout.screen(waypoints[0].point));
        var steps: u32 = 0;
        while (anchor + 1 < count) : (steps += 1) {
            assert(steps < count);
            var reach = anchor + 1;
            var candidate = count - 1;
            while (candidate > anchor + 1) : (candidate -= 1) {
                if (layout.shortcut_clear(waypoints[0..count], anchor, candidate)) {
                    reach = candidate;
                    break;
                }
            }
            try layout.point_add(layout.screen(waypoints[reach].point));
            anchor = reach;
        }
        const points = graph.points[start..graph.point_count];
        if (layout.reversed[edge]) std.mem.reverse(Point, points);
        assert(points.len >= 2);
        const source = graph.nodes[graph.edges[edge].source];
        const target = graph.nodes[graph.edges[edge].target];
        points[0] = border_point(source, points[1]);
        points[points.len - 1] = border_point(target, points[points.len - 2]);
        graph.edges[edge].points = .{ .start = start, .count = @intCast(points.len) };
        if (graph.edges[edge].label.width > 0) assert(layout.label_mode);
    }

    /// Layout-space route through the chain: node centers, virtual nodes, and both ends of
    /// every label, which the route must pass through.
    fn waypoints_collect(layout: *Layout, edge: u32, waypoints: []Waypoint) u32 {
        const graph = layout.graph;
        var count: u32 = 0;
        waypoints[count] = .{ .point = layout.layout_point(layout.dag_source(edge)), .node = none };
        count += 1;
        const chain = layout.chains[layout.chain_start[edge]..][0..layout.chain_count[edge]];
        for (chain) |node| {
            const center = layout.layout_point(node);
            if (layout.kind[node] != .label) {
                waypoints[count] = .{ .point = center, .node = node };
                count += 1;
                continue;
            }
            const half = layout.extent_rank[node] / 2;
            const top: Point = .{ .x = center.x, .y = center.y - half };
            const bottom: Point = .{ .x = center.x, .y = center.y + half };
            waypoints[count] = .{ .point = top, .node = none };
            waypoints[count + 1] = .{ .point = bottom, .node = none };
            count += 2;
            const label_cross = layout.extent_right[node] - label_clearance;
            graph.edges[edge].label_center = layout.screen(.{
                .x = center.x + label_clearance + label_cross / 2,
                .y = center.y,
            });
        }
        waypoints[count] = .{ .point = layout.layout_point(layout.dag_target(edge)), .node = none };
        count += 1;
        assert(count >= 2);
        assert(count <= waypoints.len);
        return count;
    }

    /// Whether the straight segment between two waypoints can replace the waypoints between
    /// them: it must cross every skipped rank inside the room that the separation constraints
    /// give the skipped virtual node.
    fn shortcut_clear(layout: *const Layout, waypoints: []const Waypoint, from: u32, to: u32) bool {
        assert(from + 1 < to);
        const a = waypoints[from].point;
        const b = waypoints[to].point;
        assert(b.y > a.y);
        for (waypoints[from + 1 .. to]) |waypoint| {
            if (waypoint.node == none) return false;
            const node = waypoint.node;
            var low = -std.math.inf(f32);
            var high = std.math.inf(f32);
            for (layout.constraint_pred.slice(node)) |index| {
                const constraint = layout.constraints[index];
                low = @max(low, layout.x[constraint.from] + constraint.distance);
            }
            for (layout.constraint_succ.slice(node)) |index| {
                const constraint = layout.constraints[index];
                high = @min(high, layout.x[constraint.to] - constraint.distance);
            }
            const rank = layout.rank[node];
            const half = layout.rank_extent[rank] / 2;
            for ([_]f32{ layout.rank_center[rank] - half, layout.rank_center[rank] + half }) |y| {
                const x = a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y);
                if (x < low or x > high) return false;
            }
        }
        return true;
    }

    fn layout_point(layout: *const Layout, node: u32) Point {
        return .{ .x = layout.x[node], .y = layout.y[node] };
    }

    /// A loop that leaves and re-enters the node on its cross-axis end side.
    fn loop_route(layout: *Layout, edge: u32, index: u8) Error!void {
        const graph = layout.graph;
        const source = graph.edges[edge].source;
        const node = graph.nodes[source];
        const center = layout.layout_point(source);
        const half_cross = (if (layout.horizontal) node.size.height else node.size.width) / 2;
        const half_rank = (if (layout.horizontal) node.size.width else node.size.height) / 2;
        const extent = loop_extent + loop_step * @as(f32, @floatFromInt(index));
        const offset = @min(half_rank * 0.5, 10);
        const border = center.x + half_cross;
        const shape: [5]Point = .{
            .{ .x = center.x, .y = center.y - offset },
            .{ .x = border + extent * 0.7, .y = center.y - offset - 8 },
            .{ .x = border + extent, .y = center.y },
            .{ .x = border + extent * 0.7, .y = center.y + offset + 8 },
            .{ .x = center.x, .y = center.y + offset },
        };
        const start = graph.point_count;
        for (shape) |point| try layout.point_add(layout.screen(point));
        const points = graph.points[start..graph.point_count];
        points[0] = border_point_from(node, points[0], points[1]);
        points[4] = border_point_from(node, points[4], points[3]);
        graph.edges[edge].points = .{ .start = start, .count = 5 };
        const label = graph.edges[edge].label;
        const label_cross = if (layout.horizontal) label.height else label.width;
        graph.edges[edge].label_center = layout.screen(.{
            .x = border + extent + label_clearance + label_cross / 2,
            .y = center.y,
        });
    }

    /// Moves everything so that the bounding box starts at the margin, and sets the size.
    fn translate(layout: *Layout) void {
        const graph = layout.graph;
        var box = Bounds.empty;
        for (graph.nodes[0..graph.node_count]) |node| {
            box.add_rect(node_rect(node));
            if (node.attachment.width > 0) {
                box.add_rect(rect_centered(node.attachment_center, node.attachment));
            }
        }
        for (graph.clusters[0..graph.cluster_count]) |cluster| box.add_rect(cluster.rect);
        for (graph.points[0..graph.point_count]) |point| box.add_point(point);
        for (graph.edges[0..graph.edge_count]) |edge| {
            if (edge.label.width == 0) continue;
            box.add_rect(rect_centered(edge.label_center, edge.label));
        }
        assert(box.low.x <= box.high.x);
        const dx = margin - box.low.x;
        const dy = margin - box.low.y;
        for (graph.nodes[0..graph.node_count]) |*node| {
            node.center = shift(node.center, dx, dy);
            node.attachment_center = shift(node.attachment_center, dx, dy);
        }
        for (graph.points[0..graph.point_count]) |*point| point.* = shift(point.*, dx, dy);
        for (graph.edges[0..graph.edge_count]) |*edge| {
            edge.label_center = shift(edge.label_center, dx, dy);
        }
        for (graph.clusters[0..graph.cluster_count]) |*cluster| {
            cluster.rect.x += dx;
            cluster.rect.y += dy;
            cluster.title_center = shift(cluster.title_center, dx, dy);
        }
        graph.size = .{
            .width = box.high.x - box.low.x + 2 * margin,
            .height = box.high.y - box.low.y + 2 * margin,
        };
        assert(graph.size.width > 0);
    }
};

/// Projects desired positions onto the separation constraints with the block-merging method of
/// Dwyer, Marriott, and Stuckey ("satisfy"): variables in topological order merge with the
/// blocks they violate, and each block sits at the weighted mean of its members' wishes.
const Solver = struct {
    block: []u32,
    offset: []f32,
    next: []u32,
    head: []u32,
    tail: []u32,
    size: []u32,
    weight_sum: []f32,
    weighted: []f32,
    position: []f32,

    fn init(allocator: Allocator, variables: u32) Error!Solver {
        assert(variables > 0);
        return .{
            .block = try alloc(allocator, u32, variables),
            .offset = try alloc(allocator, f32, variables),
            .next = try alloc(allocator, u32, variables),
            .head = try alloc(allocator, u32, variables),
            .tail = try alloc(allocator, u32, variables),
            .size = try alloc(allocator, u32, variables),
            .weight_sum = try alloc(allocator, f32, variables),
            .weighted = try alloc(allocator, f32, variables),
            .position = try alloc(allocator, f32, variables),
        };
    }

    fn project(solver: *Solver, layout: *const Layout, x: []f32) void {
        const variables: u32 = @intCast(x.len);
        for (x, 0..) |desired, index| {
            // Cluster borders have no wishes of their own: a tiny weight keeps blocks defined.
            const weight: f32 = if (index < layout.count) 1 else 0.001;
            solver.block[index] = @intCast(index);
            solver.offset[index] = 0;
            solver.next[index] = none;
            solver.head[index] = @intCast(index);
            solver.tail[index] = @intCast(index);
            solver.size[index] = 1;
            solver.weight_sum[index] = weight;
            solver.weighted[index] = weight * desired;
            solver.position[index] = desired;
        }
        for (layout.constraint_order[0..variables]) |variable| {
            solver.merge_left(layout, solver.block[variable], variables);
        }
        for (x, 0..) |*value, index| value.* = solver.variable_position(@intCast(index));
        // Merging can leave a constraint between earlier blocks slightly violated; one
        // rightward pass restores feasibility exactly.
        layout.push_right(x);
    }

    fn variable_position(solver: *const Solver, variable: u32) f32 {
        return solver.position[solver.block[variable]] + solver.offset[variable];
    }

    fn merge_left(solver: *Solver, layout: *const Layout, block_start: u32, variables: u32) void {
        var block = block_start;
        var merges: u32 = 0;
        while (merges < variables) : (merges += 1) {
            var worst: u32 = none;
            var violation_max: f32 = 0.001;
            var variable = solver.head[block];
            var steps: u32 = 0;
            while (variable != none) : (variable = solver.next[variable]) {
                assert(steps < variables);
                steps += 1;
                for (layout.constraint_pred.slice(variable)) |index| {
                    const constraint = layout.constraints[index];
                    if (solver.block[constraint.from] == block) continue;
                    const violation = solver.variable_position(constraint.from) +
                        constraint.distance - solver.variable_position(variable);
                    if (violation > violation_max) {
                        violation_max = violation;
                        worst = index;
                    }
                }
            }
            if (worst == none) return;
            block = solver.merge(layout.constraints[worst]);
        }
    }

    /// Merges the blocks on both sides of a violated constraint, making it tight, and returns
    /// the merged block.
    fn merge(solver: *Solver, constraint: Constraint) u32 {
        const left = solver.block[constraint.from];
        const right = solver.block[constraint.to];
        assert(left != right);
        // Offsets of the absorbed block shift so that `to - from == distance` holds.
        const shift_left = solver.offset[constraint.to] - constraint.distance -
            solver.offset[constraint.from];
        const into = if (solver.size[left] > solver.size[right]) left else right;
        const from = if (into == left) right else left;
        const offset_change = if (into == right) shift_left else -shift_left;
        var variable = solver.head[from];
        var steps: u32 = 0;
        while (variable != none) : (variable = solver.next[variable]) {
            assert(steps < solver.block.len);
            steps += 1;
            solver.block[variable] = into;
            solver.offset[variable] += offset_change;
        }
        solver.next[solver.tail[into]] = solver.head[from];
        solver.tail[into] = solver.tail[from];
        solver.size[into] += solver.size[from];
        solver.weighted[into] += solver.weighted[from] - offset_change * solver.weight_sum[from];
        solver.weight_sum[into] += solver.weight_sum[from];
        solver.position[into] = solver.weighted[into] / solver.weight_sum[into];
        return into;
    }
};

fn fenwick_add(tree: []u32, index: u32) void {
    assert(index > 0);
    var cursor: usize = index;
    while (cursor < tree.len) : (cursor += cursor & (~cursor + 1)) tree[cursor] += 1;
}

fn fenwick_prefix(tree: []const u32, index: u32) u64 {
    assert(index < tree.len);
    var sum: u64 = 0;
    var cursor: usize = index;
    while (cursor > 0) : (cursor -= cursor & (~cursor + 1)) sum += tree[cursor];
    return sum;
}

fn cluster_top(graph: *const Graph, cluster: u32) u32 {
    var current = cluster;
    var depth: u32 = 0;
    while (current != none and graph.clusters[current].parent != none) : (depth += 1) {
        assert(depth < cluster_depth_max);
        current = graph.clusters[current].parent;
    }
    return current;
}

/// Finds connected components over edges and cluster membership. Returns the component count.
fn components_find(graph: *const Graph, allocator: Allocator, component: []u32) Error!u32 {
    const parent = try alloc(allocator, u32, graph.node_count);
    for (parent, 0..) |*value, index| value.* = @intCast(index);
    for (graph.edges[0..graph.edge_count]) |edge| union_join(parent, edge.source, edge.target);
    var first: [clusters_max]u32 = @splat(none);
    for (graph.nodes[0..graph.node_count], 0..) |node, index| {
        const top = cluster_top(graph, node.cluster);
        if (top == none) continue;
        if (first[top] == none) first[top] = @intCast(index);
        union_join(parent, first[top], @intCast(index));
    }
    const numbering = try alloc_fill(allocator, u32, graph.node_count, none);
    var count: u32 = 0;
    for (component, 0..) |*value, index| {
        const root = union_find(parent, @intCast(index));
        if (numbering[root] == none) {
            numbering[root] = count;
            count += 1;
        }
        value.* = numbering[root];
    }
    assert(count <= graph.node_count);
    return count;
}

fn union_find(parent: []u32, node: u32) u32 {
    var current = node;
    var steps: u32 = 0;
    while (parent[current] != current) : (steps += 1) {
        assert(steps < parent.len);
        parent[current] = parent[parent[current]];
        current = parent[current];
    }
    return current;
}

fn union_join(parent: []u32, a: u32, b: u32) void {
    const root_a = union_find(parent, a);
    const root_b = union_find(parent, b);
    if (root_a < root_b) parent[root_b] = root_a else parent[root_a] = root_b;
}

const Bounds = struct {
    low: Point,
    high: Point,

    const empty: Bounds = .{
        .low = .{ .x = std.math.inf(f32), .y = std.math.inf(f32) },
        .high = .{ .x = -std.math.inf(f32), .y = -std.math.inf(f32) },
    };

    fn add_point(bounds: *Bounds, point: Point) void {
        bounds.low = .{ .x = @min(bounds.low.x, point.x), .y = @min(bounds.low.y, point.y) };
        bounds.high = .{ .x = @max(bounds.high.x, point.x), .y = @max(bounds.high.y, point.y) };
    }

    fn add_rect(bounds: *Bounds, rect: Rect) void {
        bounds.add_point(.{ .x = rect.x, .y = rect.y });
        bounds.add_point(.{ .x = rect.x + rect.width, .y = rect.y + rect.height });
    }
};

fn shift(point: Point, dx: f32, dy: f32) Point {
    return .{ .x = point.x + dx, .y = point.y + dy };
}

pub fn rect_centered(center: Point, size: Size) Rect {
    assert(size.width >= 0);
    assert(size.height >= 0);
    return .{
        .x = center.x - size.width / 2,
        .y = center.y - size.height / 2,
        .width = size.width,
        .height = size.height,
    };
}

pub fn node_rect(node: Node) Rect {
    return rect_centered(node.center, node.size);
}

/// The point where the ray from the node center toward `toward` leaves the node outline.
pub fn border_point(node: Node, toward: Point) Point {
    return border_point_from(node, node.center, toward);
}

/// Like `border_point`, for a ray that starts at `origin` inside the node.
fn border_point_from(node: Node, origin: Point, toward: Point) Point {
    const dx = toward.x - origin.x;
    const dy = toward.y - origin.y;
    const half_width = @max(node.size.width / 2, 0.5);
    const half_height = @max(node.size.height / 2, 0.5);
    if (@abs(dx) < 0.001 and @abs(dy) < 0.001) return origin;
    // Rays from an off-center origin are clipped against the outline seen from the center,
    // which is exact for boxes and close enough for the loop ends of other shapes.
    const ox = origin.x - node.center.x;
    const oy = origin.y - node.center.y;
    var low: f32 = 0;
    var high: f32 = 1;
    if (!clip_inside(node.shape.clip(), ox + dx, oy + dy, half_width, half_height)) {
        // Bisection keeps this exact for every outline without per-shape algebra.
        var step: u32 = 0;
        while (step < 24) : (step += 1) {
            const middle = (low + high) / 2;
            const inside = clip_inside(
                node.shape.clip(),
                ox + dx * middle,
                oy + dy * middle,
                half_width,
                half_height,
            );
            if (inside) low = middle else high = middle;
        }
        return .{ .x = origin.x + dx * high, .y = origin.y + dy * high };
    }
    return toward;
}

fn clip_inside(clip: Clip, x: f32, y: f32, half_width: f32, half_height: f32) bool {
    assert(half_width > 0);
    assert(half_height > 0);
    const u = @abs(x) / half_width;
    const v = @abs(y) / half_height;
    return switch (clip) {
        .box => u <= 1 and v <= 1,
        .ellipse => u * u + v * v <= 1,
        .diamond => u + v <= 1,
        .hexagon => v <= 1 and @abs(x) <= half_width - hexagon_inset(half_height * 2) * v,
    };
}

pub fn hexagon_inset(height: f32) f32 {
    return height / 4;
}

// Labels.

/// A label of one or more lines. Lines come from `<br>` tags and point into the source text.
pub const Label = struct {
    lines: [label_lines_max][]const u8 = undefined,
    line_count: u32 = 0,
    size: Size = .{ .width = 0, .height = 0 },
    font: scene.Font = .regular,

    pub fn init(text: []const u8, measurer: scene.Measurer, font: scene.Font) Error!Label {
        var label: Label = .{ .font = font };
        var rest = text;
        var steps: u32 = 0;
        while (steps <= label_lines_max) : (steps += 1) {
            const split = line_break_find(rest);
            const line = std.mem.trim(u8, rest[0..split.start], " \t");
            if (label.line_count == label_lines_max) return error.Overflow;
            label.lines[label.line_count] = line;
            label.line_count += 1;
            const size = measurer.measure(line, font);
            label.size.width = @max(label.size.width, size.width);
            label.size.height += size.height;
            if (split.end == rest.len and split.start == rest.len) break;
            rest = rest[split.end..];
        }
        assert(label.line_count >= 1);
        assert(label.size.height > 0);
        return label;
    }

    pub fn empty(label: *const Label) bool {
        return label.line_count == 1 and label.lines[0].len == 0;
    }

    /// Emits one text command per line, centered on `center` as a block.
    pub fn draw(
        label: *const Label,
        out: *scene.Scene,
        measurer: scene.Measurer,
        center: Point,
        color: scene.Color,
    ) Error!void {
        assert(label.line_count >= 1);
        assert(label.line_count <= label_lines_max);
        var y = center.y - label.size.height / 2;
        for (label.lines[0..label.line_count]) |line| {
            const height = measurer.measure(line, label.font).height;
            if (line.len > 0) try out.command_add(.{ .text = .{
                .origin = .{ .x = center.x, .y = y + height / 2 },
                .font = label.font,
                .color = color,
                .bytes = line,
            } });
            y += height;
        }
    }
};

const Split = struct { start: usize, end: usize };

/// Finds the first `<br>`, `<br/>`, or `<br />` tag (any case), or a literal `\n` escape.
fn line_break_find(text: []const u8) Split {
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] == '\\' and index + 1 < text.len and text[index + 1] == 'n') {
            return .{ .start = index, .end = index + 2 };
        }
        if (text[index] != '<' or index + 3 > text.len) continue;
        if (std.ascii.toLower(text[index + 1]) != 'b') continue;
        if (std.ascii.toLower(text[index + 2]) != 'r') continue;
        var cursor = index + 3;
        while (cursor < text.len and text[cursor] == ' ') cursor += 1;
        if (cursor < text.len and text[cursor] == '/') cursor += 1;
        if (cursor < text.len and text[cursor] == '>') {
            return .{ .start = index, .end = cursor + 1 };
        }
    }
    return .{ .start = text.len, .end = text.len };
}

/// Removes one pair of surrounding double quotes, if present.
pub fn unquote(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

// Statements.

/// Splits source into trimmed statements: lines, further split at `;` outside of quotes.
/// Skips blank lines and `%%` comments. The first statement is the diagram header.
pub const Statements = struct {
    source: []const u8,
    index: usize = 0,

    pub fn next(statements: *Statements) ?[]const u8 {
        var steps: u32 = 0;
        while (statements.index < statements.source.len) : (steps += 1) {
            assert(steps <= statements.source.len);
            const rest = statements.source[statements.index..];
            var end: usize = 0;
            var quoted = false;
            while (end < rest.len and rest[end] != '\n') : (end += 1) {
                if (rest[end] == '"') quoted = !quoted;
                if (rest[end] == ';' and !quoted) break;
            }
            statements.index += @min(end + 1, rest.len);
            const statement = std.mem.trim(u8, rest[0..end], " \t\r");
            if (statement.len == 0) continue;
            if (std.mem.startsWith(u8, statement, "%%")) continue;
            return statement;
        }
        return null;
    }
};

pub fn word_is(text: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, text, word)) return false;
    return text.len == word.len or text[word.len] == ' ' or text[word.len] == '\t';
}

pub fn identifier_char(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte >= 0x80;
}

// Drawing.

/// Draws a node outline with its standard colors.
pub fn shape_draw(out: *scene.Scene, shape: Shape, rect: Rect) Error!void {
    assert(rect.width >= 0);
    assert(rect.height >= 0);
    const fill: scene.Color = .node_fill;
    const stroke: scene.Color = .node_stroke;
    switch (shape) {
        .rect => try out.command_add(.{ .rect = .{
            .rect = rect,
            .radius = 3,
            .fill = fill,
            .stroke = stroke,
        } }),
        .rect_round => try out.command_add(.{ .rect = .{
            .rect = rect,
            .radius = @min(10, rect.height / 3),
            .fill = fill,
            .stroke = stroke,
        } }),
        .stadium => try out.command_add(.{ .rect = .{
            .rect = rect,
            .radius = rect.height / 2,
            .fill = fill,
            .stroke = stroke,
        } }),
        .subroutine => try subroutine_draw(out, rect),
        .cylinder => try cylinder_draw(out, rect),
        .circle => try out.command_add(.{ .ellipse = .{
            .rect = rect,
            .fill = fill,
            .stroke = stroke,
        } }),
        .circle_double => {
            try out.command_add(.{ .ellipse = .{ .rect = rect, .fill = fill, .stroke = stroke } });
            try out.command_add(.{ .ellipse = .{ .rect = rect_inset(rect, 4), .stroke = stroke } });
        },
        .start => try out.command_add(.{ .ellipse = .{ .rect = rect, .fill = .text } }),
        .end => {
            try out.command_add(.{ .ellipse = .{
                .rect = rect,
                .stroke = .text,
                .stroke_width = 1.5,
            } });
            try out.command_add(.{ .ellipse = .{ .rect = rect_inset(rect, 4), .fill = .text } });
        },
        .bar => try out.command_add(.{ .rect = .{ .rect = rect, .radius = 2, .fill = .text } }),
        .hidden => {},
        else => try polygon_draw(out, shape, rect),
    }
}

fn rect_inset(rect: Rect, inset: f32) Rect {
    const amount = @min(inset, @min(rect.width, rect.height) / 4);
    return .{
        .x = rect.x + amount,
        .y = rect.y + amount,
        .width = rect.width - 2 * amount,
        .height = rect.height - 2 * amount,
    };
}

fn subroutine_draw(out: *scene.Scene, rect: Rect) Error!void {
    const fill: scene.Color = .node_fill;
    const stroke: scene.Color = .node_stroke;
    try out.command_add(.{ .rect = .{ .rect = rect, .fill = fill, .stroke = stroke } });
    const inset: f32 = 8;
    for ([_]f32{ rect.x + inset, rect.x + rect.width - inset }) |x| {
        const range = try out.points_add(&.{
            .{ .x = x, .y = rect.y },
            .{ .x = x, .y = rect.y + rect.height },
        });
        try out.command_add(.{ .line = .{ .points = range, .stroke = stroke } });
    }
}

pub fn cylinder_cap(rect: Rect) f32 {
    return @min(rect.width / 5, 10);
}

fn cylinder_draw(out: *scene.Scene, rect: Rect) Error!void {
    const fill: scene.Color = .node_fill;
    const stroke: scene.Color = .node_stroke;
    const cap = cylinder_cap(rect);
    const bottom: Rect = .{
        .x = rect.x,
        .y = rect.y + rect.height - 2 * cap,
        .width = rect.width,
        .height = 2 * cap,
    };
    const top: Rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = 2 * cap };
    try out.command_add(.{ .ellipse = .{ .rect = bottom, .fill = fill, .stroke = stroke } });
    try out.command_add(.{ .rect = .{
        .rect = .{
            .x = rect.x,
            .y = rect.y + cap,
            .width = rect.width,
            .height = rect.height - 2 * cap,
        },
        .fill = fill,
    } });
    for ([_]f32{ rect.x, rect.x + rect.width }) |x| {
        const range = try out.points_add(&.{
            .{ .x = x, .y = rect.y + cap },
            .{ .x = x, .y = rect.y + rect.height - cap },
        });
        try out.command_add(.{ .line = .{ .points = range, .stroke = stroke } });
    }
    try out.command_add(.{ .ellipse = .{ .rect = top, .fill = fill, .stroke = stroke } });
}

pub fn slant(rect: Rect) f32 {
    return @min(rect.height / 2, rect.width / 4);
}

fn polygon_draw(out: *scene.Scene, shape: Shape, rect: Rect) Error!void {
    const left = rect.x;
    const right = rect.x + rect.width;
    const top = rect.y;
    const bottom = rect.y + rect.height;
    const middle = rect.y + rect.height / 2;
    const s = slant(rect);
    const inset = hexagon_inset(rect.height);
    var points: [6]Point = undefined;
    const count: usize = switch (shape) {
        .diamond => blk: {
            const center = rect.x + rect.width / 2;
            points[0..4].* = .{
                .{ .x = center, .y = top },
                .{ .x = right, .y = middle },
                .{ .x = center, .y = bottom },
                .{ .x = left, .y = middle },
            };
            break :blk 4;
        },
        .hexagon => blk: {
            points = .{
                .{ .x = left + inset, .y = top },
                .{ .x = right - inset, .y = top },
                .{ .x = right, .y = middle },
                .{ .x = right - inset, .y = bottom },
                .{ .x = left + inset, .y = bottom },
                .{ .x = left, .y = middle },
            };
            break :blk 6;
        },
        .parallelogram => quad(&points, left + s, right, right - s, left, top, bottom),
        .parallelogram_alt => quad(&points, left, right - s, right, left + s, top, bottom),
        .trapezoid => quad(&points, left + s, right - s, right, left, top, bottom),
        .trapezoid_alt => quad(&points, left, right, right - s, left + s, top, bottom),
        .flag => blk: {
            points[0..5].* = .{
                .{ .x = left, .y = top },
                .{ .x = right, .y = top },
                .{ .x = right, .y = bottom },
                .{ .x = left, .y = bottom },
                .{ .x = left + rect.height / 4, .y = middle },
            };
            break :blk 5;
        },
        else => unreachable,
    };
    const range = try out.points_add(points[0..count]);
    try out.command_add(.{ .polygon = .{
        .points = range,
        .fill = .node_fill,
        .stroke = .node_stroke,
    } });
}

fn quad(
    points: *[6]Point,
    top_left: f32,
    top_right: f32,
    bottom_right: f32,
    bottom_left: f32,
    top: f32,
    bottom: f32,
) usize {
    assert(top <= bottom);
    points[0..4].* = .{
        .{ .x = top_left, .y = top },
        .{ .x = top_right, .y = top },
        .{ .x = bottom_right, .y = bottom },
        .{ .x = bottom_left, .y = bottom },
    };
    assert(points[0].y == points[1].y);
    return 4;
}

/// Shortens a route whose end attaches to a subgraph, so that it stops at the subgraph box.
pub fn route_clip_to_cluster(graph: *Graph, edge: u32, cluster: u32, at_end: bool) void {
    const rect = graph.clusters[cluster].rect;
    var range = graph.edges[edge].points;
    const points = graph.points[range.start..][0..range.count];
    assert(points.len >= 2);
    var inside: u32 = 0;
    while (inside + 1 < points.len) : (inside += 1) {
        const index = if (at_end) points.len - 1 - inside else inside;
        if (!rect_contains(rect, points[index])) break;
    }
    if (inside == 0 or inside + 1 >= points.len) return;
    const from_index = if (at_end) points.len - inside else inside - 1;
    const to_index = if (at_end) points.len - 1 - inside else inside;
    var low = points[to_index];
    var high = points[from_index];
    var step: u32 = 0;
    while (step < 24) : (step += 1) {
        const middle: Point = .{ .x = (low.x + high.x) / 2, .y = (low.y + high.y) / 2 };
        if (rect_contains(rect, middle)) high = middle else low = middle;
    }
    points[from_index] = low;
    if (at_end) {
        range.count = @intCast(from_index + 1);
    } else {
        range.start += @intCast(from_index);
        range.count -= @intCast(from_index);
    }
    assert(range.count >= 2);
    graph.edges[edge].points = range;
}

pub fn rect_contains(rect: Rect, point: Point) bool {
    return point.x > rect.x and point.x < rect.x + rect.width and
        point.y > rect.y and point.y < rect.y + rect.height;
}

pub const EdgeStyle = struct {
    dash: scene.Dash = .solid,
    stroke_width: f32 = 1.25,
    head_start: scene.Head = .none,
    head_end: scene.Head = .none,
};

/// Emits the route of an edge as one line command.
pub fn edge_draw(out: *scene.Scene, graph: *const Graph, edge: u32, style: EdgeStyle) Error!void {
    const points = graph.edge_points(edge);
    assert(points.len >= 2);
    const range = try out.points_add(points);
    try out.command_add(.{ .line = .{
        .points = range,
        .stroke = .line,
        .stroke_width = style.stroke_width,
        .dash = style.dash,
        .smooth = points.len > 2,
        .head_start = style.head_start,
        .head_end = style.head_end,
    } });
}

/// Draws every cluster box and its title. Parents come before children, so outer boxes are
/// drawn first and inner boxes stay visible.
pub fn clusters_draw(
    out: *scene.Scene,
    graph: *const Graph,
    measurer: scene.Measurer,
    titles: []const Label,
) Error!void {
    assert(titles.len >= graph.cluster_count);
    for (graph.clusters[0..graph.cluster_count], 0..) |cluster, index| {
        assert(cluster.parent == none or cluster.parent < index);
        try out.command_add(.{ .rect = .{
            .rect = cluster.rect,
            .radius = 8,
            .fill = .group_fill,
            .stroke = .group_stroke,
        } });
        try titles[index].draw(out, measurer, cluster.title_center, .text_muted);
    }
}

// Tests.

pub const testing = struct {
    /// Checks the scene invariants that every diagram shares: positive size, and every
    /// command inside it.
    pub fn scene_check(out: *const scene.Scene) !void {
        try std.testing.expect(out.size.width > 0);
        try std.testing.expect(out.size.height > 0);
        const slack: f32 = 0.5;
        for (out.commands_slice()) |command| {
            var box = Bounds.empty;
            switch (command) {
                .rect => |c| box.add_rect(c.rect),
                .ellipse => |c| box.add_rect(c.rect),
                .polygon => |c| for (out.points_slice(c.points)) |p| box.add_point(p),
                .line => |c| for (out.points_slice(c.points)) |p| box.add_point(p),
                .wedge => |c| box.add_point(c.center),
                .text => |c| box.add_point(c.origin),
            }
            try std.testing.expect(box.low.x >= -slack);
            try std.testing.expect(box.low.y >= -slack);
            try std.testing.expect(box.high.x <= out.size.width + slack);
            try std.testing.expect(box.high.y <= out.size.height + slack);
        }
    }

    /// Checks that no two visible nodes overlap.
    pub fn nodes_disjoint(graph: *const Graph) !void {
        const nodes = graph.nodes[0..graph.node_count];
        for (nodes, 0..) |a, index| {
            for (nodes[index + 1 ..]) |b| {
                const ra = node_rect(a);
                const rb = node_rect(b);
                const apart = ra.x + ra.width <= rb.x + 0.5 or rb.x + rb.width <= ra.x + 0.5 or
                    ra.y + ra.height <= rb.y + 0.5 or rb.y + rb.height <= ra.y + 0.5;
                try std.testing.expect(apart);
            }
        }
    }

    /// Runs `render` on every prefix of `source`; it must return, with or without an error.
    pub fn prefixes_render(source: []const u8, render: anytype) !void {
        const scratch = try std.testing.allocator.alloc(u8, 8 << 20);
        defer std.testing.allocator.free(scratch);
        var commands: [4096]scene.Command = undefined;
        var points: [16384]Point = undefined;
        var text: [4096]u8 = undefined;
        var length: usize = 0;
        while (length <= source.len) : (length += 1) {
            var out = scene.Scene.init(&commands, &points, &text);
            render(source[0..length], scene.Measurer.fixed, scratch, &out) catch continue;
            try scene_check(&out);
        }
    }

    /// Renders and prints the SVG to stderr, for visual inspection during development.
    pub fn svg_dump(source: []const u8, render: anytype) !void {
        const scratch = try std.testing.allocator.alloc(u8, 8 << 20);
        defer std.testing.allocator.free(scratch);
        const buffer = try std.testing.allocator.alloc(u8, 1 << 20);
        defer std.testing.allocator.free(buffer);
        var commands: [4096]scene.Command = undefined;
        var points: [16384]Point = undefined;
        var text: [4096]u8 = undefined;
        var out = scene.Scene.init(&commands, &points, &text);
        try render(source, scene.Measurer.fixed, scratch, &out);
        const svg = try @import("../scene_svg.zig").write(&out, buffer);
        std.debug.print("{s}", .{svg});
    }
};

fn test_graph(allocator: Allocator, direction: Direction) !Graph {
    return Graph.init(allocator, direction);
}

test "graph: chain is layered top to bottom" {
    const scratch = try std.testing.allocator.alloc(u8, 4 << 20);
    defer std.testing.allocator.free(scratch);
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const allocator = fixed.allocator();
    var graph = try test_graph(allocator, .top_bottom);
    const size: Size = .{ .width = 60, .height = 30 };
    const a = try graph.node_add(size, .rect, none);
    const b = try graph.node_add(size, .rect, none);
    const c = try graph.node_add(size, .rect, none);
    _ = try graph.edge_add(a, b, .{ .width = 0, .height = 0 }, 1);
    _ = try graph.edge_add(b, c, .{ .width = 0, .height = 0 }, 1);
    _ = try graph.edge_add(c, a, .{ .width = 0, .height = 0 }, 1);
    try graph.layout(allocator);
    try std.testing.expect(graph.nodes[a].center.y < graph.nodes[b].center.y);
    try std.testing.expect(graph.nodes[b].center.y < graph.nodes[c].center.y);
    try testing.nodes_disjoint(&graph);
    // Edges end on the node borders.
    const points = graph.edge_points(0);
    try std.testing.expectApproxEqAbs(graph.nodes[a].center.y + 15, points[0].y, 0.1);
    try std.testing.expectApproxEqAbs(graph.nodes[b].center.y - 15, points[points.len - 1].y, 0.1);
}

test "graph: clusters contain exactly their members" {
    const scratch = try std.testing.allocator.alloc(u8, 4 << 20);
    defer std.testing.allocator.free(scratch);
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const allocator = fixed.allocator();
    var graph = try test_graph(allocator, .left_right);
    const size: Size = .{ .width = 50, .height = 30 };
    const outer = try graph.cluster_add(none, .{ .width = 40, .height = 16 });
    const inner = try graph.cluster_add(outer, .{ .width = 40, .height = 16 });
    const nodes = [_]u32{
        try graph.node_add(size, .rect, none),
        try graph.node_add(size, .rect, outer),
        try graph.node_add(size, .rect, inner),
        try graph.node_add(size, .rect, inner),
        try graph.node_add(size, .rect, none),
        try graph.node_add(size, .rect, none),
    };
    const pairs = [_][2]u32{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 0, 4 }, .{ 4, 5 }, .{ 3, 5 } };
    const zero: Size = .{ .width = 0, .height = 0 };
    for (pairs) |pair| _ = try graph.edge_add(nodes[pair[0]], nodes[pair[1]], zero, 1);
    try graph.layout(allocator);
    try testing.nodes_disjoint(&graph);
    for (graph.nodes[0..graph.node_count]) |node| {
        for (graph.clusters[0..graph.cluster_count], 0..) |cluster, index| {
            const r = node_rect(node);
            const c = cluster.rect;
            const inside = r.x >= c.x and r.y >= c.y and r.x + r.width <= c.x + c.width and
                r.y + r.height <= c.y + c.height;
            const disjoint = r.x >= c.x + c.width or r.x + r.width <= c.x or
                r.y >= c.y + c.height or r.y + r.height <= c.y;
            const member = graph.cluster_within(node.cluster, @intCast(index));
            try std.testing.expect(if (member) inside else disjoint);
        }
    }
}

test "graph: components side by side, self-loop and label" {
    const scratch = try std.testing.allocator.alloc(u8, 4 << 20);
    defer std.testing.allocator.free(scratch);
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const allocator = fixed.allocator();
    var graph = try test_graph(allocator, .top_bottom);
    const size: Size = .{ .width = 40, .height = 20 };
    const a = try graph.node_add(size, .circle, none);
    const b = try graph.node_add(size, .diamond, none);
    const c = try graph.node_add(size, .rect, none);
    _ = try graph.edge_add(a, b, .{ .width = 30, .height = 16 }, 1);
    _ = try graph.edge_add(c, c, .{ .width = 30, .height = 16 }, 1);
    try graph.layout(allocator);
    try testing.nodes_disjoint(&graph);
    try std.testing.expect(graph.nodes[c].center.y < graph.nodes[b].center.y);
    try std.testing.expectEqual(@as(u32, 5), graph.edges[1].points.count);
}

test "graph: label line breaks and statements" {
    const label = try Label.init("one<br>two<BR/>three<br />four", scene.Measurer.fixed, .regular);
    try std.testing.expectEqual(@as(u32, 4), label.line_count);
    try std.testing.expectEqualStrings("three", label.lines[2]);
    try std.testing.expectEqual(@as(f32, 64), label.size.height);
    var statements: Statements = .{ .source = "a;b\r\n%% c\n\n \"x;y\" ; z" };
    try std.testing.expectEqualStrings("a", statements.next().?);
    try std.testing.expectEqualStrings("b", statements.next().?);
    try std.testing.expectEqualStrings("\"x;y\"", statements.next().?);
    try std.testing.expectEqualStrings("z", statements.next().?);
    try std.testing.expect(statements.next() == null);
    try std.testing.expectEqualStrings("q", unquote(" \"q\" "));
}
