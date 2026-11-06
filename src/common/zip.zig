const std = @import("std");

fn le16(d: []const u8, off: usize) u16 {
    return @as(u16, d[off]) | (@as(u16, d[off + 1]) << 8);
}
fn le32(d: []const u8, off: usize) u32 {
    return @as(u32, d[off]) | (@as(u32, d[off + 1]) << 8) | (@as(u32, d[off + 2]) << 16) | (@as(u32, d[off + 3]) << 24);
}

pub fn isZip(data: []const u8) bool {
    const limit = @min(data.len, 65536);
    return std.mem.indexOf(u8, data[0..limit], "PK\x03\x04") != null;
}

fn findEocd(data: []const u8) ?usize {
    if (data.len < 22) return null;
    const start = data.len -| @min(data.len, 65557);
    var i = data.len - 22;
    while (true) {
        if (data[i] == 'P' and data[i + 1] == 'K' and data[i + 2] == 0x05 and data[i + 3] == 0x06) return i;
        if (i == start) break;
        i -= 1;
    }
    return null;
}

/// Extract a file by name from a ZIP (stored + deflate). Returns owned slice or null.
pub fn extractFile(alloc: std.mem.Allocator, zip_data: []const u8, wanted: []const u8) !?[]u8 {
    const eocd = findEocd(zip_data) orelse return null;
    const cd_offset = le32(zip_data, eocd + 16);
    const cd_size = le32(zip_data, eocd + 12);
    if (@as(usize, cd_offset) + cd_size > zip_data.len) return null;
    var pos: usize = cd_offset;
    const cd_end = cd_offset + cd_size;
    while (pos + 46 <= cd_end) {
        if (!(zip_data[pos] == 'P' and zip_data[pos + 1] == 'K' and zip_data[pos + 2] == 0x01 and zip_data[pos + 3] == 0x02)) break;
        const method = le16(zip_data, pos + 10);
        const comp_size = le32(zip_data, pos + 20);
        const name_len = le16(zip_data, pos + 28);
        const extra_len = le16(zip_data, pos + 30);
        const comment_len = le16(zip_data, pos + 32);
        const local_off = le32(zip_data, pos + 42);
        const name = zip_data[pos + 46 .. pos + 46 + name_len];
        if (std.mem.eql(u8, name, wanted)) {
            if (@as(usize, local_off) + 30 > zip_data.len) return null;
            if (!(zip_data[local_off] == 'P' and zip_data[local_off + 1] == 'K')) return null;
            const lname_len = le16(zip_data, local_off + 26);
            const lextra_len = le16(zip_data, local_off + 28);
            const data_start = @as(usize, local_off) + 30 + lname_len + lextra_len;
            const comp_end = data_start + comp_size;
            if (comp_end > zip_data.len) return null;
            if (method == 0) {
                return try alloc.dupe(u8, zip_data[data_start..comp_end]);
            } else if (method == 8) {
                var reader: std.Io.Reader = .fixed(zip_data[data_start..comp_end]);
                var dec = std.compress.flate.Decompress.init(&reader, .raw, &[_]u8{});
                return dec.reader.allocRemaining(alloc, .unlimited) catch null;
            }
            return null;
        }
        pos += 46 + name_len + extra_len + comment_len;
    }
    return null;
}

test "isZip" {
    try std.testing.expect(isZip("PK\x03\x04hello"));
    try std.testing.expect(!isZip("hello"));
}
