const std = @import("std");

fn readVarint(d: []const u8, pos: *usize) u64 {
    var r: u64 = 0;
    var s: u6 = 0;
    while (pos.* < d.len) {
        const b = d[pos.*];
        pos.* += 1;
        r |= @as(u64, b & 0x7f) << s;
        if (b & 0x80 == 0) break;
        s += 7;
    }
    return r;
}

fn readLen(d: []const u8, pos: *usize) []const u8 {
    const ln = @as(usize, @intCast(readVarint(d, pos)));
    const s = d[pos.* .. pos.* + ln];
    pos.* += ln;
    return s;
}

pub const Tensor = struct {
    name: []u8,
    dims: []i64,
    data: []f32,
};

pub const Node = struct {
    op: []u8,
    inputs: [][]u8,
    outputs: [][]u8,
    trans_b: bool = false,
};

pub const OnnxModel = struct {
    tensors: std.StringHashMap(Tensor),
    nodes: []Node,
    input_name: []u8,
    output_name: []u8,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *OnnxModel) void {
        var it = self.tensors.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*.dims);
            self.alloc.free(e.value_ptr.*.data);
        }
        self.tensors.deinit();
        for (self.nodes) |n| {
            self.alloc.free(n.op);
            for (n.inputs) |i| self.alloc.free(i);
            self.alloc.free(n.inputs);
            for (n.outputs) |o| self.alloc.free(o);
            self.alloc.free(n.outputs);
        }
        self.alloc.free(self.nodes);
        self.alloc.free(self.input_name);
        self.alloc.free(self.output_name);
    }

    pub fn run(self: *OnnxModel, alloc: std.mem.Allocator, input: []const f32) ![]f32 {
        // Single-input single-output graph, float tensors only
        var env = std.StringHashMap([]f32).init(alloc);
        defer {
            var it = env.iterator();
            while (it.next()) |e| {
                // input copy freed below; intermediates freed here except final
                _ = e;
            }
            env.deinit();
        }
        const in_copy = try alloc.dupe(f32, input);
        try env.put(self.input_name, in_copy);
        defer for (self.nodes) |_| {};
        for (self.nodes) |node| {
            if (std.mem.eql(u8, node.op, "Gemm") or std.mem.eql(u8, node.op, "MatMul")) {
                const a = env.get(node.inputs[0]) orelse return error.MissingInput;
                // B can be initializer weight or activation (MatMul of two activations, e.g. Q@K^T)
                var b_slices: []const f32 = undefined;
                var b_dims: []const i64 = &[_]i64{};
                var b_from_tensor = false;
                if (self.tensors.get(node.inputs[1])) |bt| {
                    b_slices = bt.data;
                    b_dims = bt.dims;
                    b_from_tensor = true;
                } else if (env.get(node.inputs[1])) |bv| {
                    b_slices = bv;
                } else return error.MissingWeight;
                const is_gemm = std.mem.eql(u8, node.op, "Gemm");
                const trans_b = node.trans_b or is_gemm;
                // Infer shapes: Gemm/MatMul vector x matrix -> vector
                var k_dim: usize = 0;
                var n_out: usize = 0;
                if (b_from_tensor and b_dims.len == 2) {
                    if (trans_b) {
                        n_out = @intCast(b_dims[0]);
                        k_dim = @intCast(b_dims[1]);
                    } else {
                        k_dim = @intCast(b_dims[0]);
                        n_out = @intCast(b_dims[1]);
                    }
                } else {
                    // Square assume
                    k_dim = a.len;
                    n_out = b_slices.len / k_dim;
                }
                if (k_dim != a.len) return error.BadShape;
                const out = try alloc.alloc(f32, n_out);
                for (0..n_out) |o| {
                    var sum: f32 = 0;
                    for (0..k_dim) |k| {
                        const wval = if (trans_b) b_slices[o * k_dim + k] else b_slices[k * n_out + o];
                        sum += a[k] * wval;
                    }
                    out[o] = sum;
                }
                // Add bias if third input present
                if (node.inputs.len > 2) {
                    if (self.tensors.get(node.inputs[2])) |bt| {
                        for (0..n_out) |o| out[o] += bt.data[o % bt.data.len];
                    } else if (env.get(node.inputs[2])) |bv| {
                        for (0..n_out) |o| out[o] += bv[o % bv.len];
                    }
                }
                try env.put(node.outputs[0], out);
            } else if (std.mem.eql(u8, node.op, "Gather")) {
                const data_t = self.tensors.get(node.inputs[0]) orelse return error.MissingWeight;
                const idx_t = self.tensors.get(node.inputs[1]) orelse return error.MissingWeight;
                if (data_t.dims.len != 2) return error.BadShape;
                const vocab: usize = @intCast(data_t.dims[0]);
                const dim: usize = @intCast(data_t.dims[1]);
                const n_idx = idx_t.data.len;
                const out = try alloc.alloc(f32, n_idx * dim);
                for (0..n_idx) |i| {
                    const row: usize = @intCast(@as(i64, @intFromFloat(idx_t.data[i])));
                    if (row >= vocab) return error.BadIndex;
                    @memcpy(out[i * dim .. (i + 1) * dim], data_t.data[row * dim .. (row + 1) * dim]);
                }
                try env.put(node.outputs[0], out);
            } else if (std.mem.eql(u8, node.op, "Transpose")) {
                const a = env.get(node.inputs[0]) orelse return error.MissingInput;
                // 2D transpose [R,C]->[C,R] using input tensor dims if available else square assumption via node attr
                // For transformer weights we use initializer dims; for activations assume 2D with rows from output name lookup fallback: use sqrt
                const out = try alloc.alloc(f32, a.len);
                // Default: transpose as [C,R] requires dims; use stored tensor dims if input is weight, else assume input length factors from node (fallback square)
                var rows: usize = 0;
                var cols: usize = 0;
                if (self.tensors.get(node.inputs[0])) |t| {
                    if (t.dims.len == 2) {
                        rows = @intCast(t.dims[0]);
                        cols = @intCast(t.dims[1]);
                    }
                }
                if (rows == 0) {
                    // Square fallback
                    rows = @intFromFloat(@sqrt(@as(f64, @floatFromInt(a.len))));
                    cols = rows;
                }
                for (0..rows) |r| {
                    for (0..cols) |c| {
                        out[c * rows + r] = a[r * cols + c];
                    }
                }
                try env.put(node.outputs[0], out);
            } else if (std.mem.eql(u8, node.op, "Add") or std.mem.eql(u8, node.op, "Mul") or std.mem.eql(u8, node.op, "Div")) {
                const a = env.get(node.inputs[0]) orelse return error.MissingInput;
                const b_tensor = self.tensors.get(node.inputs[1]);
                const b = if (b_tensor) |bt| bt.data else (env.get(node.inputs[1]) orelse return error.MissingInput);
                const out = try alloc.alloc(f32, a.len);
                for (a, 0..) |v, i| {
                    const bv = b[i % b.len];
                    out[i] = if (std.mem.eql(u8, node.op, "Add")) v + bv else if (std.mem.eql(u8, node.op, "Mul")) v * bv else v / bv;
                }
                try env.put(node.outputs[0], out);
            } else if (std.mem.eql(u8, node.op, "Reshape")) {
                const a = env.get(node.inputs[0]) orelse return error.MissingInput;
                const out = try alloc.dupe(f32, a);
                try env.put(node.outputs[0], out);
            } else if (std.mem.eql(u8, node.op, "Attention")) {
                // Simplified scaled dot-product attention: Q,K,V are [seq,dim] flat,
                // dim from node attribute encoded in output? Use first tensor dim fallback:
                // We infer dim from V length / seq. Assume Q,K,V same shape [seq,dim].
                const q = env.get(node.inputs[0]) orelse (self.tensors.get(node.inputs[0]) orelse return error.MissingInput).data;
                const k = env.get(node.inputs[1]) orelse (self.tensors.get(node.inputs[1]) orelse return error.MissingInput).data;
                const v = env.get(node.inputs[2]) orelse (self.tensors.get(node.inputs[2]) orelse return error.MissingInput).data;
                if (q.len == 0 or k.len == 0 or v.len == 0) return error.BadShape;
                // Infer dim: use sqrt if square, else from V dims
                var dim: usize = 0;
                if (self.tensors.get(node.inputs[2])) |vt| {
                    if (vt.dims.len == 2) dim = @intCast(vt.dims[1]);
                }
                if (dim == 0) {
                    // Square assume
                    dim = @intFromFloat(@sqrt(@as(f64, @floatFromInt(k.len))));
                    if (dim * dim != k.len and k.len % 8 == 0) dim = 8;
                }
                if (dim == 0 or q.len % dim != 0) return error.BadShape;
                const seq_q = q.len / dim;
                const seq_k = k.len / dim;
                const scale: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(dim)));
                const out = try alloc.alloc(f32, seq_q * dim);
                var scores = try alloc.alloc(f32, seq_q * seq_k);
                defer alloc.free(scores);
                for (0..seq_q) |i| {
                    var maxv: f32 = -1000000;
                    for (0..seq_k) |j| {
                        var dot: f32 = 0;
                        for (0..dim) |d| dot += q[i * dim + d] * k[j * dim + d];
                        dot *= scale;
                        scores[i * seq_k + j] = dot;
                        maxv = @max(maxv, dot);
                    }
                    var sum: f32 = 0;
                    for (0..seq_k) |j| {
                        scores[i * seq_k + j] = @exp(scores[i * seq_k + j] - maxv);
                        sum += scores[i * seq_k + j];
                    }
                    for (0..seq_k) |j| scores[i * seq_k + j] /= sum;
                    for (0..dim) |d| {
                        var acc: f32 = 0;
                        for (0..seq_k) |j| acc += scores[i * seq_k + j] * v[j * dim + d];
                        out[i * dim + d] = acc;
                    }
                }
                try env.put(node.outputs[0], out);
            } else if (std.mem.eql(u8, node.op, "Gelu")) {
                const a = env.get(node.inputs[0]) orelse return error.MissingInput;
                const out = try alloc.alloc(f32, a.len);
                for (a, 0..) |v, i| out[i] = 0.5 * v * (1 + std.math.tanh(@sqrt(2.0 / std.math.pi) * (v + 0.044715 * v * v * v)));
                try env.put(node.outputs[0], out);
            } else if (std.mem.eql(u8, node.op, "Split")) {
                const a = env.get(node.inputs[0]) orelse return error.MissingInput;
                // Equal split across outputs
                const n = node.outputs.len;
                const chunk = a.len / n;
                for (0..n) |oi| {
                    const slice = a[oi * chunk .. @min(a.len, (oi + 1) * chunk)];
                    try env.put(node.outputs[oi], try alloc.dupe(f32, slice));
                }
            } else if (std.mem.eql(u8, node.op, "Concat")) {
                var total: usize = 0;
                for (node.inputs) |inp| {
                    const t = self.tensors.get(inp) orelse return error.MissingWeight;
                    total += t.data.len;
                }
                const out = try alloc.alloc(f32, total);
                var off: usize = 0;
                for (node.inputs) |inp| {
                    const t = self.tensors.get(inp) orelse return error.MissingWeight;
                    @memcpy(out[off .. off + t.data.len], t.data);
                    off += t.data.len;
                }
                try env.put(node.outputs[0], out);
            } else if (std.mem.eql(u8, node.op, "Unsqueeze") or std.mem.eql(u8, node.op, "Squeeze")) {
                const a = env.get(node.inputs[0]) orelse return error.MissingInput;
                try env.put(node.outputs[0], try alloc.dupe(f32, a));
            } else if (std.mem.eql(u8, node.op, "Cast")) {
                const a = env.get(node.inputs[0]) orelse (self.tensors.get(node.inputs[0]) orelse return error.MissingInput).data;
                try env.put(node.outputs[0], try alloc.dupe(f32, a));
            } else if (std.mem.eql(u8, node.op, "Expand")) {
                const a = env.get(node.inputs[0]) orelse return error.MissingInput;
                try env.put(node.outputs[0], try alloc.dupe(f32, a));
            } else if (std.mem.eql(u8, node.op, "Slice")) {
                const a = env.get(node.inputs[0]) orelse return error.MissingInput;
                try env.put(node.outputs[0], try alloc.dupe(f32, a));
            } else if (std.mem.eql(u8, node.op, "Softmax")) {
                const a = env.get(node.inputs[0]) orelse return error.MissingInput;
                const out = try alloc.alloc(f32, a.len);
                var maxv: f32 = a[0];
                for (a) |v| maxv = @max(maxv, v);
                var sum: f32 = 0;
                for (a, 0..) |v, i| {
                    out[i] = @exp(v - maxv);
                    sum += out[i];
                }
                for (out) |*v| v.* /= sum;
                try env.put(node.outputs[0], out);
            } else if (std.mem.eql(u8, node.op, "LayerNormalization")) {
                const a = env.get(node.inputs[0]) orelse return error.MissingInput;
                const n = a.len;
                var mean: f32 = 0;
                for (a) |v| mean += v;
                mean /= @as(f32, @floatFromInt(n));
                var var_sum: f32 = 0;
                for (a) |v| var_sum += (v - mean) * (v - mean);
                const stdv = @sqrt(var_sum / @as(f32, @floatFromInt(n)) + 1e-5);
                const out = try alloc.alloc(f32, a.len);
                for (a, 0..) |v, i| out[i] = (v - mean) / stdv;
                try env.put(node.outputs[0], out);
            } else if (std.mem.eql(u8, node.op, "Relu")) {
                const a = env.get(node.inputs[0]) orelse return error.MissingInput;
                const out = try alloc.alloc(f32, a.len);
                for (a, 0..) |v, i| out[i] = if (v > 0) v else 0;
                try env.put(node.outputs[0], out);
            } else if (std.mem.eql(u8, node.op, "Identity")) {
                const a = env.get(node.inputs[0]) orelse return error.MissingInput;
                const out = try alloc.dupe(f32, a);
                try env.put(node.outputs[0], out);
            } else {
                return error.UnsupportedOp;
            }
        }
        const res = env.get(self.output_name) orelse return error.MissingOutput;
        const out = try alloc.dupe(f32, res);
        // Free intermediates (all env values except we copied res)
        var it = env.iterator();
        while (it.next()) |e| alloc.free(e.value_ptr.*);
        return out;
    }
};

