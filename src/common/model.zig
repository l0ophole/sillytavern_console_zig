const std = @import("std");

pub const MlpModel = struct {
    input_dim: usize,
    hidden_dim: usize,
    output_dim: usize,
    w1: []f64, // hidden x input, row-major
    b1: []f64,
    w2: []f64, // output x hidden
    b2: []f64,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *MlpModel) void {
        self.alloc.free(self.w1);
        self.alloc.free(self.b1);
        self.alloc.free(self.w2);
        self.alloc.free(self.b2);
    }

    pub fn forward(self: *MlpModel, alloc: std.mem.Allocator, input: []const f64) ![]f64 {
        if (input.len != self.input_dim) return error.BadInputDim;
        var hidden = try alloc.alloc(f64, self.hidden_dim);
        defer alloc.free(hidden);
        for (0..self.hidden_dim) |h| {
            var sum = self.b1[h];
            for (0..self.input_dim) |i| {
                sum += self.w1[h * self.input_dim + i] * input[i];
            }
            hidden[h] = std.math.tanh(sum);
        }
        var out = try alloc.alloc(f64, self.output_dim);
        for (0..self.output_dim) |o| {
            var sum = self.b2[o];
            for (0..self.hidden_dim) |h| {
                sum += self.w2[o * self.hidden_dim + h] * hidden[h];
            }
            out[o] = sum;
        }
        return out;
    }
};

fn parseF64Array(alloc: std.mem.Allocator, v: std.json.Value) ![]f64 {
    if (v != .array) return error.BadModel;
    const out = try alloc.alloc(f64, v.array.items.len);
    for (v.array.items, 0..) |item, i| {
        out[i] = switch (item) {
            .integer => @as(f64, @floatFromInt(item.integer)),
            .float => item.float,
            else => return error.BadModel,
        };
    }
    return out;
}

pub fn loadModel(alloc: std.mem.Allocator, path: []const u8) !MlpModel {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const content = try f.readToEndAlloc(alloc, 10 << 20);
    defer alloc.free(content);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    if (parsed.value != .object) return error.BadModel;
    const obj = parsed.value.object;
    const input_dim: usize = @intCast((obj.get("input_dim") orelse return error.BadModel).integer);
    const hidden_dim: usize = @intCast((obj.get("hidden_dim") orelse return error.BadModel).integer);
    const output_dim: usize = @intCast((obj.get("output_dim") orelse return error.BadModel).integer);
    const w1 = try parseF64Array(alloc, obj.get("W1") orelse return error.BadModel);
    const b1 = try parseF64Array(alloc, obj.get("b1") orelse return error.BadModel);
    const w2 = try parseF64Array(alloc, obj.get("W2") orelse return error.BadModel);
    const b2 = try parseF64Array(alloc, obj.get("b2") orelse return error.BadModel);
    if (w1.len != hidden_dim * input_dim or b1.len != hidden_dim or w2.len != output_dim * hidden_dim or b2.len != output_dim) return error.BadModel;
    return .{ .input_dim = input_dim, .hidden_dim = hidden_dim, .output_dim = output_dim, .w1 = w1, .b1 = b1, .w2 = w2, .b2 = b2, .alloc = alloc };
}

test "mlp forward identity-ish" {
    const alloc = std.testing.allocator;
    var m = MlpModel{
        .input_dim = 2, .hidden_dim = 2, .output_dim = 2,
        .w1 = try alloc.dupe(f64, &[_]f64{ 1, 0, 0, 1 }),
        .b1 = try alloc.dupe(f64, &[_]f64{ 0, 0 }),
        .w2 = try alloc.dupe(f64, &[_]f64{ 1, 0, 0, 1 }),
        .b2 = try alloc.dupe(f64, &[_]f64{ 0, 0 }),
        .alloc = alloc,
    };
    defer m.deinit();
    const out = try m.forward(alloc, &[_]f64{ 0.5, -0.5 });
    defer alloc.free(out);
    // tanh(0.5)=0.462..., tanh(-0.5)=-0.462...
    try std.testing.expectApproxEqAbs(@as(f64, 0.462117), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f64, -0.462117), out[1], 1e-5);
}
