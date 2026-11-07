const std = @import("std");
const posix = std.posix;

// Build a minimal HTTP/1.1 POST request (http only; https needs TLS —
// documented parity gap vs SillyTavern's node-fetch).
pub fn buildHttpRequest(alloc: std.mem.Allocator, host: []const u8, path: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ path, host, body.len, body });
}

pub fn splitHttpResponse(resp: []const u8) struct { status: u16, body: []const u8 } {
    var status: u16 = 0;
    if (std.mem.indexOf(u8, resp, " ")) |sp| {
        const rest = resp[sp + 1 ..];
        if (std.mem.indexOf(u8, rest, " ")) |sp2| {
            status = std.fmt.parseInt(u16, rest[0..sp2], 10) catch 0;
        }
    }
    if (std.mem.indexOf(u8, resp, "\r\n\r\n")) |idx| {
        return .{ .status = status, .body = resp[idx + 4 ..] };
    }
    return .{ .status = status, .body = resp };
}

pub fn forwardHttp(alloc: std.mem.Allocator, host: []const u8, port: u16, path: []const u8, body: []const u8) ![]u8 {
    const addr_str = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ host, port });
    defer alloc.free(addr_str);
    const addr = try std.net.Address.parseIpAndPort(addr_str);
    const sock = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(sock);
    try posix.connect(sock, &addr.any, addr.getOsSockLen());
    const req = try buildHttpRequest(alloc, host, path, body);
    defer alloc.free(req);
    _ = try posix.write(sock, req);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try posix.read(sock, &buf);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    return out.toOwnedSlice(alloc);
}

pub const FetchResult = struct { status: u16, body: []u8 };

/// Fetch via std.http.Client (supports http and https/TLS).
pub fn fetchUrl(alloc: std.mem.Allocator, url: []const u8, method: []const u8, payload: ?[]const u8) !FetchResult {
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var m: std.http.Method = .GET;
    if (std.mem.eql(u8, method, "POST")) m = .POST;
    if (std.mem.eql(u8, method, "PUT")) m = .PUT;
    if (std.mem.eql(u8, method, "DELETE")) m = .DELETE;
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = m,
        .payload = payload,
        .response_writer = &out.writer,
        .keep_alive = false,
    });
    return .{ .status = @intFromEnum(res.status), .body = try alloc.dupe(u8, out.written()) };
}

pub fn fetchUrlHeaders(alloc: std.mem.Allocator, url: []const u8, method: []const u8, payload: ?[]const u8, headers: []const std.http.Header) !FetchResult {
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var m: std.http.Method = .GET;
    if (std.mem.eql(u8, method, "POST")) m = .POST;
    if (std.mem.eql(u8, method, "PUT")) m = .PUT;
    if (std.mem.eql(u8, method, "DELETE")) m = .DELETE;
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = m,
        .payload = payload,
        .response_writer = &out.writer,
        .keep_alive = false,
        .extra_headers = headers,
    });
    return .{ .status = @intFromEnum(res.status), .body = try alloc.dupe(u8, out.written()) };
}

