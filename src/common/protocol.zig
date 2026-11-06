const std = @import("std");

pub const VERSION = "0.1.0";
pub const API_VERSION: u32 = 1; // versioned JSON API: requests may carry "version", responses always include it
pub const MAX_LINE: usize = 16 << 20; // 16 MiB (long chats exceed 1 MiB)

pub const Request = struct {
    method: []const u8,
    params: ?std.json.Value = null,
    version: u32 = API_VERSION,
};

pub fn parseRequest(alloc: std.mem.Allocator, line: []const u8) !Request {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyRequest;
    const v = try std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{});
    // Caller owns arena; v.value is heap-allocated via alloc.
    const obj = switch (v.value) {
        .object => |o| o,
        else => return error.BadRequest,
    };
    const method_v = obj.get("method") orelse return error.BadRequest;
    const method = switch (method_v) {
        .string => |s| s,
        else => return error.BadRequest,
    };
    if (method.len == 0 or method.len > 128) return error.BadRequest;
    var version: u32 = API_VERSION;
    if (obj.get("version")) |vv| {
        if (vv == .integer) {
            if (vv.integer != API_VERSION) return error.UnsupportedVersion;
            version = API_VERSION;
        } else return error.BadRequest;
    }
    return .{ .method = method, .params = obj.get("params"), .version = version };
}

pub fn isSafeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return false;
    return true;
}

pub fn jsonQuote(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    const hex = try std.fmt.allocPrint(alloc, "\\u{x:0>4}", .{c});
                    defer alloc.free(hex);
                    try out.appendSlice(alloc, hex);
                } else {
                    try out.append(alloc, c);
                }
            },
        }
    }
    try out.append(alloc, '"');
    return out.toOwnedSlice(alloc);
}

pub fn encodeOk(alloc: std.mem.Allocator, result_json: []const u8) ![]u8 {
    // result_json is raw JSON text (or "null").
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"ok\":true,\"version\":1,\"result\":");
    try out.appendSlice(alloc, result_json);
    try out.appendSlice(alloc, "}\n");
    return out.toOwnedSlice(alloc);
}

pub fn encodeErr(alloc: std.mem.Allocator, msg: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"ok\":false,\"version\":1,\"error\":");
    try out.append(alloc, '"');
    for (msg) |c| {
        if (c == '"' or c == '\\') try out.append(alloc, '\\');
        try out.append(alloc, c);
    }
    try out.append(alloc, '"');
    try out.appendSlice(alloc, "}\n");
    return out.toOwnedSlice(alloc);
}

test "parse ping request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "{\"method\":\"ping\",\"params\":{}}\n");
    try std.testing.expectEqualStrings("ping", req.method);
}

test "reject empty and bad" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.EmptyRequest, parseRequest(arena.allocator(), "  \n"));
    try std.testing.expectError(error.BadRequest, parseRequest(arena.allocator(), "{\"params\":{}}"));
    try std.testing.expectError(error.BadRequest, parseRequest(arena.allocator(), "[]"));
}

test "encode ok/err" {
    const alloc = std.testing.allocator;
    const ok = try encodeOk(alloc, "{\"pong\":true}");
    defer alloc.free(ok);
    try std.testing.expect(std.mem.indexOf(u8, ok, "\"ok\":true") != null);
    const err = try encodeErr(alloc, "bad_request");
    defer alloc.free(err);
    try std.testing.expect(std.mem.indexOf(u8, err, "\"ok\":false") != null);
}

test "jsonQuote escapes" {
    const alloc = std.testing.allocator;
    const q = try jsonQuote(alloc, "a\"b\nc");
    defer alloc.free(q);
    try std.testing.expectEqualStrings("\"a\\\"b\\nc\"", q);
}

test "safe name rejects traversal" {
    try std.testing.expect(isSafeName("Alice"));
    try std.testing.expect(!isSafeName("../etc/passwd"));
    try std.testing.expect(!isSafeName("a/b"));
    try std.testing.expect(!isSafeName(".."));
    try std.testing.expect(!isSafeName(""));
}
