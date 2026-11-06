const std = @import("std");

// Heuristic estimate (chars/4, min 1 for non-empty). SillyTavern uses
// tiktoken / sentencepiece for exact counts; this is a documented
// approximation for console use until a BPE tokenizer is ported.
pub fn bytesToUnicode(b: u8) u21 {
    if ((b >= 33 and b <= 126) or (b >= 161 and b <= 172) or (b >= 174 and b <= 255)) return b;
    // Count missing bytes below b to get sequential offset
    var n: u21 = 0;
    var v: u16 = 0;
    while (v < b) : (v += 1) {
        if (!((v >= 33 and v <= 126) or (v >= 161 and v <= 172) or (v >= 174 and v <= 255))) n += 1;
    }
    return 256 + n;
}

pub const BpeVocab = struct {
    ranks: std.StringHashMap(u32),
    // pair ranks encoded as "a\x00b" -> rank is derived from merged token rank; use token map for merges
    merges: std.StringHashMap(u32),

    pub fn init(alloc: std.mem.Allocator) BpeVocab {
        return .{ .ranks = std.StringHashMap(u32).init(alloc), .merges = std.StringHashMap(u32).init(alloc) };
    }
    pub fn deinit(self: *BpeVocab) void {
        var it = self.ranks.iterator();
        while (it.next()) |e| self.ranks.allocator.free(e.key_ptr.*);
        self.ranks.deinit();
        var it2 = self.merges.iterator();
        while (it2.next()) |e| self.merges.allocator.free(e.key_ptr.*);
        self.merges.deinit();
    }
};

/// Load cl100k_base.tiktoken format: "<base64 token> <rank>" per line.
/// Tokens in file are raw bytes base64-encoded. We store UTF-8 byte-level
/// unicode form by converting each raw byte via bytesToUnicode.
pub fn loadVocab(alloc: std.mem.Allocator, path: []const u8) !BpeVocab {
    const content = try std.fs.cwd().readFileAlloc(alloc, path, 10 << 20);
    defer alloc.free(content);
    var vocab = BpeVocab.init(alloc);
    errdefer vocab.deinit();
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const b64 = line[0..sp];
        const rank = std.fmt.parseInt(u32, line[sp + 1 ..], 10) catch continue;
        const dec = std.base64.standard.Decoder;
        const sz = dec.calcSizeForSlice(b64) catch continue;
        const raw = try alloc.alloc(u8, sz);
        dec.decode(raw, b64) catch {
            alloc.free(raw);
            continue;
        };
        defer alloc.free(raw);
        // Convert raw bytes to byte-level unicode UTF-8 string
        var tok: std.ArrayListUnmanaged(u8) = .empty;
        defer tok.deinit(alloc);
        for (raw) |byte| {
            const cp = bytesToUnicode(byte);
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch continue;
            tok.appendSlice(alloc, buf[0..n]) catch continue;
        }
        const key = try alloc.dupe(u8, tok.items);
        try vocab.ranks.put(key, rank);
    }
    // Build merges: for each token with rank r, find split? Standard BPE merges are
    // derived from vocab order: merges are pairs that form tokens. Instead, during
    // encoding we look up merged candidate in ranks and use its rank as merge priority.
    return vocab;
}

/// Load HuggingFace tokenizer.json BPE vocab (model.vocab: token -> id).
/// Works for llama3.json bundled in SillyTavern (src/tokenizers/llama3.json).
pub fn loadHfVocab(alloc: std.mem.Allocator, path: []const u8) !BpeVocab {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const content = try f.readToEndAlloc(alloc, 20 << 20);
    defer alloc.free(content);
    var arena = std.heap.ArenaAllocator.init(alloc);
    // Parse with arena to avoid leaks; copy keys out
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), content, .{});
    if (parsed.value != .object) return error.BadVocab;
    const model = parsed.value.object.get("model") orelse return error.BadVocab;
    if (model != .object) return error.BadVocab;
    const vocab_v = model.object.get("vocab") orelse return error.BadVocab;
    if (vocab_v != .object) return error.BadVocab;
    var vocab = BpeVocab.init(alloc);
    errdefer vocab.deinit();
    var it = vocab_v.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .integer) continue;
        const key = try alloc.dupe(u8, kv.key_ptr.*);
        try vocab.ranks.put(key, @intCast(kv.value_ptr.*.integer));
    }
    arena.deinit();
    return vocab;
}

fn byteLevelEncode(alloc: std.mem.Allocator, chunk: []const u8, out: *std.ArrayListUnmanaged([]u8)) !void {
    for (chunk) |byte| {
        const cp = bytesToUnicode(byte);
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &buf);
        const s = try alloc.dupe(u8, buf[0..len]);
        try out.append(alloc, s);
    }
}

