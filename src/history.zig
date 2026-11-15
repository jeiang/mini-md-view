//! The back and forward history of a window: the files that it showed and where each was
//! scrolled to.

const std = @import("std");
const assert = std.debug.assert;

pub const path_size_max = 1024;
pub const entries_max = 32;

pub const Entry = struct {
    path_buffer: [path_size_max]u8,
    path_length: u32,
    /// The vertical origin of the visible area when the window left this entry.
    scroll: f64,

    pub fn path(entry: *const Entry) []const u8 {
        assert(entry.path_length > 0);
        return entry.path_buffer[0..entry.path_length];
    }
};

pub const Direction = enum { back, forward };

/// A ring of entries. When it is full, a new entry drops the oldest one.
pub const History = struct {
    entries: [entries_max]Entry,
    /// The ring position of the oldest entry.
    start: u32,
    count: u32,
    /// The current entry, counted from the oldest.
    index: u32,

    pub fn reset(history: *History) void {
        history.start = 0;
        history.count = 0;
        history.index = 0;
    }

    /// Adds an entry after the current one and makes it current. The entries in front of the
    /// current one go away.
    pub fn push(history: *History, entry_path: []const u8) void {
        assert(entry_path.len > 0);
        assert(entry_path.len <= path_size_max);
        assert(history.count <= entries_max);
        if (history.count > 0) {
            assert(history.index < history.count);
            history.count = history.index + 1;
        }
        if (history.count == entries_max) {
            history.start = (history.start + 1) % entries_max;
            history.count -= 1;
        }
        const entry = &history.entries[history.slot(history.count)];
        // The path can be the path of the current entry, which is never the slot that is reused.
        const path_start = @intFromPtr(entry_path.ptr);
        const slot_start = @intFromPtr(&entry.path_buffer);
        const path_end = path_start + entry_path.len;
        assert(path_end <= slot_start or path_start >= slot_start + path_size_max);
        @memcpy(entry.path_buffer[0..entry_path.len], entry_path);
        entry.path_length = @intCast(entry_path.len);
        entry.scroll = 0;
        history.count += 1;
        history.index = history.count - 1;
    }

    pub fn current(history: *History) *Entry {
        assert(history.count > 0);
        assert(history.index < history.count);
        return &history.entries[history.slot(history.index)];
    }

    pub fn current_path(history: *const History) []const u8 {
        assert(history.count > 0);
        assert(history.index < history.count);
        return history.entries[history.slot(history.index)].path();
    }

    /// The entry one step in the direction, or null when there is none.
    pub fn peek(history: *History, direction: Direction) ?*Entry {
        assert(history.count > 0);
        switch (direction) {
            .back => if (history.index == 0) return null,
            .forward => if (history.index + 1 == history.count) return null,
        }
        return &history.entries[history.slot(history.step(direction))];
    }

    pub fn move(history: *History, direction: Direction) void {
        assert(history.peek(direction) != null);
        history.index = history.step(direction);
    }

    fn step(history: *const History, direction: Direction) u32 {
        return switch (direction) {
            .back => history.index - 1,
            .forward => history.index + 1,
        };
    }

    fn slot(history: *const History, index: u32) u32 {
        assert(index < entries_max);
        return (history.start + index) % entries_max;
    }
};

test "history moves back and forward and drops forward entries on push" {
    var history: History = undefined;
    history.reset();
    history.push("a.md");
    try std.testing.expect(history.peek(.back) == null);
    try std.testing.expect(history.peek(.forward) == null);
    history.current().scroll = 10;
    history.push("b.md");
    history.push("c.md");
    history.move(.back);
    try std.testing.expectEqualStrings("b.md", history.current().path());
    history.move(.back);
    try std.testing.expectEqualStrings("a.md", history.current().path());
    try std.testing.expectEqual(10, history.current().scroll);
    try std.testing.expectEqualStrings("b.md", history.peek(.forward).?.path());
    history.push("d.md");
    try std.testing.expect(history.peek(.forward) == null);
    try std.testing.expectEqual(2, history.count);
    history.move(.back);
    try std.testing.expectEqualStrings("a.md", history.current().path());
}

test "history drops the oldest entry when full" {
    var history: History = undefined;
    history.reset();
    var buffer: [16]u8 = undefined;
    for (0..entries_max + 3) |index| {
        history.push(try std.fmt.bufPrint(&buffer, "{d}.md", .{index}));
    }
    try std.testing.expectEqual(entries_max, history.count);
    try std.testing.expectEqualStrings("34.md", history.current().path());
    for (0..entries_max - 1) |_| history.move(.back);
    try std.testing.expectEqualStrings("3.md", history.current().path());
    try std.testing.expect(history.peek(.back) == null);
}

test "history pushes the path of the current entry" {
    var history: History = undefined;
    history.reset();
    var buffer: [16]u8 = undefined;
    for (0..entries_max) |index| {
        history.push(try std.fmt.bufPrint(&buffer, "{d}.md", .{index}));
    }
    history.push(history.current().path());
    try std.testing.expectEqualStrings("31.md", history.current().path());
    try std.testing.expectEqualStrings("31.md", history.peek(.back).?.path());
}
