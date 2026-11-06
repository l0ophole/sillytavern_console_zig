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
