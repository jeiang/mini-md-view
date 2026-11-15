//! Syntax highlighting: the source of one code block to colored spans, with tree-sitter.
//!
//! tree-sitter allocates with malloc, and so does the C library's regex engine for query
//! predicates. They are the one exception to the static memory rule. Everything around them is
//! bounded: the size of a highlighted block, the number of spans, the work that a parse and a
//! query may do, and the nesting of captures. Past a limit the block is not highlighted at all.
//!
//! The parser, the query cursor and the compiled queries are global and kept for the life of the
//! process. Only one thread may highlight: the viewer does it on the main thread.

const std = @import("std");
const assert = std.debug.assert;
const languages = @import("highlight_languages.zig").languages;
const queries = @import("highlight_queries");

pub const source_size_max = 32 * 1024;
pub const spans_max = 16 * 1024;
const captures_max = 2 * spans_max;
const depth_max = 128;
const capture_names_max = 256;
const regexes_max = 64;
const regex_size_max = 8 * 1024;
const name_size_max = 32;
/// In-progress matches per query. Past it tree-sitter drops matches, so the block is plain.
const matches_max = 256;
/// Time that one block may take to parse and to query. A dense block of `source_size_max`
/// bytes takes 5 to 40 ms in a release build on an Apple M3 Pro, but error recovery on hostile
/// input can take seconds.
const block_time_max_ns = 100 * std.time.ns_per_ms;
/// Time that the blocks of one document may take together, so that a reload does not hang.
const document_time_max_ns = 1000 * std.time.ns_per_ms;

comptime {
    assert(languages.len == queries.sources.len);
    assert(languages.len <= std.math.maxInt(u8));
    assert(source_size_max <= std.math.maxInt(u32));
    assert(captures_max >= spans_max);
}

pub const Kind = enum(u8) {
    keyword,
    string,
    comment,
    number,
    constant,
    type,
    function,
    variable,
    property,
    operator,
    punctuation,
    tag,
    attribute,
};

/// A byte range of the source.
pub const Span = struct {
    start: u32,
    end: u32,
    kind: Kind,
};

/// An index into the language table.
pub const Language = enum(u8) { _ };

/// tree-sitter capture names and their kinds. A capture name maps to the longest entry that is
/// equal to it or a dot-separated prefix of it: `keyword.control` maps to `keyword`.
const kind_names = [_]struct { []const u8, Kind }{
    .{ "attribute", .attribute },
    .{ "boolean", .constant },
    .{ "character", .string },
    .{ "comment", .comment },
    .{ "constant", .constant },
    .{ "constructor", .type },
    .{ "escape", .constant },
    .{ "field", .property },
    .{ "float", .number },
    .{ "function", .function },
    .{ "keyword", .keyword },
    .{ "method", .function },
    .{ "module", .type },
    .{ "namespace", .type },
    .{ "number", .number },
    .{ "operator", .operator },
    .{ "property", .property },
    .{ "punctuation", .punctuation },
    .{ "string", .string },
    .{ "string.escape", .constant },
    .{ "tag", .tag },
    .{ "type", .type },
    .{ "variable", .variable },
    .{ "variable.builtin", .constant },
};

/// Finds the language for the first word of a fence info string. Case does not matter.
pub fn language_find(name: []const u8) ?Language {
    if (name.len == 0 or name.len > name_size_max) return null;
    for (languages, 0..) |language, index| {
        if (std.ascii.eqlIgnoreCase(name, language.name)) return @fromBackingInt(@intCast(index));
        for (language.aliases) |alias| {
            assert(alias.len <= name_size_max);
            if (std.ascii.eqlIgnoreCase(name, alias)) return @fromBackingInt(@intCast(index));
        }
    }
    return null;
}

/// The deadline for the code blocks of a document that starts rendering now.
pub fn document_deadline() u64 {
    return clock_gettime_nsec_np(clock_uptime_raw) + document_time_max_ns;
}

