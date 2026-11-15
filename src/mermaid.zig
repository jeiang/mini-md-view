//! Mermaid diagrams: detects the diagram type and dispatches to its layout module.
//!
//! Every module turns diagram source into a `scene.Scene`. Modules are pure Zig, and they do not
//! allocate: working memory comes from the caller's scratch buffer.

const std = @import("std");
const assert = std.debug.assert;
const scene = @import("scene.zig");

const flowchart = @import("mermaid/flowchart.zig");
const state = @import("mermaid/state.zig");
const class = @import("mermaid/class.zig");
const er = @import("mermaid/er.zig");
const sequence = @import("mermaid/sequence.zig");
const pie = @import("mermaid/pie.zig");
const gantt = @import("mermaid/gantt.zig");

pub const Kind = enum { flowchart, state, class, er, sequence, pie, gantt };

const keywords = [_]struct { word: []const u8, kind: Kind }{
    .{ .word = "graph", .kind = .flowchart },
    .{ .word = "flowchart", .kind = .flowchart },
    .{ .word = "stateDiagram", .kind = .state },
    .{ .word = "stateDiagram-v2", .kind = .state },
    .{ .word = "classDiagram", .kind = .class },
    .{ .word = "classDiagram-v2", .kind = .class },
    .{ .word = "erDiagram", .kind = .er },
    .{ .word = "sequenceDiagram", .kind = .sequence },
    .{ .word = "pie", .kind = .pie },
    .{ .word = "gantt", .kind = .gantt },
};

pub const Header = struct {
    kind: Kind,
    /// The source from the header line onward: front matter and leading comments are removed.
    body: []const u8,
};

/// Finds the header line, which is the first line that is not blank, not a `%%` comment, and
/// not inside a `---` front matter block.
pub fn header_find(source: []const u8) ?Header {
    var in_front_matter = false;
    var line_start: usize = 0;
    while (line_start < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        assert(line_end >= line_start);
        const line = std.mem.trim(u8, source[line_start..line_end], " \t\r");
        const is_fence = std.mem.eql(u8, line, "---");
        if (is_fence) {
            in_front_matter = !in_front_matter;
        } else if (!in_front_matter and line.len > 0 and !std.mem.startsWith(u8, line, "%%")) {
            const word_end = std.mem.indexOfAny(u8, line, " \t;") orelse line.len;
            for (keywords) |keyword| {
                if (std.mem.eql(u8, line[0..word_end], keyword.word)) {
                    return .{ .kind = keyword.kind, .body = source[line_start..] };
                }
            }
            return null;
        }
        line_start = line_end + 1;
    }
    return null;
}

/// Lays out the diagram in `source` into `out`. `out` must be empty. On error, `out` holds a
/// partial scene that the caller must discard.
pub fn render(
    source: []const u8,
    measurer: scene.Measurer,
    scratch: []u8,
    out: *scene.Scene,
) scene.Error!void {
    assert(out.command_count == 0);
    assert(out.point_count == 0);
    assert(scratch.len > 0);
    const header = header_find(source) orelse return error.Syntax;
    try switch (header.kind) {
        .flowchart => flowchart.render(header.body, measurer, scratch, out),
        .state => state.render(header.body, measurer, scratch, out),
        .class => class.render(header.body, measurer, scratch, out),
        .er => er.render(header.body, measurer, scratch, out),
        .sequence => sequence.render(header.body, measurer, scratch, out),
        .pie => pie.render(header.body, measurer, scratch, out),
        .gantt => gantt.render(header.body, measurer, scratch, out),
    };
    assert(out.size.width > 0);
    assert(out.size.height > 0);
}

test "mermaid: header detection" {
    const source = "---\ntitle: x\n---\n%% comment\n\n  flowchart LR\n  A --> B\n";
    const header = header_find(source).?;
    try std.testing.expectEqual(Kind.flowchart, header.kind);
    try std.testing.expect(std.mem.startsWith(u8, header.body, "  flowchart LR"));
    try std.testing.expectEqual(Kind.state, header_find("stateDiagram-v2\n").?.kind);
    try std.testing.expectEqual(Kind.pie, header_find("pie title Pets\n").?.kind);
    try std.testing.expect(header_find("unknownDiagram\n") == null);
    try std.testing.expect(header_find("%% only a comment\n") == null);
}

test {
    _ = @import("scene.zig");
    _ = @import("scene_svg.zig");
    _ = flowchart;
    _ = state;
    _ = class;
    _ = er;
    _ = sequence;
    _ = pie;
    _ = gantt;
}
