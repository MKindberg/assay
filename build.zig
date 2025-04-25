const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "assay",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // Tree-sitter
    const tree_sitter = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("tree-sitter", tree_sitter.module("tree-sitter"));

    const tree_sitter_zig = b.dependency("tree_sitter_zig", .{
        .target = target,
        .optimize = optimize,
    });
    exe.addCSourceFile(.{ .file = tree_sitter_zig.path("src/parser.c") });

    // Babel
    const babel = b.dependency("babel", .{});
    const lsp = babel.module("lsp");
    exe.root_module.addImport("lsp", lsp);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
