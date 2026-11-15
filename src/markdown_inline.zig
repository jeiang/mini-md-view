//! Markdown inline parser: one block of text to inline events.
//!
//! The parser works in three passes over a token array, without recursion:
//! 1. Scan the text into tokens. Links are resolved here, with a backward search for the opener.
//! 2. Match emphasis delimiters, which records on each delimiter run the spans it opens and closes.
//! 3. Emit events in token order.
//!
//! The text is mutable: entities are decoded in place, which works because an entity is never
//! shorter than its UTF-8 encoding.

const std = @import("std");
const assert = std.debug.assert;
const markdown = @import("markdown.zig");
const Event = markdown.Event;
const Definition = markdown.Definition;

pub const tokens_max = 1 << 15;

/// Spans that one delimiter run can open or close. Further delimiters stay literal.
const marks_max = 4;
/// How far back a closing delimiter searches for its opener, in tokens.
const opener_distance_max = 1024;
const code_span_size_max = 1 << 16;
const entity_size_max = 32;

const Mark = enum(u8) { emphasis, strong, strike };

const Kind = enum(u8) {
    text,
    code,
    soft_break,
    hard_break,
    delimiter,
    /// `[` or `![` that has not found its closing bracket yet.
    link_open,
    image_open,
    link_start,
    link_end,
    image_start,
    image_end,
    /// A token that was cancelled, such as an autolink inside a link.
    skip,
};

pub const Token = struct {
    kind: Kind,
    /// Byte range in the text.
    start: u32,
    end: u32,
    destination: []const u8 = "",
    /// Delimiters only: the delimiter character, and how many are not yet matched.
    marker: u8 = 0,
    count: u8 = 0,
    can_open: bool = false,
    can_close: bool = false,
    /// Delimiters and bracket openers: whether the token can still take part in a match.
    active: bool = true,
    opens: [marks_max]Mark = undefined,
    open_count: u8 = 0,
    closes: [marks_max]Mark = undefined,
    close_count: u8 = 0,
};

pub const Input = struct {
    text: []u8,
    tokens: *[tokens_max]Token,
    definitions: []const Definition,
    /// Free space for the output events.
    events: []Event,
};

pub const Output = struct { event_count: u32, word_count: u32, truncated: bool };

const entities = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = "amp", .value = "&" },  .{ .name = "lt", .value = "<" },
    .{ .name = "gt", .value = ">" },   .{ .name = "quot", .value = "\"" },
    .{ .name = "apos", .value = "'" }, .{ .name = "nbsp", .value = "\u{a0}" },
    .{ .name = "copy", .value = "©" },
    .{ .name = "reg", .value = "®" },
    .{ .name = "trade", .value = "™" },
    .{ .name = "mdash", .value = "—" },
    .{ .name = "ndash", .value = "–" },
    .{ .name = "hellip", .value = "…" },
    .{ .name = "larr", .value = "←" },
    .{ .name = "rarr", .value = "→" },
    .{ .name = "uarr", .value = "↑" },
    .{ .name = "darr", .value = "↓" },
    .{ .name = "times", .value = "×" },
    .{ .name = "middot", .value = "·" },
    .{ .name = "bull", .value = "•" },
    .{ .name = "laquo", .value = "«" },
    .{ .name = "raquo", .value = "»" },
    .{ .name = "lsquo", .value = "‘" },
    .{ .name = "rsquo", .value = "’" },
    .{ .name = "ldquo", .value = "“" },
    .{ .name = "rdquo", .value = "”" },
    .{ .name = "deg", .value = "°" },
    .{ .name = "plusmn", .value = "±" },
};

const Target = struct { destination: []const u8, end: u32 };