/// Highlights the source of one code block. Returns spans that are sorted, do not overlap and
/// lie in the source, or null when the block is to be shown plain: it is over a limit, the
/// deadline from `document_deadline` passed, or the language failed to load.
pub fn highlight(
    language: Language,
    source: []const u8,
    spans: *[spans_max]Span,
    deadline_document: u64,
) ?[]const Span {
    const index = @backingInt(language);
    assert(index < languages.len);
    if (source.len > source_size_max) return null;
    const state = language_load(index) orelse return null;
    const tree_parser = parser.?;
    assert(ts_parser_set_language(tree_parser, grammars[index]()));

    const now = clock_gettime_nsec_np(clock_uptime_raw);
    if (now >= deadline_document) return null;
    deadline = @min(now + block_time_max_ns, deadline_document);
    deadline_passed = false;
    var source_input = source;
    const tree = ts_parser_parse_with_options(tree_parser, null, .{
        .payload = @ptrCast(&source_input),
        .read = input_read,
        .encoding = .utf8,
        .decode = null,
    }, .{ .payload = null, .progress_callback = progress_check }) orelse {
        assert(deadline_passed);
        ts_parser_reset(tree_parser);
        return null;
    };
    defer ts_tree_delete(tree);

    const query_cursor = cursor.?;
    const options: TSQueryCursorOptions = .{ .payload = null, .progress_callback = progress_check };
    const root = ts_tree_root_node(tree);
    ts_query_cursor_exec_with_options(query_cursor, state.query.?, root, &options);
    var capture_count: u32 = 0;
    var match: TSQueryMatch = undefined;
    var capture_index: u32 = 0;
    while (ts_query_cursor_next_capture(query_cursor, &match, &capture_index)) {
        assert(capture_index < match.capture_count);
        if (!predicates_check(index, state, &match, source)) {
            ts_query_cursor_remove_match(query_cursor, match.id);
            continue;
        }
        const capture = match.captures[capture_index];
        assert(capture.index < state.capture_count);
        const kind = state.capture_kinds[capture.index] orelse continue;
        const start = ts_node_start_byte(capture.node);
        const end = ts_node_end_byte(capture.node);
        assert(start <= end);
        assert(end <= source.len);
        if (start == end) continue;
        if (capture_count == captures_max) return null;
        captures[capture_count] = .{ .start = start, .end = end, .kind = kind };
        capture_count += 1;
    }
    if (deadline_passed) return null;
    if (ts_query_cursor_did_exceed_match_limit(query_cursor)) return null;
    return spans_resolve(captures[0..capture_count], spans);
}

/// Turns captures into flat spans. A capture inside another one wins over it, as does a later
/// capture of the same node, which comes from a later query pattern. This is what tree-sitter's
/// own highlighter does.
fn spans_resolve(found: []Capture, spans: *[spans_max]Span) ?[]const Span {
    assert(found.len <= captures_max);
    // The sort is stable: captures of the same range keep the order in which tree-sitter gave
    // them, which is the order of the query patterns.
    std.mem.sort(Capture, found, {}, capture_before);
    var resolver: Resolver = .{ .spans = spans };
    for (found) |capture_found| {
        var capture = capture_found;
        while (resolver.depth > 0 and stack[resolver.depth - 1].end <= capture.start) {
            if (!resolver.pop()) return null;
        }
        const top: ?Kind = if (resolver.depth > 0) stack[resolver.depth - 1].kind else null;
        if (!resolver.emit(capture.start, top)) return null;
        // Captures are tree nodes, so they nest. This only guards against a node that does not.
        if (resolver.depth > 0) capture.end = @min(capture.end, stack[resolver.depth - 1].end);
        if (resolver.depth == depth_max) return null;
        stack[resolver.depth] = capture;
        resolver.depth += 1;
    }
    while (resolver.depth > 0) {
        if (!resolver.pop()) return null;
    }
    const result = spans[0..resolver.span_count];
    for (result, 0..) |span, span_index| {
        assert(span.start < span.end);
        if (span_index > 0) assert(result[span_index - 1].end <= span.start);
    }
    return result;
}

const Capture = struct {
    start: u32,
    end: u32,
    kind: Kind,
};

fn capture_before(_: void, a: Capture, b: Capture) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end;
}

