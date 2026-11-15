//! Which image addresses the viewer can fetch from the network.
//!
//! A document is untrusted input, and the user approves an address by reading it. The rules
//! here keep the address that the user reads and the address that is fetched the same: no user
//! name in front of the host, nothing invisible, nothing that is not plain ASCII.

const std = @import("std");
const assert = std.debug.assert;

pub const size_max = 2048;

/// Whether an image source is an `https` address with a plain host name, an optional port, and
/// only visible ASCII characters.
pub fn fetchable(source: []const u8) bool {
    const scheme = "https://";
    if (source.len > size_max) return false;
    if (!std.ascii.startsWithIgnoreCase(source, scheme)) return false;
    for (source) |byte| {
        if (byte <= ' ' or byte >= 0x7F or byte == '\\') return false;
    }
    const rest = source[scheme.len..];
    const authority = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
    const host = authority[0 .. std.mem.indexOfScalar(u8, authority, ':') orelse authority.len];
    if (host.len == 0) return false;
    for (host) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-') return false;
    }
    const port = authority[host.len..];
    if (port.len == 0) return true;
    assert(port[0] == ':');
    if (port.len == 1) return false;
    for (port[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

test "fetchable: plain https addresses" {
    try std.testing.expect(fetchable("https://example.com/a.png"));
    try std.testing.expect(fetchable("HTTPS://Example.com:8443/a%20b.png?x=1&y=2#top"));
    try std.testing.expect(fetchable("https://img.shields.io/badge/build-passing-brightgreen"));
    try std.testing.expect(fetchable("https://example.com"));
}

test "fetchable: other schemes and local paths" {
    try std.testing.expect(!fetchable("http://example.com/a.png"));
    try std.testing.expect(!fetchable("ftp://example.com/a.png"));
    try std.testing.expect(!fetchable("https:/example.com/a.png"));
    try std.testing.expect(!fetchable("images/a.png"));
    try std.testing.expect(!fetchable("https://"));
    try std.testing.expect(!fetchable(""));
}

test "fetchable: an address that reads as another host" {
    // The host is `evil.example` in each of these.
    try std.testing.expect(!fetchable("https://good.example@evil.example/a.png"));
    try std.testing.expect(!fetchable("https://good.example%2Fa.png@evil.example/a.png"));
    try std.testing.expect(!fetchable("https://good.example\\@evil.example/a.png"));
    try std.testing.expect(!fetchable("https://good.example\n@evil.example/a.png"));
    try std.testing.expect(!fetchable("https://good.example\xE2\x80\xA8@evil.example/a.png"));
    try std.testing.expect(!fetchable("https://\xD0\xB0pple.com/a.png"));
    try std.testing.expect(!fetchable("https://example.com/a\xE2\x80\xAEgnp.exe"));
    try std.testing.expect(!fetchable("https://example.com/a b.png"));
    try std.testing.expect(!fetchable("https://[::1]/a.png"));
    try std.testing.expect(!fetchable("https://example.com:/a.png"));
    try std.testing.expect(!fetchable("https://example.com:80a/a.png"));
}

test "fetchable: length limit" {
    const prefix = "https://example.com/";
    var buffer: [size_max + 1]u8 = @splat('a');
    @memcpy(buffer[0..prefix.len], prefix);
    try std.testing.expect(fetchable(buffer[0..size_max]));
    try std.testing.expect(!fetchable(&buffer));
}