const Scanner = struct {
    text: []u8,
    tokens: *[tokens_max]Token,
    definitions: []const Definition,
    token_count: u32 = 0,
    position: u32 = 0,
    /// Start of the pending run of plain text.
    run_start: u32 = 0,
    /// Bracket openers that have not been matched or cancelled.
    opener_count: u32 = 0,
    overflow: bool = false,

    fn token_add(scanner: *Scanner, token: Token) void {
        assert(token.start <= token.end);
        assert(token.end <= scanner.text.len);
        if (scanner.token_count == tokens_max) {
            scanner.overflow = true;
            return;
        }
        scanner.tokens[scanner.token_count] = token;
        scanner.token_count += 1;
    }

    /// Emits the pending text up to `end`. The caller then moves `run_start`.
    fn run_flush(scanner: *Scanner, end: u32) void {
        assert(end <= scanner.text.len);
        if (end <= scanner.run_start) return;
        scanner.token_add(.{ .kind = .text, .start = scanner.run_start, .end = end });
        scanner.run_start = end;
    }

    /// Moves past a construct that produced tokens, so that the next text run starts after it.
    fn advance_to(scanner: *Scanner, position: u32) void {
        assert(position >= scanner.position);
        assert(position <= scanner.text.len);
        scanner.position = position;
        scanner.run_start = position;
    }

    fn byte_at(scanner: *const Scanner, position: u32) u8 {
        return if (position < scanner.text.len) scanner.text[position] else 0;
    }

    fn rest(scanner: *const Scanner) []const u8 {
        return scanner.text[scanner.position..];
    }

    fn scan(scanner: *Scanner) void {
        assert(scanner.position == 0);
        while (scanner.position < scanner.text.len and !scanner.overflow) {
            const position_old = scanner.position;
            switch (scanner.text[scanner.position]) {
                '\\' => scanner.scan_escape(),
                '`' => scanner.scan_code(),
                '*', '_', '~' => scanner.scan_delimiter(),
                '[' => scanner.scan_bracket_open(1),
                '!' => if (scanner.byte_at(scanner.position + 1) == '[') {
                    scanner.scan_bracket_open(2);
                } else {
                    scanner.position += 1;
                },
                ']' => scanner.scan_bracket_close(),
                '<' => scanner.scan_angle(),
                '&' => scanner.scan_entity(),
                '\n' => scanner.scan_break(),
                ':' => scanner.scan_url(),
                else => scanner.position += 1,
            }
            assert(scanner.position > position_old);
        }
        if (!scanner.overflow) scanner.run_flush(@intCast(scanner.text.len));
    }

    fn scan_escape(scanner: *Scanner) void {
        const next = scanner.byte_at(scanner.position + 1);
        if (next == '\n') {
            scanner.run_flush(scanner.position);
            scanner.token_add(.{
                .kind = .hard_break,
                .start = scanner.position,
                .end = scanner.position,
            });
            scanner.advance_to(scanner.position + 2);
        } else if (std.ascii.isPunctuation(next)) {
            // Drop the backslash. The escaped character starts the next text run.
            scanner.run_flush(scanner.position);
            scanner.run_start = scanner.position + 1;
            scanner.position += 2;
        } else {
            scanner.position += 1;
        }
    }

    fn scan_code(scanner: *Scanner) void {
        const open_start = scanner.position;
        const length = run_length(scanner.rest(), '`');
        const content_start = open_start + length;
        const search_end: u32 = @intCast(
            @min(scanner.text.len, content_start + code_span_size_max),
        );
        var cursor = content_start;
        while (cursor < search_end) {
            if (scanner.text[cursor] != '`') {
                cursor += 1;
                continue;
            }
            const close_length = run_length(scanner.text[cursor..], '`');
            if (close_length != length) {
                cursor += close_length;
                continue;
            }
            scanner.run_flush(open_start);
            const content = scanner.text[content_start..cursor];
            std.mem.replaceScalar(u8, content, '\n', ' ');
            const padded = content.len >= 2 and content[0] == ' ' and
                content[content.len - 1] == ' ' and std.mem.indexOfNone(u8, content, " ") != null;
            const pad: u32 = @intFromBool(padded);
            scanner.token_add(.{
                .kind = .code,
                .start = content_start + pad,
                .end = cursor - pad,
            });
            return scanner.advance_to(cursor + length);
        }
        scanner.position += length;
    }

    fn scan_delimiter(scanner: *Scanner) void {
        const marker = scanner.text[scanner.position];
        const length = @min(run_length(scanner.rest(), marker), std.math.maxInt(u8));
        const before = if (scanner.position == 0) ' ' else scanner.text[scanner.position - 1];
        const after = scanner.byte_at(scanner.position + length);
        const after_space = after == 0 or std.ascii.isWhitespace(after);
        const before_space = std.ascii.isWhitespace(before);
        const after_punctuation = std.ascii.isPunctuation(after);
        const before_punctuation = std.ascii.isPunctuation(before);
        const left = !after_space and (!after_punctuation or before_space or before_punctuation);
        const right = !before_space and (!before_punctuation or after_space or after_punctuation);
        // Underscores inside a word are not emphasis, so that snake_case stays intact.
        const can_open = if (marker == '_') left and (!right or before_punctuation) else left;
        const can_close = if (marker == '_') right and (!left or after_punctuation) else right;
        const literal = (!can_open and !can_close) or (marker == '~' and length > 2);
        if (literal) {
            scanner.position += length;
            return;
        }
        scanner.run_flush(scanner.position);
        scanner.token_add(.{
            .kind = .delimiter,
            .start = scanner.position,
            .end = scanner.position + length,
            .marker = marker,
            .count = @intCast(length),
            .can_open = can_open,
            .can_close = can_close,
        });
        scanner.advance_to(scanner.position + length);
    }

    fn scan_bracket_open(scanner: *Scanner, length: u32) void {
        assert(length == 1 or length == 2);
        scanner.run_flush(scanner.position);
        scanner.token_add(.{
            .kind = if (length == 1) .link_open else .image_open,
            .start = scanner.position,
            .end = scanner.position + length,
        });
        if (!scanner.overflow) scanner.opener_count += 1;
        scanner.advance_to(scanner.position + length);
    }

    fn scan_bracket_close(scanner: *Scanner) void {
        const opener_index = scanner.opener_find() orelse {
            scanner.position += 1;
            return;
        };
        const opener = &scanner.tokens[opener_index];
        assert(scanner.opener_count > 0);
        scanner.opener_count -= 1;
        const label = scanner.text[opener.end..scanner.position];
        const target = if (opener.active) scanner.target_parse(label) else null;
        if (target == null) {
            opener.kind = .text;
            scanner.position += 1;
            return;
        }
        scanner.run_flush(scanner.position);
        const image = opener.kind == .image_open;
        emphasis_process(scanner.tokens[opener_index + 1 .. scanner.token_count]);
        for (scanner.tokens[opener_index + 1 .. scanner.token_count]) |*token| {
            token.active = false;
            // A link cannot contain another link, which only an autolink could create here.
            if (!image and (token.kind == .link_start or token.kind == .link_end)) {
                token.kind = .skip;
            }
        }
        opener.kind = if (image) .image_start else .link_start;
        opener.destination = target.?.destination;
        scanner.token_add(.{
            .kind = if (image) .image_end else .link_end,
            .start = scanner.position,
            .end = scanner.position,
        });
        if (!image) {
            for (scanner.tokens[0..opener_index]) |*token| {
                if (token.kind == .link_open) token.active = false;
            }
        }
        scanner.advance_to(target.?.end);
    }

    fn opener_find(scanner: *Scanner) ?u32 {
        if (scanner.opener_count == 0) return null;
        var index = scanner.token_count;
        while (index > 0) {
            index -= 1;
            const kind = scanner.tokens[index].kind;
            if (kind == .link_open or kind == .image_open) return index;
        }
        unreachable;
    }

    /// Parses what follows a closing bracket at `position`: an inline destination, a reference
    /// label, or nothing, in which case the bracket text itself is the reference label.
    fn target_parse(scanner: *Scanner, label: []const u8) ?Target {
        assert(scanner.text[scanner.position] == ']');
        const after = scanner.position + 1;
        if (scanner.byte_at(after) == '(') {
            if (scanner.target_inline_parse(after + 1)) |target| return target;
        }
        if (scanner.byte_at(after) == '[') {
            const close = std.mem.indexOfScalarPos(u8, scanner.text, after + 1, ']') orelse {
                return null;
            };
            const reference = scanner.text[after + 1 .. close];
            const reference_or_label = if (reference.len > 0) reference else label;
            const destination = scanner.definition_find(reference_or_label);
            return .{ .destination = destination orelse return null, .end = @intCast(close + 1) };
        }
        return .{ .destination = scanner.definition_find(label) orelse return null, .end = after };
    }

    /// Parses `destination "title")`, starting after the opening parenthesis.
    fn target_inline_parse(scanner: *Scanner, start: u32) ?Target {
        const text = scanner.text;
        var cursor = whitespace_skip(text, start);
        var destination: []const u8 = "";
        if (scanner.byte_at(cursor) == '<') {
            const close = std.mem.indexOfAnyPos(u8, text, cursor + 1, ">\n") orelse return null;
            if (text[close] != '>') return null;
            destination = text[cursor + 1 .. close];
            cursor = @intCast(close + 1);
        } else {
            const destination_start = cursor;
            var depth: u32 = 0;
            while (cursor < text.len) : (cursor += 1) {
                const byte = text[cursor];
                if (std.ascii.isWhitespace(byte)) break;
                if (byte == '(') depth += 1;
                if (byte == ')') {
                    if (depth == 0) break;
                    depth -= 1;
                }
            }
            destination = text[destination_start..cursor];
        }
        cursor = whitespace_skip(text, cursor);
        const quote = scanner.byte_at(cursor);
        if (quote == '"' or quote == '\'' or quote == '(') {
            const quote_close: u8 = if (quote == '(') ')' else quote;
            const close = std.mem.indexOfScalarPos(u8, text, cursor + 1, quote_close) orelse {
                return null;
            };
            cursor = whitespace_skip(text, @intCast(close + 1));
        }
        if (scanner.byte_at(cursor) != ')') return null;
        return .{ .destination = destination, .end = cursor + 1 };
    }

    fn definition_find(scanner: *const Scanner, label_raw: []const u8) ?[]const u8 {
        const label = std.mem.trim(u8, label_raw, " \t\n");
        if (label.len == 0) return null;
        for (scanner.definitions) |definition| {
            if (std.ascii.eqlIgnoreCase(definition.label, label)) return definition.destination;
        }
        return null;
    }

    fn scan_angle(scanner: *Scanner) void {
        const rest_bytes = scanner.rest();
        for ([_][]const u8{ "<br>", "<br/>", "<br />" }) |tag| {
            const matches = rest_bytes.len >= tag.len and
                std.ascii.eqlIgnoreCase(rest_bytes[0..tag.len], tag);
            if (matches) {
                scanner.run_flush(scanner.position);
                scanner.token_add(.{
                    .kind = .hard_break,
                    .start = scanner.position,
                    .end = scanner.position,
                });
                return scanner.advance_to(scanner.position + @as(u32, @intCast(tag.len)));
            }
        }
        if (std.mem.startsWith(u8, rest_bytes, "<!--")) {
            if (std.mem.indexOf(u8, rest_bytes, "-->")) |close| {
                scanner.run_flush(scanner.position);
                return scanner.advance_to(scanner.position + @as(u32, @intCast(close + 3)));
            }
        }
        const close = std.mem.indexOfAny(u8, rest_bytes, "> \t\n") orelse rest_bytes.len;
        const closed = close < rest_bytes.len and rest_bytes[close] == '>';
        const content = rest_bytes[1..@max(close, 1)];
        const address = std.mem.indexOf(u8, content, "://") != null or
            std.mem.startsWith(u8, content, "mailto:") or
            (std.mem.indexOfScalar(u8, content, '@') != null and
                std.mem.indexOfScalar(u8, content, '<') == null);
        if (!closed or !address) {
            scanner.position += 1;
            return;
        }
        const start = scanner.position + 1;
        const end = scanner.position + @as(u32, @intCast(close));
        scanner.link_add(scanner.position, start, end);
        scanner.advance_to(end + 1);
    }

    /// Adds a link whose text is its own destination.
    fn link_add(scanner: *Scanner, flush_end: u32, start: u32, end: u32) void {
        assert(start < end);
        scanner.run_flush(flush_end);
        scanner.token_add(.{
            .kind = .link_start,
            .start = start,
            .end = start,
            .destination = scanner.text[start..end],
        });
        scanner.token_add(.{ .kind = .text, .start = start, .end = end });
        scanner.token_add(.{ .kind = .link_end, .start = end, .end = end });
    }

    fn scan_entity(scanner: *Scanner) void {
        const rest_bytes = scanner.rest();
        const window = rest_bytes[0..@min(rest_bytes.len, entity_size_max)];
        const close = std.mem.indexOfScalar(u8, window, ';') orelse 0;
        var buffer: [4]u8 = undefined;
        const value = entity_decode(window[1..@max(close, 1)], &buffer) orelse {
            scanner.position += 1;
            return;
        };
        assert(value.len <= close + 1);
        scanner.run_flush(scanner.position);
        @memcpy(scanner.text[scanner.position..][0..value.len], value);
        const end = scanner.position + @as(u32, @intCast(value.len));
        scanner.token_add(.{ .kind = .text, .start = scanner.position, .end = end });
        scanner.advance_to(scanner.position + @as(u32, @intCast(close + 1)));
    }

    fn scan_break(scanner: *Scanner) void {
        var content_end = scanner.position;
        while (content_end > scanner.run_start and scanner.text[content_end - 1] == ' ') {
            content_end -= 1;
        }
        const hard = scanner.position - content_end >= 2;
        scanner.run_flush(content_end);
        scanner.token_add(.{
            .kind = if (hard) .hard_break else .soft_break,
            .start = scanner.position,
            .end = scanner.position,
        });
        var next = scanner.position + 1;
        while (scanner.byte_at(next) == ' ' or scanner.byte_at(next) == '\t') next += 1;
        scanner.advance_to(next);
    }

    /// Recognizes a bare `http://` or `https://` address. The scanner stops at the colon, so the
    /// scheme is found by looking back into the pending text run.
    fn scan_url(scanner: *Scanner) void {
        const pending = scanner.text[scanner.run_start..scanner.position];
        const scheme_length: u32 = if (std.mem.endsWith(u8, pending, "https"))
            5
        else if (std.mem.endsWith(u8, pending, "http"))
            4
        else
            0;
        const start = scanner.position - scheme_length;
        const boundary = start == 0 or !std.ascii.isAlphanumeric(scanner.text[start - 1]);
        if (scheme_length == 0 or !boundary or !std.mem.startsWith(u8, scanner.rest(), "://")) {
            scanner.position += 1;
            return;
        }
        var end: u32 = @intCast(
            std.mem.indexOfAnyPos(u8, scanner.text, scanner.position, " \t\n<") orelse
                scanner.text.len,
        );
        while (end > scanner.position + 3) {
            const last = scanner.text[end - 1];
            const unbalanced = last == ')' and
                std.mem.indexOfScalar(u8, scanner.text[start..end], '(') == null;
            if (std.mem.indexOfScalar(u8, ".,;:!?*_~'\"", last) == null and !unbalanced) break;
            end -= 1;
        }
        if (end <= scanner.position + 3) {
            scanner.position += 1;
            return;
        }
        scanner.link_add(start, start, end);
        scanner.advance_to(end);
    }
};

