//! Tests for the Markdown parser. Events are printed in an HTML-like notation and compared.

const std = @import("std");
const markdown = @import("markdown.zig");

var storage: markdown.Storage = undefined;
var source_buffer: [4096]u8 = undefined;
var output_buffer: [16 * 1024]u8 = undefined;

const Output = struct {
    count: usize = 0,

    fn add(output: *Output, comptime fmt: []const u8, args: anytype) void {
        const printed = std.fmt.bufPrint(
            output_buffer[output.count..],
            fmt,
            args,
        ) catch unreachable;
        output.count += printed.len;
    }
};

fn print(events: []const markdown.Event) []const u8 {
    var output: Output = .{};
    for (events) |event| switch (event) {
        .blockquote_start => output.add("<quote>", .{}),
        .blockquote_end => output.add("</quote>", .{}),
        .list_start => |list| output.add("<{s}{s}{d}>", .{
            if (list.ordered) "ol" else "ul",
            if (list.tight) "" else " loose ",
            list.start,
        }),
        .list_end => output.add("</list>", .{}),
        .item_start => |task| output.add("<li{s}>", .{switch (task) {
            .none => "",
            .unchecked => " todo",
            .checked => " done",
        }}),
        .item_end => output.add("</li>", .{}),
        .paragraph_start => output.add("<p>", .{}),
        .paragraph_end => output.add("</p>", .{}),
        .heading_start => |level| output.add("<h{d}>", .{level}),
        .heading_end => output.add("</h>", .{}),
        .code_block_start => |info| output.add("<pre {s}>", .{info}),
        .code_line => |line| output.add("{s}|", .{line}),
        .code_block_end => output.add("</pre>", .{}),
        .thematic_break => output.add("<hr>", .{}),
        .table_start => |columns| output.add("<table {d}>", .{columns}),
        .table_end => output.add("</table>", .{}),
        .row_start => |header| output.add("<tr{s}>", .{if (header) " head" else ""}),
        .row_end => output.add("</tr>", .{}),
        .cell_start => |cell_align| output.add("<td {s}>", .{@tagName(cell_align)}),
        .cell_end => output.add("</td>", .{}),
        .text => |bytes| output.add("{s}", .{bytes}),
        .code => |bytes| output.add("<code>{s}</code>", .{bytes}),
        .soft_break => output.add("<soft>", .{}),
        .hard_break => output.add("<br>", .{}),
        .emphasis_start => output.add("<em>", .{}),
        .emphasis_end => output.add("</em>", .{}),
        .strong_start => output.add("<b>", .{}),
        .strong_end => output.add("</b>", .{}),
        .strike_start => output.add("<s>", .{}),
        .strike_end => output.add("</s>", .{}),
        .link_start => |destination| output.add("<a {s}>", .{destination}),
        .link_end => output.add("</a>", .{}),
        .image_start => |destination| output.add("<img {s}>", .{destination}),
        .image_end => output.add("</img>", .{}),
    };
    return output_buffer[0..output.count];
}

fn expect(source: []const u8, expected: []const u8) !void {
    const result = markdown.parse(&storage, source);
    try std.testing.expect(!result.truncated);
    try std.testing.expectEqualStrings(expected, print(result.events));
}

test "markdown: paragraphs and headings" {
    try expect("hello\nworld\n\nnext", "<p>hello<soft>world</p><p>next</p>");
    try expect("# One\n## Two ##\n#nope", "<h1>One</h>" ++ "<h2>Two</h>" ++ "<p>#nope</p>");
    try expect("Title\n=====\nSub\n---\n", "<h1>Title</h><h2>Sub</h>");
    try expect("a\n\n---\n\nb", "<p>a</p><hr><p>b</p>");
    try expect("line  \nbreak\\\nagain", "<p>line<br>break<br>again</p>");
}

test "markdown: emphasis" {
    try expect("*a* **b** ***c*** ~~d~~", "<p><em>a</em> <b>b</b> <em><b>c</b></em> <s>d</s></p>");
    try expect("snake_case_name and _em_", "<p>snake_case_name and <em>em</em></p>");
    try expect("**a *b* c**", "<p><b>a <em>b</em> c</b></p>");
    try expect("2 * 3 * 4", "<p>2 * 3 * 4</p>");
    try expect("\\*not\\* `co*de` ``a ` b``", "<p>*not* <code>co*de</code> <code>a ` b</code></p>");
    try expect("*unclosed", "<p>*unclosed</p>");
}

test "markdown: links and images" {
    try expect("[text](http://a.b/c \"title\") end", "<p><a http://a.b/c>text</a> end</p>");
    try expect("![alt *x*](img.png)", "<p><img img.png>alt <em>x</em></img></p>");
    try expect("[ref][id] [id] [no]\n\n[id]: <http://x.y>", "<p><a http://x.y>ref</a> " ++
        "<a http://x.y>id</a> [no]</p>");
    try expect("see https://a.b/c. and <http://d.e>", "<p>see <a https://a.b/c>https://a.b/c</a>" ++
        ". and <a http://d.e>http://d.e</a></p>");
    try expect("[a](b) ] [", "<p><a b>a</a> ] [</p>");
    try expect("[![badge](i.svg)](http://x)", "<p><a http://x><img i.svg>badge</img></a></p>");
    try expect("&amp; &#65; &#x1F600; &nope;", "<p>& A \u{1F600} &nope;</p>");
}