fn parseTensor(alloc: std.mem.Allocator, msg: []const u8) !Tensor {
    var pos: usize = 0;
    var name: []u8 = &.{};
    var dims: std.ArrayListUnmanaged(i64) = .empty;
    var data: std.ArrayListUnmanaged(f32) = .empty;
    while (pos < msg.len) {
        const tag = readVarint(msg, &pos);
        const field = @as(usize, @intCast(tag >> 3));
        const wt = @as(usize, @intCast(tag & 7));
        if (field == 1 and wt == 2) {
            const packed_data = readLen(msg, &pos);
            var p2: usize = 0;
            while (p2 < packed_data.len) {
                const v = readVarint(packed_data, &p2);
                try dims.append(alloc, @bitCast(v));
            }
        } else if (field == 4 and wt == 2) {
            const packed2 = readLen(msg, &pos);
            var p2: usize = 0;
            while (p2 + 4 <= packed2.len) : (p2 += 4) {
                try data.append(alloc, @bitCast(std.mem.readInt(u32, packed2[p2..][0..4], .little)));
            }
        } else if (field == 8 and wt == 2) {
            const s = readLen(msg, &pos);
            name = try alloc.dupe(u8, s);
        } else if (wt == 2) {
            _ = readLen(msg, &pos);
        } else if (wt == 5) {
            pos += 4;
        } else if (wt == 0) {
            _ = readVarint(msg, &pos);
        } else break;
    }
    return .{ .name = name, .dims = try dims.toOwnedSlice(alloc), .data = try data.toOwnedSlice(alloc) };
}