fn run_length(bytes: []const u8, byte: u8) u32 {
    var length: u32 = 0;
    while (length < bytes.len and bytes[length] == byte) length += 1;
    return length;
}

fn whitespace_skip(text: []const u8, start: u32) u32 {
    var cursor = start;
    while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) cursor += 1;
    return cursor;
}

/// Decodes the name of an entity, without the `&` and `;`, into UTF-8.
fn entity_decode(name: []const u8, buffer: *[4]u8) ?[]const u8 {
    if (name.len == 0) return null;
    if (name[0] != '#') {
        for (entities) |entity| {
            if (std.mem.eql(u8, entity.name, name)) return entity.value;
        }
        return null;
    }
    const hexadecimal = name.len > 1 and (name[1] == 'x' or name[1] == 'X');
    const digits = name[if (hexadecimal) 2 else 1..];
    if (digits.len == 0 or digits.len > 7) return null;
    const code_point = std.fmt.parseInt(u21, digits, if (hexadecimal) 16 else 10) catch return null;
    if (code_point == 0) return null;
    const length = std.unicode.utf8Encode(code_point, buffer) catch return null;
    // The decoded bytes replace the entity in place, so they must not be longer than it.
    if (length > name.len + 2) return null;
    return buffer[0..length];
}

/// Matches closing delimiters with openers, as CommonMark's "process emphasis" does. Each match
/// is recorded on both runs. Runs inside a matched pair are deactivated, which keeps the
/// resulting spans well nested.
fn emphasis_process(tokens: []Token) void {
    for (tokens, 0..) |*closer, closer_index| {
        if (closer.kind != .delimiter or !closer.active or !closer.can_close) continue;
        var matched = false;
        while (closer.count > 0 and closer.close_count < marks_max) {
            const opener_index = emphasis_opener_find(tokens, closer_index) orelse break;
            const opener = &tokens[opener_index];
            const strike = closer.marker == '~';
            const use: u8 = if (strike)
                closer.count
            else if (opener.count >= 2 and closer.count >= 2)
                2
            else
                1;
            const mark: Mark = if (strike) .strike else if (use == 2) .strong else .emphasis;
            opener.opens[opener.open_count] = mark;
            opener.open_count += 1;
            closer.closes[closer.close_count] = mark;
            closer.close_count += 1;
            opener.count -= use;
            closer.count -= use;
            for (tokens[opener_index + 1 .. closer_index]) |*between| between.active = false;
            matched = true;
        }
        if (!matched and !closer.can_open) closer.active = false;
    }
}

