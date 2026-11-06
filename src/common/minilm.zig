const std = @import("std");

// Pure-Zig MiniLM-L6-v2 inference (6 layers, 384 hidden, 12 heads, 32 head_dim)
// via safetensors weights. Mirrors the ONNX graph: embeddings+LN,
// multi-head attention (QKV MatMul + scaled softmax + output MatMul),
// intermediate Gelu, output Dense+LN, mean-pool + L2 norm.

pub const Hidden: usize = 384;
pub const Heads: usize = 12;
pub const HeadDim: usize = 32;
pub const Layers: usize = 6;
pub const MaxSeq: usize = 256;

pub const Weights = struct {
    word_emb: []f32, // [30522,384]
    pos_emb: []f32, // [512,384]
    tok_emb: []f32,
    emb_ln_w: []f32,
    emb_ln_b: []f32,
    // per layer 0..5
    q_w: [Layers][]f32, q_b: [Layers][]f32,
    k_w: [Layers][]f32, k_b: [Layers][]f32,
    v_w: [Layers][]f32, v_b: [Layers][]f32,
    attn_out_w: [Layers][]f32, attn_out_b: [Layers][]f32,
    attn_ln_w: [Layers][]f32, attn_ln_b: [Layers][]f32,
    inter_w: [Layers][]f32, inter_b: [Layers][]f32, // [1536,384]
    out_w: [Layers][]f32, out_b: [Layers][]f32, // [384,1536]
    out_ln_w: [Layers][]f32, out_ln_b: [Layers][]f32,
    alloc: std.mem.Allocator,
    raw: []u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Weights) void {
        self.arena.deinit();
    }
};

fn getTensor(alloc: std.mem.Allocator, raw: []const u8, hdr: std.json.Value, name: []const u8) ![]f32 {
    const t = hdr.object.get(name) orelse return error.MissingTensor;
    const begin: usize = @intCast(t.object.get("data_offsets").?.array.items[0].integer);
    const end: usize = @intCast(t.object.get("data_offsets").?.array.items[1].integer);
    const bytes = raw[begin..end];
    const n = bytes.len / 4;
    const out = try alloc.alloc(f32, n);
    for (0..n) |i| out[i] = @bitCast(std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little));
    return out;
}