test "markdown: lists" {
    try expect("- a\n- b\n", "<ul1><li><p>a</p></li><li><p>b</p></li></list>");
    try expect("- a\n\n- b\n", "<ul loose 1><li><p>a</p></li><li><p>b</p></li></list>");
    try expect(
        "1. a\n   - x\n   - y\n2. b",
        "<ol1><li><p>a</p><ul1><li><p>x</p></li><li><p>y</p></li></list></li>" ++
            "<li><p>b</p></li></list>",
    );
    try expect("- [ ] todo\n- [x] done", "<ul1><li todo><p>todo</p></li>" ++
        "<li done><p>done</p></li></list>");
    try expect("- a\nlazy\n\npara", "<ul1><li><p>a<soft>lazy</p></li></list><p>para</p>");
    try expect("- a\n+ b", "<ul1><li><p>a</p></li></list><ul1><li><p>b</p></li></list>");
    try expect("- a\n\n1. b\n2. c", "<ul1><li><p>a</p></li></list>" ++
        "<ol1><li><p>b</p></li><li><p>c</p></li></list>");
    try expect("text\n- item", "<p>text</p><ul1><li><p>item</p></li></list>");
    try expect("text\n2. not a list", "<p>text<soft>2. not a list</p>");
}

test "markdown: blockquotes and code" {
    try expect("> a\n> b\n\nc", "<quote><p>a<soft>b</p></quote><p>c</p>");
    try expect("> - a\n>   b\n> > c", "<quote><ul1><li><p>a<soft>b</p></li></list>" ++
        "<quote><p>c</p></quote></quote>");
    try expect("```zig\nconst a = 1;\n\n  b\n```\nx", "<pre zig>const a = 1;||  b|</pre><p>x</p>");
    try expect("    code\n\n    more\n\nx", "<pre >code||more|</pre><p>x</p>");
    try expect("- item\n  ```\n  in\n  ```", "<ul1><li><p>item</p><pre >in|</pre></li></list>");
    try expect("```\nunclosed", "<pre >unclosed|</pre>");
}

test "markdown: tables" {
    try expect(
        "| a | b |\n|:--|--:|\n| 1 | `x\\|y` |\n| only |\n\nafter",
        "<table 2><tr head><td left>a</td><td right>b</td></tr>" ++
            "<tr><td left>1</td><td right><code>x\\|y</code></td></tr>" ++
            "<tr><td left>only</td><td right></td></tr></table><p>after</p>",
    );
    try expect(
        "a | b\n--|--",
        "<table 2><tr head><td default>a</td><td default>b</td></tr></table>",
    );
    try expect("a | b\n---", "<h2>a | b</h>");
}

test "markdown: every prefix and every single-byte mutation parses" {
    const sample = "# T\n> - [x] *a* **b** `c` [d](e) ![f](g)\n>   1. x\n\n```m\ny\n```\n" ++
        "| a | b |\n|---|:-:|\n| 1 | 2 |\n\n[r]: <u>\n<br>&amp;~~z~~ https://q.r\n";
    for (0..sample.len + 1) |length| {
        const result = markdown.parse(&storage, sample[0..length]);
        try std.testing.expect(!result.truncated);
    }
    const mutations = "*_`[]()<>!#-|~&\\ \n";
    for (0..sample.len) |index| {
        for (mutations) |mutation| {
            @memcpy(source_buffer[0..sample.len], sample);
            source_buffer[index] = mutation;
            const result = markdown.parse(&storage, source_buffer[0..sample.len]);
            try std.testing.expect(balanced(result.events));
        }
    }
}

/// Checks that start and end events nest properly.
fn balanced(events: []const markdown.Event) bool {
    var stack: [64]std.meta.Tag(markdown.Event) = undefined;
    var depth: usize = 0;
    for (events) |event| {
        const name = @tagName(event);
        if (std.mem.endsWith(u8, name, "_start")) {
            if (depth == stack.len) return false;
            stack[depth] = event;
            depth += 1;
        } else if (std.mem.endsWith(u8, name, "_end")) {
            if (depth == 0) return false;
            depth -= 1;
            const start_name = @tagName(stack[depth]);
            const stem = name[0 .. name.len - "_end".len];
            const start_stem = start_name[0 .. start_name.len - "_start".len];
            if (!std.mem.eql(u8, start_stem, stem)) return false;
        }
    }
    return depth == 0;
}

test "markdown: pathological input stays bounded" {
    const size = 256 * 1024;
    const buffer = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(buffer);
    for ([_][]const u8{ "*a ", "[", "`` ` ", "> ", "- ", "](", "a_b ", "|" }) |pattern| {
        for (buffer, 0..) |*byte, index| byte.* = pattern[index % pattern.len];
        const result = markdown.parse(&storage, buffer);
        try std.testing.expect(balanced(result.events));
    }
}