fn emphasis_opener_find(tokens: []Token, closer_index: usize) ?usize {
    const closer = &tokens[closer_index];
    assert(closer.kind == .delimiter);
    const index_min = closer_index -| opener_distance_max;
    var index = closer_index;
    while (index > index_min) {
        index -= 1;
        const opener = &tokens[index];
        if (opener.kind != .delimiter or !opener.active or !opener.can_open) continue;
        if (opener.count == 0 or opener.open_count == marks_max) continue;
        if (opener.marker != closer.marker) continue;
        if (opener.marker == '~') {
            // Strikethrough: both runs must have the same length.
            if (opener.count == closer.count) return index;
            continue;
        }
        // The "rule of three" keeps `*a**b*` from pairing the first and second runs.
        const both = opener.can_close or closer.can_open;
        const length_opener = opener.end - opener.start;
        const length_closer = closer.end - closer.start;
        const sum_multiple = (length_opener + length_closer) % 3 == 0;
        const each_multiple = length_opener % 3 == 0 and length_closer % 3 == 0;
        if (both and sum_multiple and !each_multiple) continue;
        return index;
    }
    return null;
}

const Emitter = struct {
    text: []const u8,
    events: []Event,
    event_count: u32 = 0,
    word_count: u32 = 0,

    fn add(emitter: *Emitter, event: Event) void {
        assert(emitter.event_count < emitter.events.len);
        emitter.events[emitter.event_count] = event;
        emitter.event_count += 1;
    }

    fn text_add(emitter: *Emitter, bytes: []const u8) void {
        if (bytes.len == 0) return;
        emitter.add(.{ .text = bytes });
        var words = std.mem.tokenizeAny(u8, bytes, " \t\n");
        while (words.next() != null) emitter.word_count += 1;
    }

    fn token_emit(emitter: *Emitter, token: *const Token) void {
        const bytes = emitter.text[token.start..token.end];
        switch (token.kind) {
            .text, .link_open, .image_open => emitter.text_add(bytes),
            .code => emitter.add(.{ .code = bytes }),
            .soft_break => emitter.add(.soft_break),
            .hard_break => emitter.add(.hard_break),
            .link_start => emitter.add(.{ .link_start = token.destination }),
            .link_end => emitter.add(.link_end),
            .image_start => emitter.add(.{ .image_start = token.destination }),
            .image_end => emitter.add(.image_end),
            .skip => {},
            .delimiter => {
                for (token.closes[0..token.close_count]) |mark| emitter.add(switch (mark) {
                    .emphasis => .emphasis_end,
                    .strong => .strong_end,
                    .strike => .strike_end,
                });
                emitter.text_add(bytes[0..token.count]);
                // The first match of an opener is its innermost span, so it is emitted last.
                var index = token.open_count;
                while (index > 0) {
                    index -= 1;
                    emitter.add(switch (token.opens[index]) {
                        .emphasis => .emphasis_start,
                        .strong => .strong_start,
                        .strike => .strike_start,
                    });
                }
            },
        }
    }
};

