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

    linkTSLib("tree_sitter_zig", b, exe, target, optimize);
    linkTSLib("tree_sitter_rust", b, exe, target, optimize);

    // Babel
    const babel = b.dependency("babel", .{});
    const lsp = babel.module("lsp");
    exe.root_module.addImport("lsp", lsp);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}

fn linkTSLib(name: []const u8, b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const tree_sitter_lib = b.dependency(name, .{
        .target = target,
        .optimize = optimize,
    });
    const files = &[_][]const u8{ "src/parser.c", "src/scanner.c" };
    for (files) |f| {
        const file = tree_sitter_lib.path(f);
        std.fs.accessAbsolute(file.getPath(b), .{}) catch continue;
        exe.addCSourceFile(.{ .file = file });
    }
}
