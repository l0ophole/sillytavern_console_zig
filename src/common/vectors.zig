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

test "cosine" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), cosine(&[_]f64{ 1, 0 }, &[_]f64{ 1, 0 }), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cosine(&[_]f64{ 1, 0 }, &[_]f64{ 0, 1 }), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), cosine(&[_]f64{ 1, 0 }, &[_]f64{ -1, 0 }), 1e-9);
    try std.testing.expectEqual(@as(f64, 0), cosine(&[_]f64{}, &[_]f64{}));
}
