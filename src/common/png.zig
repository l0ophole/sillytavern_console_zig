const std = @import("std");

pub const PNG_SIG = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

pub fn isPng(data: []const u8) bool {
    if (data.len < 8) return false;
    return std.mem.eql(u8, data[0..8], &PNG_SIG);
}

pub fn detectFormat(data: []const u8) []const u8 {
    if (isPng(data)) return "png";
    if (data.len >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) return "jpeg";
    if (data.len >= 6 and (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a"))) return "gif";
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return "webp";
    if (data.len >= 2 and data[0] == 'B' and data[1] == 'M') return "bmp";
    return "unknown";
}

pub fn pngSize(data: []const u8) ?[2]u32 {
    if (!isPng(data) or data.len < 24) return null;
    // IHDR chunk starts at 8: len(4) type(4) width(4) height(4)
    if (!std.mem.eql(u8, data[12..16], "IHDR")) return null;
    const w: u32 = (@as(u32, data[16]) << 24) | (@as(u32, data[17]) << 16) | (@as(u32, data[18]) << 8) | @as(u32, data[19]);
    const h: u32 = (@as(u32, data[20]) << 24) | (@as(u32, data[21]) << 16) | (@as(u32, data[22]) << 8) | @as(u32, data[23]);
    return .{ w, h };
}

/// Extract tEXt/iTXt chunk with given keyword. Returns owned slice or null.
pub fn extractTextChunk(alloc: std.mem.Allocator, data: []const u8, keyword: []const u8) !?[]u8 {
    if (!isPng(data)) return null;
    var pos: usize = 8;
    while (pos + 12 <= data.len) {
        const len: u32 = (@as(u32, data[pos]) << 24) | (@as(u32, data[pos+1]) << 16) | (@as(u32, data[pos+2]) << 8) | @as(u32, data[pos+3]);
        const ctype = data[pos + 4 .. pos + 8];
        const chunk_data_start = pos + 8;
        const chunk_data_end = chunk_data_start + len;
        if (chunk_data_end + 4 > data.len) break;
        const chunk_data = data[chunk_data_start..chunk_data_end];
        if (std.mem.eql(u8, ctype, "tEXt")) {
            if (std.mem.indexOfScalar(u8, chunk_data, 0)) |nul| {
                const kw = chunk_data[0..nul];
                if (std.mem.eql(u8, kw, keyword)) {
                    return try alloc.dupe(u8, chunk_data[nul + 1 ..]);
                }
            }
        } else if (std.mem.eql(u8, ctype, "iTXt")) {
            if (std.mem.indexOfScalar(u8, chunk_data, 0)) |nul| {
                const kw = chunk_data[0..nul];
                if (std.mem.eql(u8, kw, keyword)) {
                    // iTXt: keyword\0 comp_flag(1) comp_method(1) lang\0 translated\0 text
                    var p = nul + 1 + 2;
                    // skip lang tag
                    if (std.mem.indexOfScalar(u8, chunk_data[p..], 0)) |z| p += z + 1;
                    if (std.mem.indexOfScalar(u8, chunk_data[p..], 0)) |z| p += z + 1;
                    return try alloc.dupe(u8, chunk_data[p..]);
                }
            }
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            break;
        }
        pos = chunk_data_end + 4;
    }
    return null;
}

/// SillyTavern stores chara as base64 JSON in tEXt; also accept plain JSON.
pub fn decodeChara(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '{') return alloc.dupe(u8, trimmed);
    const dec = std.base64.standard.Decoder;
    const size = try dec.calcSizeForSlice(trimmed);
    const out = try alloc.alloc(u8, size);
    errdefer alloc.free(out);
    try dec.decode(out, trimmed);
    return out;
}

test "detectFormat" {
    try std.testing.expectEqualStrings("png", detectFormat(&PNG_SIG));
    try std.testing.expectEqualStrings("jpeg", detectFormat(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 }));
    try std.testing.expectEqualStrings("gif", detectFormat("GIF89a123"));
    try std.testing.expectEqualStrings("unknown", detectFormat("hello"));
}

test "pngSize and text chunk" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, &PNG_SIG);
    // IHDR 1x2
    try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 13 });
    try buf.appendSlice(alloc, "IHDR");
    try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 1, 0, 0, 0, 2, 8, 0, 0, 0, 0 });
    try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 }); // crc dummy
    const card = "{\"name\":\"Bob\"}";
    const kw = "chara";
    const text_data = try std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ kw, card });
    defer alloc.free(text_data);
    const tlen: u32 = @intCast(text_data.len);
    var lenb: [4]u8 = undefined;
    std.mem.writeInt(u32, &lenb, tlen, .big);
    try buf.appendSlice(alloc, &lenb);
    try buf.appendSlice(alloc, "tEXt");
    try buf.appendSlice(alloc, text_data);
    try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 });
    // IEND
    try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 });
    try buf.appendSlice(alloc, "IEND");
    try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 });

    const sz = pngSize(buf.items).?;
    try std.testing.expectEqual(@as(u32, 1), sz[0]);
    try std.testing.expectEqual(@as(u32, 2), sz[1]);
    const extracted = (try extractTextChunk(alloc, buf.items, "chara")).?;
    defer alloc.free(extracted);
    try std.testing.expectEqualStrings(card, extracted);
}
