//! Test root for the platform-independent core: the Markdown parser and diagram layout.

test {
    _ = @import("markdown.zig");
    _ = @import("mermaid.zig");
}