/// Streaming fetch (http only): invokes `on_chunk` with decoded body bytes
/// as they arrive (incremental, not buffered-to-completion) and returns the
/// HTTP status. https URLs return error.UnsupportedProtocol so callers can
/// fall back to buffered TLS fetch.
pub fn fetchUrlHeadersStream(
    alloc: std.mem.Allocator,
    url: []const u8,
    method: []const u8,
    payload: ?[]const u8,
    headers: []const std.http.Header,
    on_chunk: *const fn (*anyopaque, []const u8) anyerror!void,
    on_ctx: *anyopaque,
) !u16 {
    if (!std.mem.startsWith(u8, url, "http://")) return error.UnsupportedProtocol;
    const url_rest = url["http://".len..];
    const path_idx = std.mem.indexOfScalar(u8, url_rest, '/') orelse return error.UnsupportedUriScheme;
    const authority = url_rest[0..path_idx];
    const path = url_rest[path_idx..];
    var host: []const u8 = authority;
    var port: u16 = 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |ci| {
        host = authority[0..ci];
        port = try std.fmt.parseInt(u16, authority[ci + 1 ..], 10);
    }
    if (host.len == 0) return error.UnsupportedUriScheme;
    const body_len = if (payload) |p| p.len else 0;
    var req: std.ArrayListUnmanaged(u8) = .empty;
    defer req.deinit(alloc);
    try req.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s} {s} HTTP/1.1\r\nHost: {s}\r\n", .{ method, path, host }));
    try req.appendSlice(alloc, try std.fmt.allocPrint(alloc, "Content-Length: {d}\r\nConnection: close\r\n", .{body_len}));
    for (headers) |h| {
        try req.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}: {s}\r\n", .{ h.name, h.value }));
    }
    try req.appendSlice(alloc, "\r\n");
    if (payload) |p| try req.appendSlice(alloc, p);
    const host_port = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ host, port });
    defer alloc.free(host_port);
    const addr = addr_block: {
        if (std.net.Address.parseIpAndPort(host_port) catch null) |a| break :addr_block a;
        const a: std.net.Address = try std.net.Address.resolveIp(host, port);
        break :addr_block a;
    };
    const sock = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(sock);
    try posix.connect(sock, &addr.any, addr.getOsSockLen());
    var written: usize = 0;
    while (written < req.items.len) {
        const w = try posix.write(sock, req.items[written..]);
        if (w == 0) return error.ConnectionResetByPeer;
        written += w;
    }
    // Read headers incrementally until \r\n\r\n, keeping leftover body bytes.
    var head_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer head_buf.deinit(alloc);
    var leftover: std.ArrayListUnmanaged(u8) = .empty;
    defer leftover.deinit(alloc);
    var status: u16 = 0;
    var content_length: ?u64 = null;
    var chunked = false;
    {
        var rbuf: [4096]u8 = undefined;
        var found = false;
        while (!found) {
            const n = try posix.read(sock, &rbuf);
            if (n == 0) break;
            try head_buf.appendSlice(alloc, rbuf[0..n]);
            if (std.mem.indexOf(u8, head_buf.items, "\r\n\r\n")) |hi| {
                found = true;
                const hdr_end = hi + 4;
                try leftover.appendSlice(alloc, head_buf.items[hdr_end..]);
                const head = head_buf.items[0..hi];
                if (std.mem.indexOfScalar(u8, head, ' ')) |sp1| {
                    const rest = head[sp1 + 1 ..];
                    if (std.mem.indexOfScalar(u8, rest, ' ')) |sp2| {
                        status = std.fmt.parseInt(u16, rest[0..sp2], 10) catch 0;
                    }
                }
                var line_iter = std.mem.splitSequence(u8, head, "\r\n");
                while (line_iter.next()) |line| {
                    const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                    const name = std.mem.trim(u8, line[0..colon], " \t");
                    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
                    if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                        content_length = std.fmt.parseInt(u64, value, 10) catch null;
                    } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
                        if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) chunked = true;
                    }
                }
            }
        }
        if (!found) return error.ConnectionResetByPeer;
        if (status == 0) return error.ConnectionResetByPeer;
    }
    var received: u64 = 0;
    var rbuf: [4096]u8 = undefined;
    if (chunked) {
        // Decode chunked framing incrementally.
        var pending: std.ArrayListUnmanaged(u8) = .empty;
        defer pending.deinit(alloc);
        try pending.appendSlice(alloc, leftover.items);
        leftover.clearRetainingCapacity();
        while (true) {
            // Ensure a full chunk-size line.
            while (std.mem.indexOf(u8, pending.items, "\r\n") == null) {
                const n = try posix.read(sock, &rbuf);
                if (n == 0) return status;
                try pending.appendSlice(alloc, rbuf[0..n]);
            }
            const line_end = std.mem.indexOf(u8, pending.items, "\r\n").?;
            const line = std.mem.trim(u8, pending.items[0..line_end], " \r");
            const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
            const chunk_len = std.fmt.parseInt(u64, line[0..semi], 16) catch return error.HttpChunkInvalid;
            try pending.replaceRange(alloc, 0, line_end + 2, &.{});
            if (chunk_len == 0) break;
            var chunk_left = chunk_len;
            while (chunk_left > 0) {
                if (pending.items.len == 0) {
                    const n = try posix.read(sock, &rbuf);
                    if (n == 0) break;
                    try pending.appendSlice(alloc, rbuf[0..n]);
                } else {
                    const take: usize = @intCast(@min(chunk_left, @as(u64, @intCast(pending.items.len))));
                    try on_chunk(on_ctx, pending.items[0..take]);
                    try pending.replaceRange(alloc, 0, take, &.{});
                    chunk_left -= take;
                }
            }
            // Consume trailing \r\n after chunk data.
            while (pending.items.len < 2) {
                const n = try posix.read(sock, &rbuf);
                if (n == 0) break;
                try pending.appendSlice(alloc, rbuf[0..n]);
            }
            if (pending.items.len >= 2) try pending.replaceRange(alloc, 0, 2, &.{});
        }
        return status;
    }
    if (leftover.items.len > 0) {
        try on_chunk(on_ctx, leftover.items);
        received += leftover.items.len;
        leftover.clearRetainingCapacity();
    }
    if (content_length) |cl| {
        while (received < cl) {
            const n = try posix.read(sock, &rbuf);
            if (n == 0) break;
            const take: u64 = @min(@as(u64, @intCast(n)), cl - received);
            try on_chunk(on_ctx, rbuf[0..@intCast(take)]);
            received += take;
        }
    } else {
        while (true) {
            const n = try posix.read(sock, &rbuf);
            if (n == 0) break;
            try on_chunk(on_ctx, rbuf[0..n]);
        }
    }
    return status;
}

test "buildHttpRequest" {
    const alloc = std.testing.allocator;
    const r = try buildHttpRequest(alloc, "example.com", "/v1/chat", "{}");
    defer alloc.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "POST /v1/chat") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "Content-Length: 2") != null);
}

test "splitHttpResponse" {
    const s = splitHttpResponse("HTTP/1.1 200 OK\r\n\r\n{\"ok\":1}");
    try std.testing.expectEqual(@as(u16, 200), s.status);
    try std.testing.expectEqualStrings("{\"ok\":1}", s.body);
}