const Resolver = struct {
    spans: *[spans_max]Span,
    span_count: u32 = 0,
    depth: u32 = 0,
    /// Everything before this byte has been emitted.
    position: u32 = 0,

    /// Emits the bytes from `position` to `end` in the given kind, or plain when null.
    fn emit(resolver: *Resolver, end: u32, kind: ?Kind) bool {
        if (end <= resolver.position) return true;
        defer resolver.position = end;
        const span_kind = kind orelse return true;
        if (resolver.span_count > 0) {
            const last = &resolver.spans[resolver.span_count - 1];
            if (last.end == resolver.position and last.kind == span_kind) {
                last.end = end;
                return true;
            }
        }
        if (resolver.span_count == spans_max) return false;
        resolver.spans[resolver.span_count] = .{
            .start = resolver.position,
            .end = end,
            .kind = span_kind,
        };
        resolver.span_count += 1;
        return true;
    }

    fn pop(resolver: *Resolver) bool {
        assert(resolver.depth > 0);
        const top = stack[resolver.depth - 1];
        resolver.depth -= 1;
        return resolver.emit(top.end, top.kind);
    }
};

/// The number of UTF-16 code units in UTF-8 text. Text views count in UTF-16 units, and spans
/// count in bytes. Every byte that starts a code point is one unit, and code points of four
/// bytes are two.
pub fn utf16_length(bytes: []const u8) usize {
    var result: usize = 0;
    for (bytes) |byte| {
        if (byte & 0xC0 != 0x80) result += 1;
        if (byte >= 0xF0) result += 1;
    }
    assert(result <= bytes.len);
    return result;
}

// Languages.

const State = struct {
    query: ?*TSQuery = null,
    failed: bool = false,
    capture_count: u32 = 0,
    capture_kinds: [capture_names_max]?Kind = undefined,
};

const LanguageFunction = *const fn () callconv(.c) *const TSLanguage;

const grammars = grammars: {
    var result: [languages.len]LanguageFunction = undefined;
    for (languages, &result) |language, *grammar| {
        grammar.* = @extern(LanguageFunction, .{ .name = "tree_sitter_" ++ language.name });
    }
    break :grammars result;
};

var states: [languages.len]State = @splat(.{});
var parser: ?*TSParser = null;
var cursor: ?*TSQueryCursor = null;
var captures: [captures_max]Capture = undefined;
var stack: [depth_max]Capture = undefined;
var deadline: u64 = 0;
var deadline_passed: bool = false;

/// Compiles the language's query on first use. A grammar that the runtime rejects or a query
/// that does not compile is a programmer error that the tests catch. At run time the language
/// stays plain.
fn language_load(index: u8) ?*State {
    assert(index < languages.len);
    const state = &states[index];
    if (state.failed) return null;
    if (state.query != null) return state;
    state.failed = true;
    if (parser == null) {
        parser = ts_parser_new();
        cursor = ts_query_cursor_new();
        ts_query_cursor_set_match_limit(cursor.?, matches_max);
    }
    const grammar = grammars[index]();
    if (!ts_parser_set_language(parser.?, grammar)) return null;
    const source = queries.sources[index];
    var error_offset: u32 = 0;
    var error_type: TSQueryError = .none;
    const source_length: u32 = @intCast(source.len);
    const query =
        ts_query_new(grammar, source.ptr, source_length, &error_offset, &error_type) orelse
        return null;
    const capture_count = ts_query_capture_count(query);
    if (capture_count > capture_names_max or !predicates_load(index, query)) {
        ts_query_delete(query);
        return null;
    }
    state.capture_count = capture_count;
    for (state.capture_kinds[0..capture_count], 0..) |*kind, capture_id| {
        var length: u32 = 0;
        const name = ts_query_capture_name_for_id(query, @intCast(capture_id), &length);
        kind.* = kind_find(name[0..length]);
    }
    state.query = query;
    state.failed = false;
    return state;
}

fn kind_find(name: []const u8) ?Kind {
    var result: ?Kind = null;
    var result_length: usize = 0;
    for (kind_names) |entry| {
        const prefix = entry[0];
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        if (name.len > prefix.len and name[prefix.len] != '.') continue;
        if (prefix.len > result_length) {
            result = entry[1];
            result_length = prefix.len;
        }
    }
    return result;
}