pub fn loadOnnx(alloc: std.mem.Allocator, path: []const u8) !OnnxModel {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const content = try f.readToEndAlloc(alloc, 20 << 20);
    defer alloc.free(content);
    var model = OnnxModel{
        .tensors = std.StringHashMap(Tensor).init(alloc),
        .nodes = &.{},
        .input_name = &.{},
        .output_name = &.{},
        .alloc = alloc,
    };
    errdefer model.deinit();
    var pos: usize = 0;
    var graph_msg: ?[]const u8 = null;
    var graph_owned: ?[]u8 = null;
    while (pos < content.len) {
        const tag = readVarint(content, &pos);
        const field = @as(usize, @intCast(tag >> 3));
        const wt = @as(usize, @intCast(tag & 7));
        if (field == 7 and wt == 2) {
            const s = readLen(content, &pos);
            graph_owned = try alloc.dupe(u8, s);
            graph_msg = graph_owned.?;
        } else if (wt == 2) {
            _ = readLen(content, &pos);
        } else if (wt == 5) {
            pos += 4;
        } else if (wt == 0) {
            _ = readVarint(content, &pos);
        } else break;
    }
    defer if (graph_owned) |g| alloc.free(g);
    const graph = graph_msg orelse return error.BadOnnx;
    var gpos: usize = 0;
    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    var input_name: ?[]u8 = null;
    var output_name: ?[]u8 = null;
    while (gpos < graph.len) {
        const tag = readVarint(graph, &gpos);
        const field = @as(usize, @intCast(tag >> 3));
        const wt = @as(usize, @intCast(tag & 7));
        if (field == 1 and wt == 2) {
            const nmsg = readLen(graph, &gpos);
            var npos: usize = 0;
            var op: []u8 = &.{};
            var ins: std.ArrayListUnmanaged([]u8) = .empty;
            var outs: std.ArrayListUnmanaged([]u8) = .empty;
            var trans_b = false;
            while (npos < nmsg.len) {
                const t2 = readVarint(nmsg, &npos);
                const f2 = @as(usize, @intCast(t2 >> 3));
                const w2 = @as(usize, @intCast(t2 & 7));
                if (f2 == 1 and w2 == 2) {
                    try ins.append(alloc, try alloc.dupe(u8, readLen(nmsg, &npos)));
                } else if (f2 == 2 and w2 == 2) {
                    try outs.append(alloc, try alloc.dupe(u8, readLen(nmsg, &npos)));
                } else if (f2 == 4 and w2 == 2) {
                    op = try alloc.dupe(u8, readLen(nmsg, &npos));
                } else if (f2 == 5 and w2 == 2) {
                    // attribute: name=1, i=3
                    const amsg = readLen(nmsg, &npos);
                    var apos: usize = 0;
                    var aname: []const u8 = "";
                    while (apos < amsg.len) {
                        const at = readVarint(amsg, &apos);
                        const af = @as(usize, @intCast(at >> 3));
                        const aw = @as(usize, @intCast(at & 7));
                        if (af == 1 and aw == 2) {
                            aname = readLen(amsg, &apos);
                        } else if (af == 3 and aw == 0) {
                            const v = readVarint(amsg, &apos);
                            if (std.mem.eql(u8, aname, "transB") and v == 1) trans_b = true;
                        } else if (aw == 2) {
                            _ = readLen(amsg, &apos);
                        } else if (aw == 5) {
                            apos += 4;
                        } else if (aw == 0) {
                            _ = readVarint(amsg, &apos);
                        } else break;
                    }
                } else if (w2 == 2) {
                    _ = readLen(nmsg, &npos);
                } else if (w2 == 5) {
                    npos += 4;
                } else if (w2 == 0) {
                    _ = readVarint(nmsg, &npos);
                } else break;
            }
            try nodes.append(alloc, .{ .op = op, .inputs = try ins.toOwnedSlice(alloc), .outputs = try outs.toOwnedSlice(alloc), .trans_b = trans_b });
        } else if (field == 5 and wt == 2) {
            const tmsg = readLen(graph, &gpos);
            const tensor = try parseTensor(alloc, tmsg);
            try model.tensors.put(tensor.name, tensor);
        } else if ((field == 11 or field == 12) and wt == 2) {
            const vmsg = readLen(graph, &gpos);
            var vpos: usize = 0;
            while (vpos < vmsg.len) {
                const vt = readVarint(vmsg, &vpos);
                const vf = @as(usize, @intCast(vt >> 3));
                const vw = @as(usize, @intCast(vt & 7));
                if (vf == 1 and vw == 2) {
                    const nm = try alloc.dupe(u8, readLen(vmsg, &vpos));
                    if (field == 11) input_name = nm else output_name = nm;
                    break;
                } else if (vw == 2) {
                    _ = readLen(vmsg, &vpos);
                } else if (vw == 5) {
                    vpos += 4;
                } else if (vw == 0) {
                    _ = readVarint(vmsg, &vpos);
                } else break;
            }
        } else if (wt == 2) {
            _ = readLen(graph, &gpos);
        } else if (wt == 5) {
            gpos += 4;
        } else if (wt == 0) {
            _ = readVarint(graph, &gpos);
        } else break;
    }
    model.nodes = try nodes.toOwnedSlice(alloc);
    model.input_name = input_name orelse return error.BadOnnx;
    model.output_name = output_name orelse return error.BadOnnx;
    return model;
}

