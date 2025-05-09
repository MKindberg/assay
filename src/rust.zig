const std = @import("std");
const ts = @import("tree-sitter");
const lsp = @import("lsp");

const TestData = @import("main.zig").TestData;

extern fn tree_sitter_rust() callconv(.C) *ts.Language;

pub const Rust = struct {
    pub fn tsLanguage() *ts.Language {
        return tree_sitter_rust();
    }

    pub fn testNames(arena: std.mem.Allocator, root: ts.Node, doc: lsp.Document) []TestData {
        var tests = std.ArrayList(TestData).init(arena);

        var error_offset: u32 = 0;
        const query = ts.Query.create(tsLanguage(), "(attribute_item (attribute (identifier)) @attr) (function_item name: (identifier) @testName)", &error_offset) catch unreachable;
        defer query.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(query, root);

        while (cursor.nextMatch()) |match| {
            const attr = match.captures[0].node;
            const attr_start = attr.startByte();
            const attr_end = attr.endByte();
            if (std.mem.eql(u8, "test", doc.text[attr_start..attr_end])) {
                if (cursor.nextMatch()) |m| {
                    const name = m.captures[0].node;
                    const start = name.startByte();
                    const end = name.endByte();
                    tests.append(.{ .name = doc.text[start..end], .start_idx = start, .end_idx = end }) catch unreachable;
                }
            }
        }
        return tests.items;
    }

    pub fn runTests(allocator: std.mem.Allocator, filename: []const u8, test_data: *[]TestData) void {
        const output = executeTests(allocator, filename) catch unreachable;
        parseTestResult(test_data, output);
    }

    fn executeTests(allocator: std.mem.Allocator, path: []const u8) std.process.Child.RunError!std.process.Child.RunResult {
        const sep = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
        const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
        const module = path[sep + 1 .. dot];
        const argv = [_][]const u8{
            "cargo",
            "test",
            module,
        };
        return std.process.Child.run(.{ .allocator = allocator, .argv = &argv });
    }

    fn parseTestResult(tests: *[]TestData, output: std.process.Child.RunResult) void {
        var buf: [100]u8 = undefined;
        for (tests.*) |*t| {
            const start_str = std.fmt.bufPrint(&buf, "{s} ... ", .{t.name}) catch unreachable;
            if (std.mem.indexOf(u8, output.stdout, start_str)) |i| {
                const start_idx = i + start_str.len;
                if (std.mem.startsWith(u8, output.stdout[start_idx..], "ok")) {
                    t.pass = true;
                    t.output = "Test ok";
                } else {
                    t.pass = false;
                    t.output = "Test failed";
                }
            } else {
                // Probably compilation error
                t.pass = false;
                t.output = output.stderr;
            }
        }
    }
};
