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
    fn init(uri: []const u8, content: []const u8) ?Self {
        const language = Language.init(uri) orelse return null;
        const parser = ts.Parser.create();
        parser.setLanguage(language.tsLanguage()) catch unreachable;
        const tree = parser.parseString(content, null) orelse unreachable;
        return State{
            .language = language,
            .parser = parser,
            .tree = tree,
        };
    }

    fn parse(self: *Self, content: []const u8) void {
        self.tree = self.parser.parseString(content, null) orelse unreachable;
    }

    fn deinit(self: Self) void {
        self.tree.destroy();
        const language = self.parser.getLanguage().?;
        self.parser.destroy();
        language.destroy();
    }
};
const Lsp = lsp.Lsp(.{
    .state_type = State,
    .document_sync = .None,
    .full_text_on_save = true,
});

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
const allocator = debug_allocator.allocator();

var server: Lsp = undefined;
pub fn main() !u8 {
    const server_info = lsp.types.ServerInfo{ .name = "assay", .version = "0.1.0" };
    server = Lsp.init(allocator, server_info);

    server.registerDocOpenCallback(handleOpenDoc);
    server.registerDocCloseCallback(handleCloseDoc);
    server.registerDocSaveCallback(handleSave);

    const res = server.start();

    return res;
}

fn handleOpenDoc(p: Lsp.OpenDocumentParameters) void {
    p.context.state = State.init(p.context.document.uri, p.context.document.text) orelse return;
    sendDiagnostics(p.arena, p.context.state.?, p.context.document);
}

fn handleCloseDoc(p: Lsp.CloseDocumentParameters) void {
    const state = p.context.state orelse return;
    state.deinit();
}

fn posToPoint(p: lsp.types.Position) ts.Point {
    return .{ .row = @intCast(p.line), .column = @intCast(p.character) };
}

fn handleSave(p: Lsp.SaveDocumentParameters) void {
    var state = p.context.state orelse return;
    state.parse(p.context.document.text);
    sendDiagnostics(p.arena, state, p.context.document);
}

fn sendDiagnostics(arena: std.mem.Allocator, state: State, doc: lsp.Document) void {
    var tests = testNames(arena, state, doc);
    if (tests.len == 0) return;

    var diagnostics = std.ArrayList(lsp.types.Diagnostic).init(arena);

    const file = uriToFilename(doc.uri);
    state.language.runTests(arena, file, &tests);

    for (tests) |t| {
        const start = lsp.Document.idxToPos(doc.text, t.start_idx).?;
        const end = lsp.Document.idxToPos(doc.text, t.end_idx).?;
        const message = if (t.pass) "Test pased" else (t.output orelse "Test failed");
        const severity: lsp.types.DiagnosticSeverity = if (t.pass) .Information else .Error;

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