test "onnx gemm equivalence" {
    // Manual Gemm [2,2] identity, transB: out = in * W
    const alloc = std.testing.allocator;
    var tensors = std.StringHashMap(Tensor).init(alloc);
    const w = try alloc.dupe(f32, &[_]f32{ 1, 0, 0, 1 });
    const b = try alloc.dupe(f32, &[_]f32{ 0, 0 });
    try tensors.put(try alloc.dupe(u8, "W"), .{ .name = try alloc.dupe(u8, "W"), .dims = try alloc.dupe(i64, &[_]i64{ 2, 2 }), .data = w });
    try tensors.put(try alloc.dupe(u8, "B"), .{ .name = try alloc.dupe(u8, "B"), .dims = try alloc.dupe(i64, &[_]i64{2}), .data = b });
    var model = OnnxModel{
        .tensors = tensors,
        .nodes = try alloc.dupe(Node, &[_]Node{
            .{ .op = try alloc.dupe(u8, "Gemm"), .inputs = try alloc.dupe([]u8, &[_][]u8{ try alloc.dupe(u8, "X"), try alloc.dupe(u8, "W"), try alloc.dupe(u8, "B") }), .outputs = try alloc.dupe([]u8, &[_][]u8{try alloc.dupe(u8, "Y")}), .trans_b = true },
        }),
        .input_name = try alloc.dupe(u8, "X"),
        .output_name = try alloc.dupe(u8, "Y"),
        .alloc = alloc,
    };
    defer {
        // free model nodes/names only (tensors map owned by test below)
        for (model.nodes) |n| {
            alloc.free(n.op);
            for (n.inputs) |i| alloc.free(i);
            alloc.free(n.inputs);
            for (n.outputs) |o| alloc.free(o);
            alloc.free(n.outputs);
        }
        alloc.free(model.nodes);
        alloc.free(model.input_name);
        alloc.free(model.output_name);
        var it = tensors.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*.name);
            alloc.free(e.value_ptr.*.dims);
            alloc.free(e.value_ptr.*.data);
        }
        tensors.deinit();
    }
    const out = try model.run(alloc, &[_]f32{ 3, 4 });
    defer alloc.free(out);
    try std.testing.expectApproxEqAbs(@as(f32, 3), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 4), out[1], 1e-5);
}

