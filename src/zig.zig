const std = @import("std");
const ts = @import("tree-sitter");
const lsp = @import("lsp");

const TestData = @import("main.zig").TestData;

extern fn tree_sitter_zig() callconv(.C) *ts.Language;

pub const Zig = struct {
    pub fn tsLanguage() *ts.Language {
        return tree_sitter_zig();
    }

    pub fn testNames(arena: std.mem.Allocator, root: ts.Node, doc: lsp.Document) []TestData {
        var tests = std.ArrayList(TestData).init(arena);

        var error_offset: u32 = 0;
        const query = ts.Query.create(tsLanguage(), "(test_declaration (string (string_content) @testName))", &error_offset) catch unreachable;
        defer query.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(query, root);

        while (cursor.nextMatch()) |match| {
            const capture = match.captures[0].node;
            const start = capture.startByte();
            const end = capture.endByte();
            tests.append(.{ .name = doc.text[start..end], .start_idx = start, .end_idx = end }) catch unreachable;
        }
        return tests.items;
    }

    pub fn runTests(allocator: std.mem.Allocator, filename: []const u8, test_data: *[]TestData) void {
        const output = executeTests(allocator, filename) catch unreachable;
        parseTestResult(test_data, output);
    }

    fn executeTests(allocator: std.mem.Allocator, filename: []const u8) std.process.Child.RunError!std.process.Child.RunResult {
        const argv = [_][]const u8{
            "zig",
            "test",
            filename,
        };
        return std.process.Child.run(.{ .allocator = allocator, .argv = &argv });
    }

    fn parseTestResult(tests: *[]TestData, output: std.process.Child.RunResult) void {
        var buf: [100]u8 = undefined;
        for (tests.*) |*t| {
            const start_str = std.fmt.bufPrint(&buf, "{s}...", .{t.name}) catch unreachable;
            if (std.mem.indexOf(u8, output.stderr, start_str)) |i| {
                const start_idx = i + start_str.len;
                if (std.mem.startsWith(u8, output.stderr[start_idx..], "OK")) {
                    t.pass = true;
                } else {
                    t.pass = false;
                    const end_idx = std.mem.indexOfPos(u8, output.stderr, start_idx, "FAIL").?;
                    t.output = output.stderr[start_idx..end_idx];
                }
            } else {
                // Probably compilation error
                t.pass = false;
                t.output = output.stderr;
            }
        }
    }
};
