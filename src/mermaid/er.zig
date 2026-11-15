//! Placeholder: replaced by the real implementation.

const scene = @import("../scene.zig");

pub fn render(
    source: []const u8,
    measurer: scene.Measurer,
    scratch: []u8,
    out: *scene.Scene,
) scene.Error!void {
    _ = source;
    _ = measurer;
    _ = scratch;
    _ = out;
    return error.Syntax;
}
