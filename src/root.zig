//! Test root for the platform-independent core: the Markdown parser, diagram layout and syntax
//! highlighting.

test {
    _ = @import("address.zig");
    _ = @import("markdown.zig");
    _ = @import("history.zig");
    _ = @import("mermaid.zig");
    _ = @import("highlight.zig");
}