fn token_event_count(token: *const Token) u32 {
    return switch (token.kind) {
        .skip => 0,
        .delimiter => @as(u32, token.close_count) + token.open_count +
            @intFromBool(token.count > 0),
        else => 1,
    };
}

pub fn parse(input: Input) Output {
    assert(input.text.len <= markdown.source_size_max);
    var scanner: Scanner = .{
        .text = input.text,
        .tokens = input.tokens,
        .definitions = input.definitions,
    };
    scanner.scan();
    const tokens = scanner.tokens[0..scanner.token_count];
    emphasis_process(tokens);

    var events_needed: u32 = 0;
    for (tokens) |*token| events_needed += token_event_count(token);
    var emitter: Emitter = .{ .text = input.text, .events = input.events };
    if (scanner.overflow or events_needed > input.events.len) {
        // The block is too complex: show it as plain text instead of dropping it.
        if (input.events.len > 0) emitter.text_add(input.text);
        return .{
            .event_count = emitter.event_count,
            .word_count = emitter.word_count,
            .truncated = true,
        };
    }
    for (tokens) |*token| emitter.token_emit(token);
    assert(emitter.event_count <= events_needed);
    return .{
        .event_count = emitter.event_count,
        .word_count = emitter.word_count,
        .truncated = false,
    };
}
