//! The languages of highlighted code blocks. `build.zig` compiles their grammars and embeds their
//! queries from the fetched packages, and `highlight.zig` finds fence names here.

pub const Language = struct {
    /// Fence name. The grammar exports the function `tree_sitter_<name>`.
    name: []const u8,
    /// Other fence names, in lower case.
    aliases: []const []const u8 = &.{},
    /// The `build.zig.zon` dependency that holds the grammar.
    package: []const u8,
    /// Directory in the package that holds `src/parser.c` and, if the grammar has one,
    /// `src/scanner.c`.
    directory: []const u8 = ".",
    /// Highlight query files, joined in the order that the grammar's `tree-sitter.json` gives.
    queries: []const Query,
};

pub const Query = struct {
    package: []const u8,
    path: []const u8,
};

fn query(package: []const u8) []const Query {
    return &.{.{ .package = package, .path = "queries/highlights.scm" }};
}

/// To add a language, fetch its grammar with
/// `zig fetch --save=tree_sitter_<name> <release tarball URL>`, then add one entry here. The
/// tarball must contain the generated `src/parser.c`.
pub const languages = [_]Language{
    .{
        .name = "bash",
        .aliases = &.{ "sh", "shell", "zsh" },
        .package = "tree_sitter_bash",
        .queries = query("tree_sitter_bash"),
    },
    .{
        .name = "c",
        .aliases = &.{"h"},
        .package = "tree_sitter_c",
        .queries = query("tree_sitter_c"),
    },
    .{
        .name = "cpp",
        .aliases = &.{ "c++", "cc", "cxx", "hpp" },
        .package = "tree_sitter_cpp",
        .queries = query("tree_sitter_c") ++ query("tree_sitter_cpp"),
    },
    .{
        .name = "css",
        .package = "tree_sitter_css",
        .queries = query("tree_sitter_css"),
    },
    .{
        .name = "go",
        .aliases = &.{"golang"},
        .package = "tree_sitter_go",
        .queries = query("tree_sitter_go"),
    },
    .{
        .name = "html",
        .package = "tree_sitter_html",
        .queries = query("tree_sitter_html"),
    },
    .{
        .name = "javascript",
        .aliases = &.{ "js", "jsx", "mjs" },
        .package = "tree_sitter_javascript",
        .queries = &.{
            .{ .package = "tree_sitter_javascript", .path = "queries/highlights.scm" },
            .{ .package = "tree_sitter_javascript", .path = "queries/highlights-jsx.scm" },
            .{ .package = "tree_sitter_javascript", .path = "queries/highlights-params.scm" },
        },
    },
    .{
        .name = "json",
        .aliases = &.{"jsonc"},
        .package = "tree_sitter_json",
        .queries = query("tree_sitter_json"),
    },
    .{
        .name = "nix",
        .package = "tree_sitter_nix",
        .queries = query("tree_sitter_nix"),
    },
    .{
        .name = "python",
        .aliases = &.{"py"},
        .package = "tree_sitter_python",
        .queries = query("tree_sitter_python"),
    },
    .{
        .name = "rust",
        .aliases = &.{"rs"},
        .package = "tree_sitter_rust",
        .queries = query("tree_sitter_rust"),
    },
    .{
        .name = "toml",
        .package = "tree_sitter_toml",
        .queries = query("tree_sitter_toml"),
    },
    .{
        .name = "tsx",
        .package = "tree_sitter_typescript",
        .directory = "tsx",
        .queries = &.{
            .{ .package = "tree_sitter_typescript", .path = "queries/highlights.scm" },
            .{ .package = "tree_sitter_javascript", .path = "queries/highlights-jsx.scm" },
            .{ .package = "tree_sitter_javascript", .path = "queries/highlights.scm" },
        },
    },
    .{
        .name = "typescript",
        .aliases = &.{"ts"},
        .package = "tree_sitter_typescript",
        .directory = "typescript",
        .queries = query("tree_sitter_typescript") ++ query("tree_sitter_javascript"),
    },
    .{
        .name = "yaml",
        .aliases = &.{"yml"},
        .package = "tree_sitter_yaml",
        .queries = query("tree_sitter_yaml"),
    },
    .{
        .name = "zig",
        .package = "tree_sitter_zig",
        .queries = query("tree_sitter_zig"),
    },
};