// Query predicates. The runtime parses them but leaves their evaluation to the caller.

const Predicate = enum { eq, not_eq, any_of, not_any_of, match, not_match, other };

fn predicate_find(name: []const u8) Predicate {
    if (std.mem.eql(u8, name, "eq?")) return .eq;
    if (std.mem.eql(u8, name, "not-eq?")) return .not_eq;
    if (std.mem.eql(u8, name, "any-of?")) return .any_of;
    if (std.mem.eql(u8, name, "not-any-of?")) return .not_any_of;
    if (std.mem.eql(u8, name, "match?")) return .match;
    if (std.mem.eql(u8, name, "not-match?")) return .not_match;
    // The Lua patterns in the queries are also regular expressions with the same meaning.
    // `predicates_load` rejects the ones with `%`, where the two differ.
    if (std.mem.eql(u8, name, "lua-match?")) return .match;
    return .other;
}

/// Checks the shape of every text predicate and compiles the regular expressions. Other
/// predicates, such as `#set!` and `#is-not? local`, do not filter matches here.
fn predicates_load(index: u8, query: *TSQuery) bool {
    const pattern_count = ts_query_pattern_count(query);
    for (0..pattern_count) |pattern_index| {
        var step_count: u32 = 0;
        const steps_start =
            ts_query_predicates_for_pattern(query, @intCast(pattern_index), &step_count);
        var steps: []const TSQueryPredicateStep = steps_start[0..step_count];
        while (steps.len > 0) {
            const end = for (steps, 0..) |step, step_index| {
                if (step.type == .done) break step_index;
            } else return false;
            const predicate = steps[0..end];
            steps = steps[end + 1 ..];
            if (predicate.len == 0 or predicate[0].type != .string) return false;
            const name = query_string(query, predicate[0].value_id);
            const arguments = predicate[1..];
            switch (predicate_find(name)) {
                .other => {},
                .eq, .not_eq => {
                    if (arguments.len != 2 or arguments[0].type != .capture) return false;
                },
                .any_of, .not_any_of => {
                    if (arguments.len < 2 or arguments[0].type != .capture) return false;
                    for (arguments[1..]) |argument| {
                        if (argument.type != .string) return false;
                    }
                },
                .match, .not_match => {
                    if (arguments.len != 2 or arguments[0].type != .capture) return false;
                    if (arguments[1].type != .string) return false;
                    const pattern = query_string(query, arguments[1].value_id);
                    const lua = std.mem.eql(u8, name, "lua-match?");
                    if (lua and std.mem.indexOfScalar(u8, pattern, '%') != null) return false;
                    if (!regex_add(index, arguments[1].value_id, pattern)) return false;
                },
            }
        }
    }
    return true;
}

fn query_string(query: *const TSQuery, id: u32) []const u8 {
    var length: u32 = 0;
    const bytes = ts_query_string_value_for_id(query, id, &length);
    return bytes[0..length];
}

/// Whether the captures of the match so far satisfy the predicates of its pattern.
fn predicates_check(
    index: u8,
    state: *const State,
    match: *const TSQueryMatch,
    source: []const u8,
) bool {
    const query = state.query.?;
    var step_count: u32 = 0;
    const steps_start = ts_query_predicates_for_pattern(query, match.pattern_index, &step_count);
    var steps: []const TSQueryPredicateStep = steps_start[0..step_count];
    const match_captures = match.captures[0..match.capture_count];
    while (steps.len > 0) {
        const end = for (steps, 0..) |step, step_index| {
            if (step.type == .done) break step_index;
        } else unreachable;
        const predicate = steps[0..end];
        steps = steps[end + 1 ..];
        const predicate_kind = predicate_find(query_string(query, predicate[0].value_id));
        if (predicate_kind == .other) continue;
        const arguments = predicate[1..];
        assert(arguments[0].type == .capture);
        for (match_captures) |capture| {
            if (capture.index != arguments[0].value_id) continue;
            const text = node_text(capture.node, source);
            const satisfied = switch (predicate_kind) {
                .eq, .not_eq => satisfied: {
                    const expected = switch (arguments[1].type) {
                        .string => query_string(query, arguments[1].value_id),
                        .capture => for (match_captures) |other| {
                            if (other.index != arguments[1].value_id) continue;
                            break node_text(other.node, source);
                        } else continue,
                        .done => unreachable,
                    };
                    break :satisfied std.mem.eql(u8, text, expected) == (predicate_kind == .eq);
                },
                .any_of, .not_any_of => satisfied: {
                    const found = for (arguments[1..]) |argument| {
                        const string = query_string(query, argument.value_id);
                        if (std.mem.eql(u8, text, string)) break true;
                    } else false;
                    break :satisfied found == (predicate_kind == .any_of);
                },
                .match, .not_match => satisfied: {
                    const regex = regex_find(index, arguments[1].value_id);
                    const start = ts_node_start_byte(capture.node);
                    const found = regex_match(regex, source, start, ts_node_end_byte(capture.node));
                    break :satisfied found == (predicate_kind == .match);
                },
                .other => unreachable,
            };
            if (!satisfied) return false;
        }
    }
    return true;
}