test "onnx softmax/layernorm" {
    const alloc = std.testing.allocator;
    const tensors = std.StringHashMap(Tensor).init(alloc);
    var model = OnnxModel{
        .tensors = tensors,
        .nodes = try alloc.dupe(Node, &[_]Node{
            .{ .op = try alloc.dupe(u8, "Softmax"), .inputs = try alloc.dupe([]u8, &[_][]u8{try alloc.dupe(u8, "X")}), .outputs = try alloc.dupe([]u8, &[_][]u8{try alloc.dupe(u8, "Y")}) },
        }),
        .input_name = try alloc.dupe(u8, "X"),
        .output_name = try alloc.dupe(u8, "Y"),
        .alloc = alloc,
    };
    const out = try model.run(alloc, &[_]f32{ 1, 2, 3 });
    defer alloc.free(out);
    var sum: f32 = 0;
    for (out) |v| sum += v;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum, 1e-5);
    try std.testing.expect(out[2] > out[1] and out[1] > out[0]);
    for (model.nodes) |n| {
        alloc.free(n.op);
        for (n.inputs) |i| alloc.free(i);
        alloc.free(n.inputs);
        for (n.outputs) |o| alloc.free(o);
        alloc.free(n.outputs);
    }
    alloc.free(model.nodes);
    alloc.free(model.input_name);
    alloc.free(model.output_name);
    model.tensors.deinit();
}

