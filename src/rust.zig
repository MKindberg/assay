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
        parseTestResult(allocator, test_data, output);
    }

    fn executeTests(allocator: std.mem.Allocator, path: []const u8) std.process.Child.RunError!std.process.Child.RunResult {
        const sep = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
        const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
        const module = path[sep + 1 .. dot];
        const argv = [_][]const u8{
            "cargo",
            "test",
            module,
            "--",
            "--format",
            "json",
            "-Z",
            "unstable-options",
        };
        return std.process.Child.run(.{ .allocator = allocator, .argv = &argv });
    }

    const TestType = enum {
        Suite,
        Test,

        const Self = @This();
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
            _ = options;
            switch (try source.nextAlloc(allocator, .alloc_if_needed)) {
                inline .string, .allocated_string => |s| {
                    if (std.mem.eql(u8, s, "suite")) {
                        return .Suite;
                    } else if (std.mem.eql(u8, s, "test")) {
                        return .Test;
                    } else {
                        return error.UnexpectedToken;
                    }
                },
                else => return error.UnexpectedToken,
            }
        }
    };

    const TestEvent = enum {
        Starting,
        Ok,
        Failed,

        const Self = @This();
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
            _ = options;
            switch (try source.nextAlloc(allocator, .alloc_if_needed)) {
                inline .string, .allocated_string => |s| {
                    if (std.mem.eql(u8, s, "starting")) {
                        return .Starting;
                    } else if (std.mem.eql(u8, s, "ok")) {
                        return .Ok;
                    } else if (std.mem.eql(u8, s, "failed")) {
                        return .Failed;
                    } else {
                        return error.UnexpectedToken;
                    }
                },
                else => return error.UnexpectedToken,
            }
        }
    };

    const CargoResult = struct {
        type: TestType,
        event: TestEvent,
        name: ?[]const u8 = null,
        stdout: ?[]const u8 = null,
    };

    fn parseTestResult(allocator: std.mem.Allocator, tests: *[]TestData, output: std.process.Child.RunResult) void {
        if (output.stdout.len == 0) {
            // Probably compilation error
            for (tests.*) |*t| {
                t.pass = false;
                t.output = output.stderr;
            }
        }
        var lines = std.mem.splitScalar(u8, output.stdout, '\n');
        while (lines.next()) |line| {
            const result = std.json.parseFromSliceLeaky(CargoResult, allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
            if (result.type != .Test) continue;
            if (result.event == .Starting) continue;
            var it = std.mem.splitBackwardsSequence(u8, result.name.?, "::");
            const name = it.next().?;

            for (tests.*) |*t| {
                if (std.mem.eql(u8, t.name, name)) {
                    if (result.event == .Ok) {
                        t.pass = true;
                    } else if (result.event == .Failed) {
                        t.pass = false;
                        t.output = result.stdout;
                    }
                    break;
                }
            }
        }
    }
};