fn node_text(node: TSNode, source: []const u8) []const u8 {
    const start = ts_node_start_byte(node);
    const end = ts_node_end_byte(node);
    assert(start <= end);
    assert(end <= source.len);
    return source[start..end];
}

// Regular expressions, with the C library's engine. Queries use the Rust regex syntax. The
// enhanced extended syntax of macOS shares the subset that the queries use, such as `\d`.

const Regex = struct {
    language: u8,
    string_id: u32,
    compiled: regex_t,
};

var regexes: [regexes_max]Regex = undefined;
var regex_count: u32 = 0;

fn regex_add(index: u8, string_id: u32, pattern: []const u8) bool {
    for (regexes[0..regex_count]) |*regex| {
        if (regex.language == index and regex.string_id == string_id) return true;
    }
    if (regex_count == regexes_max) return false;
    if (pattern.len >= regex_size_max) return false;
    var buffer: [regex_size_max]u8 = undefined;
    @memcpy(buffer[0..pattern.len], pattern);
    buffer[pattern.len] = 0;
    const regex = &regexes[regex_count];
    regex.* = .{ .language = index, .string_id = string_id, .compiled = undefined };
    const flags = reg_extended | reg_enhanced;
    if (regcomp(&regex.compiled, @ptrCast(&buffer), flags) != 0) return false;
    regex_count += 1;
    return true;
}

fn regex_find(index: u8, string_id: u32) *const regex_t {
    for (regexes[0..regex_count]) |*regex| {
        if (regex.language == index and regex.string_id == string_id) return &regex.compiled;
    }
    unreachable;
}

fn regex_match(regex: *const regex_t, source: []const u8, start: u32, end: u32) bool {
    assert(start <= end);
    assert(end <= source.len);
    // The source has no terminating zero: the range is passed in the first match slot.
    var range = [1]regmatch_t{.{ .rm_so = start, .rm_eo = end }};
    return regexec(regex, source.ptr, 1, &range, reg_startend) == 0;
}

// tree-sitter callbacks.

fn input_read(
    payload: ?*anyopaque,
    byte_index: u32,
    _: TSPoint,
    bytes_read: *u32,
) callconv(.c) [*]const u8 {
    const source: *const []const u8 = @ptrCast(@alignCast(payload.?));
    const offset = @min(byte_index, source.len);
    bytes_read.* = @intCast(source.len - offset);
    return source.ptr + offset;
}

fn progress_check(_: *anyopaque) callconv(.c) bool {
    if (clock_gettime_nsec_np(clock_uptime_raw) < deadline) return false;
    deadline_passed = true;
    return true;
}

// C declarations: the tree-sitter API (`tree_sitter/api.h`) and POSIX regular expressions in
// the layout of macOS (`_regex.h`).

const TSLanguage = opaque {};
const TSParser = opaque {};
const TSTree = opaque {};
const TSQuery = opaque {};
const TSQueryCursor = opaque {};

const TSPoint = extern struct { row: u32, column: u32 };