pub fn loadWeights(alloc: std.mem.Allocator, path: []const u8) !Weights {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const raw = try f.readToEndAlloc(a, 500 << 20);
    const hdr_len: usize = @intCast(std.mem.readInt(u64, raw[0..8], .little));
    const hdr_json = raw[8 .. 8 + hdr_len];
    const parsed = try std.json.parseFromSlice(std.json.Value, a, hdr_json, .{});
    const data_base = 8 + hdr_len;
    // getTensor offsets are relative to data start; adjust by slicing raw from data_base front view:
    // Our getTensor slices raw[begin..end] — pass raw[data_base..] as raw_view
    const raw_view = raw[data_base..];
    var w: Weights = undefined;
    w.alloc = alloc;
    w.arena = arena;
    w.raw = raw;
    w.word_emb = try getTensor(a, raw_view, parsed.value, "embeddings.word_embeddings.weight");
    w.pos_emb = try getTensor(a, raw_view, parsed.value, "embeddings.position_embeddings.weight");
    w.tok_emb = try getTensor(a, raw_view, parsed.value, "embeddings.token_type_embeddings.weight");
    w.emb_ln_w = try getTensor(a, raw_view, parsed.value, "embeddings.LayerNorm.weight");
    w.emb_ln_b = try getTensor(a, raw_view, parsed.value, "embeddings.LayerNorm.bias");
    inline for (0..Layers) |l| {
        const qname = try std.fmt.allocPrint(a, "encoder.layer.{d}.attention.self.query.weight", .{l});
        const qbias = try std.fmt.allocPrint(a, "encoder.layer.{d}.attention.self.query.bias", .{l});
        const kname = try std.fmt.allocPrint(a, "encoder.layer.{d}.attention.self.key.weight", .{l});
        const kbias = try std.fmt.allocPrint(a, "encoder.layer.{d}.attention.self.key.bias", .{l});
        const vname = try std.fmt.allocPrint(a, "encoder.layer.{d}.attention.self.value.weight", .{l});
        const vbias = try std.fmt.allocPrint(a, "encoder.layer.{d}.attention.self.value.bias", .{l});
        const owname = try std.fmt.allocPrint(a, "encoder.layer.{d}.attention.output.dense.weight", .{l});
        const owbias = try std.fmt.allocPrint(a, "encoder.layer.{d}.attention.output.dense.bias", .{l});
        const alnw = try std.fmt.allocPrint(a, "encoder.layer.{d}.attention.output.LayerNorm.weight", .{l});
        const alnb = try std.fmt.allocPrint(a, "encoder.layer.{d}.attention.output.LayerNorm.bias", .{l});
        const iwn = try std.fmt.allocPrint(a, "encoder.layer.{d}.intermediate.dense.weight", .{l});
        const iwb = try std.fmt.allocPrint(a, "encoder.layer.{d}.intermediate.dense.bias", .{l});
        const own = try std.fmt.allocPrint(a, "encoder.layer.{d}.output.dense.weight", .{l});
        const owb = try std.fmt.allocPrint(a, "encoder.layer.{d}.output.dense.bias", .{l});
        const olnw = try std.fmt.allocPrint(a, "encoder.layer.{d}.output.LayerNorm.weight", .{l});
        const olnb = try std.fmt.allocPrint(a, "encoder.layer.{d}.output.LayerNorm.bias", .{l});
        w.q_w[l] = try getTensor(a, raw_view, parsed.value, qname);
        w.q_b[l] = try getTensor(a, raw_view, parsed.value, qbias);
        w.k_w[l] = try getTensor(a, raw_view, parsed.value, kname);
        w.k_b[l] = try getTensor(a, raw_view, parsed.value, kbias);
        w.v_w[l] = try getTensor(a, raw_view, parsed.value, vname);
        w.v_b[l] = try getTensor(a, raw_view, parsed.value, vbias);
        w.attn_out_w[l] = try getTensor(a, raw_view, parsed.value, owname);
        w.attn_out_b[l] = try getTensor(a, raw_view, parsed.value, owbias);
        w.attn_ln_w[l] = try getTensor(a, raw_view, parsed.value, alnw);
        w.attn_ln_b[l] = try getTensor(a, raw_view, parsed.value, alnb);
        w.inter_w[l] = try getTensor(a, raw_view, parsed.value, iwn);
        w.inter_b[l] = try getTensor(a, raw_view, parsed.value, iwb);
        w.out_w[l] = try getTensor(a, raw_view, parsed.value, own);
        w.out_b[l] = try getTensor(a, raw_view, parsed.value, owb);
        w.out_ln_w[l] = try getTensor(a, raw_view, parsed.value, olnw);
        w.out_ln_b[l] = try getTensor(a, raw_view, parsed.value, olnb);
    }
    return w;
}

fn matmulVec(alloc: std.mem.Allocator, x: []const f32, w: []const f32, b: []const f32, in_dim: usize, out_dim: usize, out: []f32) void {
    _ = alloc;
    for (0..out_dim) |o| {
        var sum = b[o];
        for (0..in_dim) |i| sum += x[i] * w[o * in_dim + i];
        out[o] = sum;
    }
}

fn layerNorm(x: []f32, w: []const f32, b: []const f32) void {
    var mean: f32 = 0;
    for (x) |v| mean += v;
    mean /= @as(f32, @floatFromInt(x.len));
    var var_sum: f32 = 0;
    for (x) |v| var_sum += (v - mean) * (v - mean);
    const stdv = @sqrt(var_sum / @as(f32, @floatFromInt(x.len)) + 1e-12);
    for (x, 0..) |*v, i| v.* = (v.* - mean) / stdv * w[i] + b[i];
}

