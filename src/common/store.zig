const std = @import("std");
const protocol = @import("common");

pub fn userDir(alloc: std.mem.Allocator, data_root: []const u8, user: []const u8) ![]u8 {
    if (!protocol.isSafeName(user)) return error.BadName;
    return std.fs.path.join(alloc, &.{ data_root, user });
}

pub fn ensureUserDirs(dir_path: []const u8) !void {
    const cwd = std.fs.cwd();
    try cwd.makePath(dir_path);
    const subs = [_][]const u8{ "characters", "chats", "presets", "worldinfo", "groups", "themes", "backups", "backgrounds", "avatars" };
    for (subs) |s| {
        const p = try std.fs.path.join(std.heap.page_allocator, &.{ dir_path, s });
        defer std.heap.page_allocator.free(p);
        try cwd.makePath(p);
    }
}

pub fn writeAtomic(path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.tmp", .{path});
    defer std.heap.page_allocator.free(tmp);
    const f = try std.fs.cwd().createFile(tmp, .{});
    defer f.close();
    try f.writeAll(data);
    try std.fs.cwd().rename(tmp, path);
}

pub fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    return f.readToEndAlloc(alloc, protocol.MAX_LINE * 4);
}

pub fn stringifyValue(alloc: std.mem.Allocator, v: std.json.Value) ![]u8 {
    var out: std.io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.write(v);
    return alloc.dupe(u8, out.written());
}

test "stringify round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"a\":1,\"b\":\"x\"}", .{});
    const s = try stringifyValue(alloc, parsed.value);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"a\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"b\":\"x\"") != null);
}

test "userDir rejects traversal" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.BadName, userDir(alloc, "data", "../evil"));
    const d = try userDir(alloc, "data", "default-user");
    defer alloc.free(d);
    try std.testing.expectEqualStrings("data/default-user", d);
}