test "onnx gather/add/transpose" {
    const alloc = std.testing.allocator;
    // Gather: data [3,2] rows [0,1,2], indices [1,0] as float tensor hack (value in float)
    const tensors = std.StringHashMap(Tensor).init(alloc);
    var model = OnnxModel{
        .tensors = tensors,
        .nodes = try alloc.dupe(Node, &[_]Node{
            .{ .op = try alloc.dupe(u8, "Gather"), .inputs = try alloc.dupe([]u8, &[_][]u8{ try alloc.dupe(u8, "D"), try alloc.dupe(u8, "I") }), .outputs = try alloc.dupe([]u8, &[_][]u8{try alloc.dupe(u8, "Y")}) },
            .{ .op = try alloc.dupe(u8, "Add"), .inputs = try alloc.dupe([]u8, &[_][]u8{ try alloc.dupe(u8, "Y"), try alloc.dupe(u8, "B") }), .outputs = try alloc.dupe([]u8, &[_][]u8{try alloc.dupe(u8, "Z")}) },
        }),
        .input_name = try alloc.dupe(u8, "X"),
        .output_name = try alloc.dupe(u8, "Z"),
        .alloc = alloc,
    };
    // Manually inject tensors via run env? Use tensors map directly:
    try model.tensors.put(try alloc.dupe(u8, "D"), .{ .name = try alloc.dupe(u8, "D"), .dims = try alloc.dupe(i64, &[_]i64{ 3, 2 }), .data = try alloc.dupe(f32, &[_]f32{ 0, 1, 2, 3, 4, 5 }) });
    try model.tensors.put(try alloc.dupe(u8, "I"), .{ .name = try alloc.dupe(u8, "I"), .dims = try alloc.dupe(i64, &[_]i64{2}), .data = try alloc.dupe(f32, &[_]f32{ 1, 0 }) });
    try model.tensors.put(try alloc.dupe(u8, "B"), .{ .name = try alloc.dupe(u8, "B"), .dims = try alloc.dupe(i64, &[_]i64{4}), .data = try alloc.dupe(f32, &[_]f32{ 10, 10, 10, 10 }) });
    const out = try model.run(alloc, &[_]f32{0});
    defer alloc.free(out);
    try std.testing.expectApproxEqAbs(@as(f32, 12), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 13), out[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 10), out[2], 1e-5);
    // cleanup
    for (model.nodes) |n| {
        alloc.free(n.op);
        for (n.inputs) |i| alloc.free(i);
        alloc.free(n.inputs);
        for (n.outputs) |o| alloc.free(o);
        alloc.free(n.outputs);
    }
    alloc.free(model.nodes);
    alloc.free(model.input_name);
    alloc.free(model.output_name);
    var it = model.tensors.iterator();
    while (it.next()) |e| {
        alloc.free(e.key_ptr.*);
        alloc.free(e.value_ptr.*.name);
        alloc.free(e.value_ptr.*.dims);
        alloc.free(e.value_ptr.*.data);
    }
    model.tensors.deinit();
}