/// Encode one chunk via BPE merges (using vocab ranks as merge priority).
pub fn bpeEncodeChunk(alloc: std.mem.Allocator, vocab: *BpeVocab, chunk: []const u8, out_ids: *std.ArrayListUnmanaged(u32)) !void {
    var parts: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (parts.items) |p| alloc.free(p);
        parts.deinit(alloc);
    }
    try byteLevelEncode(alloc, chunk, &parts);
    if (parts.items.len <= 1) {
        for (parts.items) |p| {
            if (vocab.ranks.get(p)) |r| try out_ids.append(alloc, r);
        }
        return;
    }
    while (true) {
        // Find pair with lowest rank of merged token
        var best_idx: ?usize = null;
        var best_rank: u32 = std.math.maxInt(u32);
        var i: usize = 0;
        while (i + 1 < parts.items.len) : (i += 1) {
            const merged = try std.fmt.allocPrint(alloc, "{s}{s}", .{ parts.items[i], parts.items[i + 1] });
            defer alloc.free(merged);
            if (vocab.ranks.get(merged)) |r| {
                if (r < best_rank) {
                    best_rank = r;
                    best_idx = i;
                }
            }
        }
        if (best_idx == null) break;
        const idx = best_idx.?;
        const merged = try std.fmt.allocPrint(alloc, "{s}{s}", .{ parts.items[idx], parts.items[idx + 1] });
        alloc.free(parts.items[idx]);
        alloc.free(parts.items[idx + 1]);
        parts.items[idx] = merged;
        _ = parts.orderedRemove(idx + 1);
    }
    for (parts.items) |p| {
        if (vocab.ranks.get(p)) |r| try out_ids.append(alloc, r);
    }
}

/// Approximate cl100k chunk split (ASCII-focused; handles contractions, words, numbers, punctuation, whitespace).
pub fn splitChunks(alloc: std.mem.Allocator, text: []const u8, out: *std.ArrayListUnmanaged([]u8)) !void {
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        const c = text[i];
        // contraction: 's 't 're etc — handled as part of preceding word in full regex;
        // here treat ' as its own start if followed by letters
        if (c == ' ' or c == '\t') {
            // space + following letters/digits/punct as one chunk, else whitespace run
            var j = i + 1;
            if (j < text.len and (std.ascii.isAlphabetic(text[j]) or std.ascii.isDigit(text[j]))) {
                while (j < text.len and (std.ascii.isAlphabetic(text[j]) or std.ascii.isDigit(text[j]) or text[j] == '\'')) j += 1;
                try out.append(alloc, try alloc.dupe(u8, text[start..j]));
                i = j;
            } else {
                while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) j += 1;
                try out.append(alloc, try alloc.dupe(u8, text[start..j]));
                i = j;
            }
        } else if (std.ascii.isAlphabetic(c)) {
            var j = i;
            while (j < text.len and (std.ascii.isAlphabetic(text[j]) or text[j] == '\'')) j += 1;
            try out.append(alloc, try alloc.dupe(u8, text[start..j]));
            i = j;
        } else if (std.ascii.isDigit(c)) {
            var j = i;
            while (j < text.len and std.ascii.isDigit(text[j]) and j - i < 3) j += 1;
            try out.append(alloc, try alloc.dupe(u8, text[start..j]));
            i = j;
        } else if (c == '\n' or c == '\r') {
            var j = i;
            while (j < text.len and (text[j] == '\n' or text[j] == '\r')) j += 1;
            try out.append(alloc, try alloc.dupe(u8, text[start..j]));
            i = j;
        } else if (c == ' ' or c == '\t') {
            unreachable;
        } else {
            // punctuation / other bytes: group consecutive non-space non-alnum
            var j = i;
            while (j < text.len and !std.ascii.isAlphabetic(text[j]) and !std.ascii.isDigit(text[j]) and text[j] != ' ' and text[j] != '\t' and text[j] != '\n' and text[j] != '\r') j += 1;
            if (j == i) j = i + 1;
            try out.append(alloc, try alloc.dupe(u8, text[start..j]));
            i = j;
        }
    }
}

pub fn bpeEncode(alloc: std.mem.Allocator, vocab: *BpeVocab, text: []const u8) ![]u32 {
    var ids: std.ArrayListUnmanaged(u32) = .empty;
    errdefer ids.deinit(alloc);
    var chunks: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (chunks.items) |ch| alloc.free(ch);
        chunks.deinit(alloc);
    }
    try splitChunks(alloc, text, &chunks);
    for (chunks.items) |ch| {
        try bpeEncodeChunk(alloc, vocab, ch, &ids);
    }
    return ids.toOwnedSlice(alloc);
}

pub fn estimateTokens(text: []const u8) usize {
    if (text.len == 0) return 0;
    return (text.len + 3) / 4;
}

test "bytesToUnicode" {
    try std.testing.expectEqual(@as(u21, 'a'), bytesToUnicode('a'));
    try std.testing.expect(bytesToUnicode(' ') > 255);
    try std.testing.expect(bytesToUnicode(0) > 255);
}

test "estimateTokens" {
    try std.testing.expectEqual(@as(usize, 0), estimateTokens(""));
    try std.testing.expectEqual(@as(usize, 1), estimateTokens("abcd"));
    try std.testing.expectEqual(@as(usize, 2), estimateTokens("abcdefgh"));
    try std.testing.expectEqual(@as(usize, 1), estimateTokens("a"));
}
