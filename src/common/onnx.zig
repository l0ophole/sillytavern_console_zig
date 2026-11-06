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
                const b_tensor = self.tensors.get(node.inputs[1]) orelse return error.MissingWeight;
                const b = b_tensor.data;
                const dims = b_tensor.dims;
                if (dims.len != 2) return error.BadShape;
                const n_out: usize = @intCast(dims[0]);
                const k_dim: usize = @intCast(dims[1]);
                // Y = X * W (W is [N,K] with transB, or [K,N] without)
                const out = try alloc.alloc(f32, n_out);
                const trans_b = node.trans_b or std.mem.eql(u8, node.op, "Gemm");
                for (0..n_out) |o| {
                    var sum: f32 = 0;
                    for (0..k_dim) |k| {
                        const wval = if (trans_b) b[o * k_dim + k] else b[k * n_out + o];
                        sum += a[k] * wval;
                    }
                    out[o] = sum;
                }
                // Add bias if third input present
                if (node.inputs.len > 2) {
                    if (self.tensors.get(node.inputs[2])) |bt| {
                        for (0..n_out) |o| out[o] += bt.data[o];
                    }
                }
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

test "onnx varint" {
    try std.testing.expect(true);
}