const TSInput = extern struct {
    payload: ?*anyopaque,
    read: *const fn (?*anyopaque, u32, TSPoint, *u32) callconv(.c) [*]const u8,
    encoding: enum(c_uint) { utf8, utf16le, utf16be, custom },
    decode: ?*const anyopaque,
};

const ProgressCallback = *const fn (*anyopaque) callconv(.c) bool;
const TSParseOptions = extern struct { payload: ?*anyopaque, progress_callback: ProgressCallback };
const TSQueryCursorOptions = extern struct {
    payload: ?*anyopaque,
    progress_callback: ProgressCallback,
};

const TSNode = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const TSTree,
};

const TSQueryCapture = extern struct { node: TSNode, index: u32 };

const TSQueryMatch = extern struct {
    id: u32,
    pattern_index: u16,
    capture_count: u16,
    captures: [*]const TSQueryCapture,
};

const TSQueryPredicateStep = extern struct {
    type: enum(c_uint) { done, capture, string },
    value_id: u32,
};

const TSQueryError = enum(c_uint) { none, syntax, node_type, field, capture, structure, language };

extern fn ts_parser_new() *TSParser;
extern fn ts_parser_set_language(*TSParser, *const TSLanguage) bool;
extern fn ts_parser_parse_with_options(*TSParser, ?*const TSTree, TSInput, TSParseOptions) ?*TSTree;
extern fn ts_parser_reset(*TSParser) void;
extern fn ts_tree_delete(*TSTree) void;
extern fn ts_tree_root_node(*const TSTree) TSNode;
extern fn ts_node_start_byte(TSNode) u32;
extern fn ts_node_end_byte(TSNode) u32;
extern fn ts_query_new(*const TSLanguage, [*]const u8, u32, *u32, *TSQueryError) ?*TSQuery;
extern fn ts_query_delete(*TSQuery) void;
extern fn ts_query_pattern_count(*const TSQuery) u32;
extern fn ts_query_capture_count(*const TSQuery) u32;
extern fn ts_query_capture_name_for_id(*const TSQuery, u32, *u32) [*]const u8;
extern fn ts_query_string_value_for_id(*const TSQuery, u32, *u32) [*]const u8;
extern fn ts_query_predicates_for_pattern(*const TSQuery, u32, *u32) [*]const TSQueryPredicateStep;
extern fn ts_query_cursor_new() *TSQueryCursor;
extern fn ts_query_cursor_set_match_limit(*TSQueryCursor, u32) void;
extern fn ts_query_cursor_did_exceed_match_limit(*const TSQueryCursor) bool;
extern fn ts_query_cursor_exec_with_options(
    *TSQueryCursor,
    *const TSQuery,
    TSNode,
    *const TSQueryCursorOptions,
) void;
extern fn ts_query_cursor_next_capture(*TSQueryCursor, *TSQueryMatch, *u32) bool;
extern fn ts_query_cursor_remove_match(*TSQueryCursor, u32) void;

const regex_t = extern struct {
    re_magic: c_int,
    re_nsub: usize,
    re_endp: ?[*]const u8,
    re_g: ?*anyopaque,
};
const regmatch_t = extern struct { rm_so: i64, rm_eo: i64 };
const reg_extended: c_int = 0o1;
const reg_enhanced: c_int = 0o400;
const reg_startend: c_int = 0o4;

extern fn regcomp(*regex_t, [*:0]const u8, c_int) c_int;
extern fn regexec(*const regex_t, [*]const u8, usize, [*]regmatch_t, c_int) c_int;

const clock_uptime_raw: c_int = 8;
extern fn clock_gettime_nsec_np(c_int) u64;

const testing = std.testing;

fn expect_spans(name: []const u8, source: []const u8, expected: []const Span) !void {
    var spans: [spans_max]Span = undefined;
    const found = highlight(language_find(name).?, source, &spans, document_deadline()).?;
    errdefer for (found) |span| {
        std.debug.print("{d}..{d} {t} {s}\n", .{
            span.start,
            span.end,
            span.kind,
            source[span.start..span.end],
        });
    };
    for (expected) |span| {
        const present = for (found) |candidate| {
            if (std.meta.eql(candidate, span)) break true;
        } else false;
        try testing.expect(present);
    }
}

