const std = @import("std");
const highlight_languages = @import("src/highlight_languages.zig").languages;

/// Frameworks that the app links. They are part of macOS.
const frameworks = [_][]const u8{
    "AppKit",
    "CoreGraphics",
    "CoreServices",
    "Foundation",
    "UniformTypeIdentifiers",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tree_sitter = tree_sitter_add(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "mini-md-view",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.linkSystemLibrary("objc", .{});
    for (frameworks) |framework| exe.root_module.linkFramework(framework, .{});
    exe.root_module.linkLibrary(tree_sitter.library);
    exe.root_module.addImport("highlight_queries", tree_sitter.queries);
    // Zig does not search the macOS SDK on its own when it runs inside a Nix shell.
    if (b.graph.environ_map.get("SDKROOT")) |sdk| {
        exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        exe.root_module.addFrameworkPath(.{
            .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }),
        });
    }
    b.installArtifact(exe);

    // The application bundle: `zig-out/MiniMdView.app`.
    const bundle_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "MiniMdView.app/Contents/MacOS" } },
    });
    // build.zig.zon holds the one version number.
    const plist = std.mem.replaceOwned(
        u8,
        b.allocator,
        @embedFile("assets/Info.plist"),
        "@VERSION@",
        @import("build.zig.zon").version,
    ) catch @panic("OOM");
    const bundle_plist = b.addInstallFile(
        b.addWriteFiles().add("Info.plist", plist),
        "MiniMdView.app/Contents/Info.plist",
    );
    const bundle_icon = b.addInstallFile(
        b.path("assets/AppIcon.icns"),
        "MiniMdView.app/Contents/Resources/AppIcon.icns",
    );
    b.getInstallStep().dependOn(&bundle_exe.step);
    b.getInstallStep().dependOn(&bundle_plist.step);
    b.getInstallStep().dependOn(&bundle_icon.step);

    // The icon is drawn by a tool, and its files are committed: a build does not redraw it.
    const icon_exe = b.addExecutable(.{
        .name = "icon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/icon.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true, // For `erfc`, which shapes the shadow.
        }),
    });
    const icon_run = b.addRunArtifact(icon_exe);
    icon_run.setCwd(b.path("."));
    b.step("icon", "Redraw assets/icon.png and assets/AppIcon.icns").dependOn(&icon_run.step);

    // The app runs from its bundle, so that it has the bundle's icon and document types.
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunFile(.{ .relative = .{
        .base = .install_prefix,
        .sub_path = "MiniMdView.app/Contents/MacOS/mini-md-view",
    } });
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // The tests cover the parts that do not need AppKit: the Markdown parser, diagram layout
    // and syntax highlighting.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.linkLibrary(tree_sitter.library);
    tests.root_module.addImport("highlight_queries", tree_sitter.queries);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

const TreeSitter = struct {
    library: *std.Build.Step.Compile,
    /// The module `highlight_queries`: one joined highlight query per language.
    queries: *std.Build.Module,
};

/// Compiles the tree-sitter runtime and the grammars of `src/highlight_languages.zig` from the
/// fetched packages, embeds their highlight queries, and installs their licenses in the bundle.
fn tree_sitter_add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) TreeSitter {
    // Upstream C is not tested with the undefined behavior sanitizer.
    const flags = &.{ "-std=c11", "-fno-sanitize=undefined" };
    const library = b.addLibrary(.{
        .name = "tree-sitter",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const runtime = package_path(b, "tree_sitter", "lib");
    library.root_module.addCSourceFile(.{ .file = runtime.path(b, "src/lib.c"), .flags = flags });
    library.root_module.addIncludePath(runtime.path(b, "include"));
    library.root_module.addIncludePath(runtime.path(b, "src"));
    library.root_module.addCMacro("_POSIX_C_SOURCE", "200112L");
    library.root_module.addCMacro("_DEFAULT_SOURCE", "");
    library.root_module.addCMacro("_DARWIN_C_SOURCE", "");
    license_install(b, "tree_sitter");

    const queries = b.addWriteFiles();
    var queries_source: std.ArrayList(u8) = .empty;
    queries_source.appendSlice(b.allocator, "pub const sources = [_][]const u8{\n") catch
        @panic("OOM");
    for (highlight_languages, 0..) |language, language_index| {
        const grammar = package_path(b, language.package, language.directory);
        library.root_module.addCSourceFile(.{
            .file = grammar.path(b, "src/parser.c"),
            .flags = flags,
        });
        const scanner = grammar.path(b, "src/scanner.c");
        if (std.Io.Dir.cwd().access(b.graph.io, scanner.cwd_relative, .{})) {
            library.root_module.addCSourceFile(.{ .file = scanner, .flags = flags });
        } else |_| {}
        library.root_module.addIncludePath(grammar.path(b, "src"));

        queries_source.appendSlice(b.allocator, "   ") catch @panic("OOM");
        for (language.queries, 0..) |query, query_index| {
            const name = b.fmt("{d}-{d}.scm", .{ language_index, query_index });
            _ = queries.addCopyFile(package_path(b, query.package, query.path), name);
            const separator = if (query_index == 0) "" else " ++ \"\\n\" ++";
            queries_source.appendSlice(b.allocator, b.fmt("{s} @embedFile(\"{s}\")", .{
                separator,
                name,
            })) catch @panic("OOM");
        }
        queries_source.appendSlice(b.allocator, ",\n") catch @panic("OOM");

        const first = for (highlight_languages[0..language_index]) |previous| {
            if (std.mem.eql(u8, previous.package, language.package)) break false;
        } else true;
        if (first) license_install(b, language.package);
    }
    queries_source.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    const queries_root = queries.add("queries.zig", queries_source.items);
    return .{
        .library = library,
        .queries = b.createModule(.{ .root_source_file = queries_root }),
    };
}

/// A path in a fetched package. `b.dependency` would compile and run the package's build script,
/// and some grammars ship build scripts that fail under Zig 0.17. The build runner's package
/// table gives the package directory without them.
fn package_path(b: *std.Build, package: []const u8, sub_path: []const u8) std.Build.LazyPath {
    const dependencies = @import("root").dependencies;
    inline for (dependencies.root_deps) |dependency| {
        if (std.mem.eql(u8, dependency[0], package)) {
            const root = @field(dependencies.packages, dependency[1]).build_root;
            return .{ .cwd_relative = b.pathJoin(&.{ root, sub_path }) };
        }
    }
    std.debug.panic("build.zig.zon has no dependency {s}", .{package});
}

fn license_install(b: *std.Build, package: []const u8) void {
    const destination = b.fmt("MiniMdView.app/Contents/Resources/licenses/{s}/LICENSE", .{package});
    const install = b.addInstallFile(package_path(b, package, "LICENSE"), destination);
    b.getInstallStep().dependOn(&install.step);
}