pub fn embed(alloc: std.mem.Allocator, w: *Weights, token_ids: []const i64) ![]f32 {
    const seq = token_ids.len;
    // x: [seq, 384]
    var x = try alloc.alloc(f32, seq * Hidden);
    defer alloc.free(x);
    for (0..seq) |s| {
        const tid: usize = @intCast(token_ids[s]);
        for (0..Hidden) |h| {
            x[s * Hidden + h] = w.word_emb[tid * Hidden + h] + w.pos_emb[s * Hidden + h] + w.tok_emb[h];
        }
    }
    layerNormVec(x, w.emb_ln_w, w.emb_ln_b, seq);
    var q = try alloc.alloc(f32, seq * Hidden);
    defer alloc.free(q);
    var k = try alloc.alloc(f32, seq * Hidden);
    defer alloc.free(k);
    var v = try alloc.alloc(f32, seq * Hidden);
    defer alloc.free(v);
    var attn_out = try alloc.alloc(f32, seq * Hidden);
    defer alloc.free(attn_out);
    const inter = try alloc.alloc(f32, seq * 1536);
    defer alloc.free(inter);
    const tmp_vec = try alloc.alloc(f32, Hidden);
    defer alloc.free(tmp_vec);
    const tmp_big = try alloc.alloc(f32, 1536);
    defer alloc.free(tmp_big);
    var scores = try alloc.alloc(f32, seq * seq);
    defer alloc.free(scores);
    for (0..Layers) |l| {
        // QKV per token
        for (0..seq) |s| {
            matmulVec(alloc, x[s * Hidden .. (s + 1) * Hidden], w.q_w[l], w.q_b[l], Hidden, Hidden, q[s * Hidden .. (s + 1) * Hidden]);
            matmulVec(alloc, x[s * Hidden .. (s + 1) * Hidden], w.k_w[l], w.k_b[l], Hidden, Hidden, k[s * Hidden .. (s + 1) * Hidden]);
            matmulVec(alloc, x[s * Hidden .. (s + 1) * Hidden], w.v_w[l], w.v_b[l], Hidden, Hidden, v[s * Hidden .. (s + 1) * Hidden]);
        }
        // Multi-head attention
        const scale: f32 = 1.0 / @sqrt(@as(f32, 32));
        for (0..seq) |s| {
            for (0..Heads) |h| {
                const hoff = h * HeadDim;
                var maxv: f32 = -1000000;
                for (0..seq) |t| {
                    var dot: f32 = 0;
                    for (0..HeadDim) |d| dot += q[s * Hidden + hoff + d] * k[t * Hidden + hoff + d];
                    dot *= scale;
                    scores[s * seq + t] = dot;
                    maxv = @max(maxv, dot);
                }
                var sum: f32 = 0;
                for (0..seq) |t| {
                    scores[s * seq + t] = @exp(scores[s * seq + t] - maxv);
                    sum += scores[s * seq + t];
                }
                for (0..seq) |t| scores[s * seq + t] /= sum;
                for (0..HeadDim) |d| {
                    var acc: f32 = 0;
                    for (0..seq) |t| acc += scores[s * seq + t] * v[t * Hidden + hoff + d];
                    attn_out[s * Hidden + hoff + d] = acc;
                }
            }
        }
        // Output dense + residual + LN
        for (0..seq) |s| {
            matmulVec(alloc, attn_out[s * Hidden .. (s + 1) * Hidden], w.attn_out_w[l], w.attn_out_b[l], Hidden, Hidden, tmp_vec);
            for (0..Hidden) |h| attn_out[s * Hidden + h] = x[s * Hidden + h] + tmp_vec[h];
            layerNormVec(attn_out[s * Hidden .. (s + 1) * Hidden * 1], w.attn_ln_w[l], w.attn_ln_b[l], 1);
            // Intermediate Gelu
            matmulVec(alloc, attn_out[s * Hidden .. (s + 1) * Hidden], w.inter_w[l], w.inter_b[l], Hidden, 1536, tmp_big);
            for (0..1536) |g| {
                const gv = tmp_big[g / 1536 * 0 + (g % 1536)]; // placeholder (overwritten below by direct)
                _ = gv;
            }
            // FFN: inter (1536) -> gelu -> out (384)
            var gelu_out = try alloc.alloc(f32, 1536);
            defer alloc.free(gelu_out);
            for (0..1536) |g| {
                const gv = tmp_big[g];
                gelu_out[g] = 0.5 * gv * (1 + std.math.tanh(@sqrt(2.0 / std.math.pi) * (gv + 0.044715 * gv * gv * gv)));
            }
            matmulVec(alloc, gelu_out, w.out_w[l], w.out_b[l], 1536, Hidden, tmp_vec);
            for (0..Hidden) |h| attn_out[s * Hidden + h] += tmp_vec[h];
            layerNormVec(attn_out[s * Hidden .. (s + 1) * Hidden], w.out_ln_w[l], w.out_ln_b[l], 1);
            @memcpy(x[s * Hidden .. (s + 1) * Hidden], attn_out[s * Hidden .. (s + 1) * Hidden]);
        }
    }
    // Mean pool + normalize
    var pooled = try alloc.alloc(f32, Hidden);
    defer alloc.free(pooled);
    for (0..Hidden) |h| {
        var sum: f32 = 0;
        for (0..seq) |s| sum += x[s * Hidden + h];
        pooled[h] = sum / @as(f32, @floatFromInt(seq));
    }
    var norm: f32 = 0;
    for (pooled) |pv| norm += pv * pv;
    norm = @sqrt(norm);
    for (pooled) |*pv| pv.* /= @max(norm, 1e-9);
    return alloc.dupe(f32, pooled);
}

