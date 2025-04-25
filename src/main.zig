const std = @import("std");
const builtin = @import("builtin");

const ts = @import("tree-sitter");
const lsp = @import("lsp");

const Zig = @import("zig.zig").Zig;

pub const std_options = std.Options{ .log_level = if (builtin.mode == .Debug) .debug else .info, .logFn = lsp.log };

const Language = union(enum) {
    zig: Zig,

    const Self = @This();

    fn init(uri: []const u8) ?Self {
        if (std.mem.endsWith(u8, uri, ".zig")) {
            return .{ .zig = .{} };
        }
        return null;
    }
    pub fn tsLanguage(self: Self) *ts.Language {
        return switch (self) {
            inline else => |l| @TypeOf(l).tsLanguage(),
        };
    }

    pub fn tsQuery(self: Self) *ts.Query {
        return switch (self) {
            inline else => |l| @TypeOf(l).tsQuery(),
        };
    }
    pub fn runTests(self: Self, arena: std.mem.Allocator, filename: []const u8, test_data: *[]TestData) void {
        return switch (self) {
            inline else => |l| @TypeOf(l).runTests(arena, filename, test_data),
        };
    }
};

pub const TestData = struct {
    name: []const u8,
    start_idx: usize,
    end_idx: usize,
    pass: bool = false,
    output: ?[]const u8 = null,
};

const State = struct {
    language: Language,
    parser: *ts.Parser,
    tree: *ts.Tree,

    const Self = @This();
    fn init(uri: []const u8, content: []const u8) Self {
        const language = Language.init(uri).?;
        const parser = ts.Parser.create();
        parser.setLanguage(language.tsLanguage()) catch unreachable;
        const tree = parser.parseString(content, null) orelse unreachable;
        return State{
            .language = language,
            .parser = parser,
            .tree = tree,
        };
    }

    fn deinit(self: Self) void {
        self.tree.destroy();
        const language = self.parser.getLanguage().?;
        self.parser.destroy();
        language.destroy();
    }
};
const Lsp = lsp.Lsp(State);

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
const allocator = debug_allocator.allocator();

var server: Lsp = undefined;
pub fn main() !u8 {
    const server_data = lsp.types.ServerData{
        .serverInfo = .{ .name = "server_name", .version = "0.1.0" },
    };
    server = Lsp.init(allocator, server_data);

    server.registerDocOpenCallback(handleOpenDoc);
    server.registerDocCloseCallback(handleCloseDoc);
    server.registerDocChangeCallback(handleChangeDoc);
    server.registerDocSaveCallback(handleSave);

    const res = server.start();

    return res;
}

fn handleOpenDoc(p: Lsp.OpenDocumentParameters) Lsp.OpenDocumentReturn {
    p.context.state = State.init(p.context.document.uri, p.context.document.text);
    sendDiagnostics(p.arena, p.context);
}

fn handleCloseDoc(p: Lsp.CloseDocumentParameters) void {
    p.context.state.?.deinit();
}

fn handleChangeDoc(p: Lsp.ChangeDocumentParameters) Lsp.ChangeDocumentReturn {
    const doc = p.context.document;
    for (p.changes) |c| {
        const start_pos = c.range.start;
        const old_end_pos = c.range.end;
        const start_byte = lsp.Document.posToIdx(doc.text, start_pos).?;
        const old_end_byte = lsp.Document.posToIdx(doc.text, old_end_pos).?;
        const new_end_byte = start_byte + c.text.len;
        const new_end_pos = lsp.Document.idxToPos(doc.text, new_end_byte).?;
        const start_point = posToPoint(start_pos);
        const old_end_point = posToPoint(old_end_pos);
        const new_end_point = posToPoint(new_end_pos);

        p.context.state.?.tree.edit(.{
            .start_byte = @intCast(start_byte),
            .old_end_byte = @intCast(old_end_byte),
            .new_end_byte = @intCast(new_end_byte),
            .start_point = start_point,
            .old_end_point = old_end_point,
            .new_end_point = new_end_point,
        });

        p.context.state.?.tree = p.context.state.?.parser.parseString(doc.text, p.context.state.?.tree).?;
    }
}

fn posToPoint(p: lsp.types.Position) ts.Point {
    return .{ .row = @intCast(p.line), .column = @intCast(p.character) };
}

fn handleSave(p: Lsp.SaveDocumentParameters) Lsp.SaveDocumentReturn {
    sendDiagnostics(p.arena, p.context);
}

fn sendDiagnostics(arena: std.mem.Allocator, c: *Lsp.Context) void {
    const doc = c.document;

    var tests = testNames(arena, c.state.?, c.document);

    var diagnostics = std.ArrayList(lsp.types.Diagnostic).init(arena);

    const file = uriToFilename(c.document.uri);
    c.state.?.language.runTests(arena, file, &tests);

    for (tests) |t| {
        const start = lsp.Document.idxToPos(doc.text, t.start_idx).?;
        const end = lsp.Document.idxToPos(doc.text, t.end_idx).?;
        const message = if (t.pass) "Test pased" else (t.output orelse "Test failed");
        const severity: i32 = if (t.pass) 3 else 1;

        diagnostics.append(.{
            .message = message,
            .range = .{
                .start = start,
                .end = end,
            },
            .severity = severity,
            .source = "assay",
        }) catch unreachable;
    }

    const d = lsp.types.Notification.PublishDiagnostics{ .params = .{
        .uri = doc.uri,
        .diagnostics = diagnostics.items,
    } };
    server.writeResponse(arena, d) catch unreachable;
}

fn uriToFilename(uri: []const u8) []const u8 {
    const prefix = "file://";
    std.debug.assert(std.mem.startsWith(u8, uri, prefix));
    return uri[prefix.len..];
}

fn testNames(arena: std.mem.Allocator, state: State, doc: lsp.Document) []TestData {
    const node = state.tree.rootNode();

    const query = state.language.tsQuery();
    defer query.destroy();

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(query, node);

    var tests = std.ArrayList(TestData).init(arena);
    errdefer tests.deinit();

    while (cursor.nextMatch()) |match| {
        const capture = match.captures[0].node;
        const start = capture.startByte();
        const end = capture.endByte();
        tests.append(.{ .name = doc.text[start..end], .start_idx = start, .end_idx = end }) catch unreachable;
    }
    return tests.items;
}