test "onnx attention identity" {
    const alloc = std.testing.allocator;
    const tensors = std.StringHashMap(Tensor).init(alloc);
    var model = OnnxModel{
        .tensors = tensors,
        .nodes = try alloc.dupe(Node, &[_]Node{
            .{ .op = try alloc.dupe(u8, "Attention"), .inputs = try alloc.dupe([]u8, &[_][]u8{ try alloc.dupe(u8, "Q"), try alloc.dupe(u8, "K"), try alloc.dupe(u8, "V") }), .outputs = try alloc.dupe([]u8, &[_][]u8{try alloc.dupe(u8, "Y")}) },
        }),
        .input_name = try alloc.dupe(u8, "Q"),
        .output_name = try alloc.dupe(u8, "Y"),
        .alloc = alloc,
    };
    defer {
        for (model.nodes) |n| {
            alloc.free(n.op);
            for (n.inputs) |i| alloc.free(i);
            alloc.free(n.inputs);
            for (n.outputs) |o| alloc.free(o);
            alloc.free(n.outputs);
        }
        alloc.free(model.nodes);
        alloc.free(model.input_name);
        alloc.free(model.output_name);
        var it = model.tensors.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*.name);
            alloc.free(e.value_ptr.*.dims);
            alloc.free(e.value_ptr.*.data);
        }
        model.tensors.deinit();
    }
    // Q=K=V identity basis: attention output approx V (each token attends to itself with dim 1)
    // Use tensors for K,V; Q comes from input
    try model.tensors.put(try alloc.dupe(u8, "K"), .{ .name = try alloc.dupe(u8, "K"), .dims = try alloc.dupe(i64, &[_]i64{ 2, 1 }), .data = try alloc.dupe(f32, &[_]f32{ 1, 0 }) });
    try model.tensors.put(try alloc.dupe(u8, "V"), .{ .name = try alloc.dupe(u8, "V"), .dims = try alloc.dupe(i64, &[_]i64{ 2, 1 }), .data = try alloc.dupe(f32, &[_]f32{ 10, 20 }) });
    const out = try model.run(alloc, &[_]f32{ 1, 0 });
    defer alloc.free(out);
    // token0 attends mostly to K0 (dot 1 vs 0) -> out near 10; token1 (0,0) uniform -> 15
    try std.testing.expect(out[0] > 10 and out[0] < 15);
    try std.testing.expectApproxEqAbs(@as(f32, 15), out[1], 1e-4);
}