fn layerNormVec(x: []f32, w: []const f32, b: []const f32, seq: usize) void {
    for (0..seq) |s| {
        layerNorm(x[s * Hidden .. (s + 1) * Hidden], w, b);
    }
}

pub const Vocab = struct {
    map: *const std.StringHashMap(u32),
};

pub fn wordPieceTokenize(alloc: std.mem.Allocator, text: []const u8, vocab: *const std.StringHashMap(u32), out_ids: *std.ArrayListUnmanaged(i64)) !void {
    try out_ids.append(alloc, 101); // [CLS]
    var it = std.mem.splitScalar(u8, text, ' ');
    while (it.next()) |word| {
        const lower = try alloc.alloc(u8, word.len);
        defer alloc.free(lower);
        for (word, 0..) |c, ci| lower[ci] = std.ascii.toLower(c);
        if (lower.len == 0) continue;
        var start: usize = 0;
        while (start < lower.len) {
            var end = lower.len;
            var found: ?u32 = null;
            while (start < end) : (end -= 1) {
                const substr = lower[start..end];
                var tok: []const u8 = substr;
                var with_prefix: [260]u8 = undefined;
                if (start > 0) {
                    if (substr.len + 2 > with_prefix.len) continue;
                    @memcpy(with_prefix[0..2], "##");
                    @memcpy(with_prefix[2..][0..substr.len], substr);
                    tok = with_prefix[0 .. substr.len + 2];
                }
                if (vocab.get(tok)) |id| {
                    found = id;
                    break;
                }
            }
            if (found) |id| {
                try out_ids.append(alloc, @intCast(id));
                start = end;
            } else {
                try out_ids.append(alloc, 100); // [UNK]
                break;
            }
        }
        if (out_ids.items.len > 250) break;
    }
    try out_ids.append(alloc, 102); // [SEP]
}

test "minilm constants" {
    try std.testing.expectEqual(@as(usize, 384), Hidden);
    try std.testing.expectEqual(@as(usize, 6), Layers);
}
