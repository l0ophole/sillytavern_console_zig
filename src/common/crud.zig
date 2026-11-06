const std = @import("std");
const protocol = @import("common");
const store = @import("store");

pub fn listNames(alloc: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return out.toOwnedSlice(alloc);
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const name = try alloc.dupe(u8, entry.name);
        try out.append(alloc, name);
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

pub fn jsonArrayOfNames(alloc: std.mem.Allocator, names: [][]u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try out.append(alloc, '[');
    for (names, 0..) |n, idx| {
        if (idx > 0) try out.append(alloc, ',');
        try out.append(alloc, '"');
        for (n) |c| {
            if (c == '"' or c == '\\') try out.append(alloc, '\\');
            try out.append(alloc, c);
        }
        try out.append(alloc, '"');
    }
    try out.append(alloc, ']');
    return out.toOwnedSlice(alloc);
}

pub fn saveJson(alloc: std.mem.Allocator, dir_path: []const u8, name: []const u8, value: std.json.Value) !void {
    if (!protocol.isSafeName(name)) return error.BadName;
    const fname = try std.fmt.allocPrint(alloc, "{s}.json", .{name});
    defer alloc.free(fname);
    const path = try std.fs.path.join(alloc, &.{ dir_path, fname });
    defer alloc.free(path);
    const s = try store.stringifyValue(alloc, value);
    defer alloc.free(s);
    try store.writeAtomic(path, s);
}

pub fn loadFile(alloc: std.mem.Allocator, dir_path: []const u8, name: []const u8) ![]u8 {
    // name may include extension
    if (!protocol.isSafeName(name)) return error.BadName;
    const path = try std.fs.path.join(alloc, &.{ dir_path, name });
    defer alloc.free(path);
    return store.readFileAlloc(alloc, path);
}

pub fn deleteFile(alloc: std.mem.Allocator, dir_path: []const u8, name: []const u8) !void {
    if (!protocol.isSafeName(name)) return error.BadName;
    const path = try std.fs.path.join(alloc, &.{ dir_path, name });
    defer alloc.free(path);
    try std.fs.cwd().deleteFile(path);
}

test "jsonArrayOfNames" {
    const alloc = std.testing.allocator;
    var names = [_][]u8{ try alloc.dupe(u8, "b.json"), try alloc.dupe(u8, "a.json") };
    const s = try jsonArrayOfNames(alloc, &names);
    defer alloc.free(s);
    for (names) |n| alloc.free(n);
    try std.testing.expectEqualStrings("[\"b.json\",\"a.json\"]", s);
}
