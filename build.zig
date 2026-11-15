const std = @import("std");

/// Frameworks that the app links. They are part of macOS: the project has no dependencies.
const frameworks = [_][]const u8{
    "AppKit",
    "CoreGraphics",
    "Foundation",
    "UniformTypeIdentifiers",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    const bundle_plist = b.addInstallFile(
        b.path("assets/Info.plist"),
        "MiniMdView.app/Contents/Info.plist",
    );
    b.getInstallStep().dependOn(&bundle_exe.step);
    b.getInstallStep().dependOn(&bundle_plist.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // The tests cover the parts that do not need AppKit: the Markdown parser and diagram layout.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
