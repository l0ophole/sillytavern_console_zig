const std = @import("std");

pub fn cosine(a: []const f64, b: []const f64) f64 {
    if (a.len == 0 or a.len != b.len) return 0;
    var dot: f64 = 0;
    var na: f64 = 0;
    var nb: f64 = 0;
    for (a, b) |x, y| {
        dot += x * y;
        na += x * x;
        nb += y * y;
    }
    if (na == 0 or nb == 0) return 0;
    return dot / (@sqrt(na) * @sqrt(nb));
}

/// Deterministic local embedding (hash-based, NOT a neural model).
/// Same text -> same vector; dim defaults to 32.
pub fn localEmbed(alloc: std.mem.Allocator, text: []const u8, dim: usize) ![]f64 {
    const d = if (dim == 0) @as(usize, 32) else dim;
    const out = try alloc.alloc(f64, d);
    var counter: u32 = 0;
    var idx: usize = 0;
    while (idx < d) {
        var h: [32]u8 = undefined;
        var buf: [256]u8 = undefined;
        const n = std.fmt.bufPrint(&buf, "{s}:{d}", .{ text, counter }) catch text;
        std.crypto.hash.sha2.Sha256.hash(n, &h, .{});
        for (h) |byte| {
            if (idx >= d) break;
            // Map byte [0,255] -> [-1,1]
            out[idx] = (@as(f64, @floatFromInt(byte)) / 127.5) - 1.0;
            idx += 1;
        }
        counter += 1;
    }
    return out;
}

test "localEmbed deterministic" {
    const alloc = std.testing.allocator;
    const a = try localEmbed(alloc, "hello", 8);
    defer alloc.free(a);
    const b = try localEmbed(alloc, "hello", 8);
    defer alloc.free(b);
    try std.testing.expectEqualSlices(f64, a, b);
    const c = try localEmbed(alloc, "world", 8);
    defer alloc.free(c);
    try std.testing.expect(!std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(c)));
}

test "cosine" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), cosine(&[_]f64{ 1, 0 }, &[_]f64{ 1, 0 }), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cosine(&[_]f64{ 1, 0 }, &[_]f64{ 0, 1 }), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), cosine(&[_]f64{ 1, 0 }, &[_]f64{ -1, 0 }), 1e-9);
    try std.testing.expectEqual(@as(f64, 0), cosine(&[_]f64{}, &[_]f64{}));
}