test "every language loads" {
    for (languages, 0..) |language, index| {
        errdefer std.debug.print("{s}: the grammar or its query does not load\n", .{language.name});
        try testing.expect(language_load(@intCast(index)) != null);
    }
}

test "fence names" {
    const pairs = [_][2][]const u8{
        .{ "sh", "bash" },       .{ "Shell", "bash" },     .{ "zsh", "bash" },
        .{ "c++", "cpp" },       .{ "CC", "cpp" },         .{ "cxx", "cpp" },
        .{ "hpp", "cpp" },       .{ "h", "c" },            .{ "golang", "go" },
        .{ "js", "javascript" }, .{ "jsx", "javascript" }, .{ "mjs", "javascript" },
        .{ "jsonc", "json" },    .{ "py", "python" },      .{ "rs", "rust" },
        .{ "ts", "typescript" }, .{ "yml", "yaml" },       .{ "TSX", "tsx" },
    };
    for (pairs) |pair| try testing.expectEqual(language_find(pair[1]).?, language_find(pair[0]).?);
    for (languages, 0..) |language, index| {
        const expected: Language = @fromBackingInt(@intCast(index));
        try testing.expectEqual(expected, language_find(language.name).?);
    }
    try testing.expectEqual(null, language_find("cobol"));
    try testing.expectEqual(null, language_find("mermaid"));
    try testing.expectEqual(null, language_find(""));
}

test "keywords, strings and comments" {
    try expect_spans("c", "return \"a\"; // c", &.{
        .{ .start = 0, .end = 6, .kind = .keyword },
        .{ .start = 7, .end = 10, .kind = .string },
        .{ .start = 12, .end = 16, .kind = .comment },
    });
    try expect_spans("python", "def f():\n    return 'x'  # c", &.{
        .{ .start = 0, .end = 3, .kind = .keyword },
        .{ .start = 4, .end = 5, .kind = .function },
        .{ .start = 13, .end = 19, .kind = .keyword },
        .{ .start = 20, .end = 23, .kind = .string },
        .{ .start = 25, .end = 28, .kind = .comment },
    });
    // `#match?` predicates: only names in capitals are constants.
    try expect_spans("javascript", "const AB = 1; let y = AB;", &.{
        .{ .start = 0, .end = 5, .kind = .keyword },
        .{ .start = 6, .end = 8, .kind = .constant },
        .{ .start = 11, .end = 12, .kind = .number },
        .{ .start = 18, .end = 19, .kind = .variable },
        .{ .start = 22, .end = 24, .kind = .constant },
    });
}

test "non-ASCII text" {
    try expect_spans("rust", "fn main() { let s = \"é\"; } // ü", &.{
        .{ .start = 0, .end = 2, .kind = .keyword },
        .{ .start = 20, .end = 24, .kind = .string },
        .{ .start = 28, .end = 33, .kind = .comment },
    });
    try expect_spans("python", "s = \"héllo\"  # ü", &.{
        .{ .start = 4, .end = 12, .kind = .string },
        .{ .start = 14, .end = 18, .kind = .comment },
    });
    try testing.expectEqual(5, utf16_length("aé€😀"));
    try testing.expectEqual(0, utf16_length(""));
}

test "limits" {
    var spans: [spans_max]Span = undefined;
    var source: [source_size_max + 1]u8 = undefined;
    const json = language_find("json").?;
    @memset(&source, ' ');
    try testing.expectEqual(null, highlight(json, &source, &spans, document_deadline()));
    const deadline_document = document_deadline();
    const blank = highlight(json, source[0..source_size_max], &spans, deadline_document);
    try testing.expect(blank != null);
    // More spans than fit.
    source[0] = '[';
    var index: usize = 1;
    while (index + 2 < source_size_max) : (index += 2) @memcpy(source[index..][0..2], "1,");
    source[index] = '1';
    source[index + 1] = ']';
    const many = highlight(json, source[0 .. index + 2], &spans, deadline_document);
    try testing.expectEqual(null, many);
    // The deadline passed.
    try testing.expectEqual(null, highlight(json, "[1]", &spans, 0));
    try testing.expect(highlight(json, "[1]", &spans, document_deadline()) != null);
}
