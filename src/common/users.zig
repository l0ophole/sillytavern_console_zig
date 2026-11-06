const std = @import("std");

pub fn hashPassword(alloc: std.mem.Allocator, password: []const u8) ![]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(password, &hash, .{});
    return std.fmt.allocPrint(alloc, "{x}", .{hash});
}

pub fn verifyPassword(alloc: std.mem.Allocator, password: []const u8, expected_hex: []const u8) !bool {
    const h = try hashPassword(alloc, password);
    defer alloc.free(h);
    return std.mem.eql(u8, h, expected_hex);
}

test "hash/verify" {
    const alloc = std.testing.allocator;
    const h = try hashPassword(alloc, "secret");
    defer alloc.free(h);
    try std.testing.expectEqual(@as(usize, 64), h.len);
    try std.testing.expect(try verifyPassword(alloc, "secret", h));
    try std.testing.expect(!(try verifyPassword(alloc, "wrong", h)));
}