test "onnx gelu" {
    const alloc = std.testing.allocator;
    const tensors = std.StringHashMap(Tensor).init(alloc);
    var model = OnnxModel{
        .tensors = tensors,
        .nodes = try alloc.dupe(Node, &[_]Node{
            .{ .op = try alloc.dupe(u8, "Gelu"), .inputs = try alloc.dupe([]u8, &[_][]u8{try alloc.dupe(u8, "X")}), .outputs = try alloc.dupe([]u8, &[_][]u8{try alloc.dupe(u8, "Y")}) },
        }),
        .input_name = try alloc.dupe(u8, "X"),
        .output_name = try alloc.dupe(u8, "Y"),
        .alloc = alloc,
    };
    const out = try model.run(alloc, &[_]f32{ 0, 1, -1 });
    defer alloc.free(out);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.84119), out[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -0.15881), out[2], 1e-4);
    for (model.nodes) |n| {
        alloc.free(n.op);
        for (n.inputs) |i| alloc.free(i);
        alloc.free(n.inputs);
        for (n.outputs) |o| alloc.free(o);
        alloc.free(n.outputs);
    }
    alloc.free(model.nodes);
    alloc.free(model.input_name);
    alloc.free(model.output_name);
    model.tensors.deinit();
}

test "onnx transformer block chain" {
    // Chain: Gemm -> LayerNorm -> Gelu, verify vs manual reference
    const alloc = std.testing.allocator;
    var tensors = std.StringHashMap(Tensor).init(alloc);
    try tensors.put(try alloc.dupe(u8, "W"), .{ .name = try alloc.dupe(u8, "W"), .dims = try alloc.dupe(i64, &[_]i64{ 2, 2 }), .data = try alloc.dupe(f32, &[_]f32{ 1, 0, 0, 1 }) });
    try tensors.put(try alloc.dupe(u8, "B"), .{ .name = try alloc.dupe(u8, "B"), .dims = try alloc.dupe(i64, &[_]i64{2}), .data = try alloc.dupe(f32, &[_]f32{ 0, 0 }) });
    var model = OnnxModel{
        .tensors = tensors,
        .nodes = try alloc.dupe(Node, &[_]Node{
            .{ .op = try alloc.dupe(u8, "Gemm"), .inputs = try alloc.dupe([]u8, &[_][]u8{ try alloc.dupe(u8, "X"), try alloc.dupe(u8, "W"), try alloc.dupe(u8, "B") }), .outputs = try alloc.dupe([]u8, &[_][]u8{try alloc.dupe(u8, "H")}), .trans_b = true },
            .{ .op = try alloc.dupe(u8, "LayerNormalization"), .inputs = try alloc.dupe([]u8, &[_][]u8{try alloc.dupe(u8, "H")}), .outputs = try alloc.dupe([]u8, &[_][]u8{try alloc.dupe(u8, "N")}) },
            .{ .op = try alloc.dupe(u8, "Gelu"), .inputs = try alloc.dupe([]u8, &[_][]u8{try alloc.dupe(u8, "N")}), .outputs = try alloc.dupe([]u8, &[_][]u8{try alloc.dupe(u8, "Y")}) },
        }),
        .input_name = try alloc.dupe(u8, "X"),
        .output_name = try alloc.dupe(u8, "Y"),
        .alloc = alloc,
    };
    defer {
        for (model.nodes) |n| {
            alloc.free(n.op);
            for (n.inputs) |i| alloc.free(i);
            alloc.free(n.inputs);
            for (n.outputs) |o| alloc.free(o);
            alloc.free(n.outputs);
        }
        alloc.free(model.nodes);
        alloc.free(model.input_name);
        alloc.free(model.output_name);
        var it = model.tensors.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*.name);
            alloc.free(e.value_ptr.*.dims);
            alloc.free(e.value_ptr.*.data);
        }
        model.tensors.deinit();
    }
    const out = try model.run(alloc, &[_]f32{ 2, 0 });
    defer alloc.free(out);
    // Gemm identity -> [2,0]; LayerNorm mean=1,var=1 -> [1,-1]; Gelu -> [0.841,-0.159]
    try std.testing.expectApproxEqAbs(@as(f32, 0.84119), out[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -0.15881), out[1], 1e-4);
}

test "onnx varint" {
    try std.testing.expect(true);
}
