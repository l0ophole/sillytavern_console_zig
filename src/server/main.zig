const std = @import("std");
const protocol = @import("common");
const posix = std.posix;

var data_root: []const u8 = "data";
var port: u16 = 8000;
var host: []const u8 = "127.0.0.1";

fn printUsage() void {
    const stderr = std.fs.File.stderr();
    stderr.writeAll("Usage: st-server [--host 127.0.0.1] [--port 8000] [--data-dir ./data]\n") catch {};
}

fn readLine(stream: posix.fd_t, buf: []u8) !usize {
    var n: usize = 0;
    while (n < buf.len) {
        var b: [1]u8 = undefined;
        const r = posix.read(stream, &b) catch return n;
        if (r == 0) break;
        buf[n] = b[0];
        n += 1;
        if (b[0] == '\n') break;
        if (n >= protocol.MAX_LINE) return error.TooLarge;
    }
    return n;
}

fn handleClient(conn: posix.fd_t) void {
    defer posix.close(conn);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf = alloc.alloc(u8, protocol.MAX_LINE + 1) catch return;
    defer alloc.free(buf);
    const n = readLine(conn, buf) catch {
        const e = protocol.encodeErr(alloc, "bad_request") catch return;
        defer alloc.free(e);
        _ = posix.write(conn, e) catch {};
        return;
    };
    if (n == 0) return;
    const req = protocol.parseRequest(alloc, buf[0..n]) catch {
        const e = protocol.encodeErr(alloc, "bad_request") catch return;
        defer alloc.free(e);
        _ = posix.write(conn, e) catch {};
        return;
    };
    var resp: []u8 = undefined;
    if (std.mem.eql(u8, req.method, "ping")) {
        resp = protocol.encodeOk(alloc, "{\"pong\":true,\"version\":\"" ++ protocol.VERSION ++ "\"}") catch return;
    } else if (std.mem.eql(u8, req.method, "version")) {
        resp = protocol.encodeOk(alloc, "{\"version\":\"" ++ protocol.VERSION ++ "\",\"name\":\"sillytavern-console-zig\"}") catch return;
    } else if (std.mem.eql(u8, req.method, "health")) {
        const inner = std.fmt.allocPrint(alloc, "{{\"status\":\"ok\",\"data_root\":\"{s}\"}}", .{data_root}) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else {
        resp = protocol.encodeErr(alloc, "unknown_method") catch return;
    }
    defer alloc.free(resp);
    _ = posix.write(conn, resp) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--host") and i + 1 < args.len) {
            host = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--data-dir") and i + 1 < args.len) {
            data_root = args[i + 1];
            i += 1;
        }
    }
    try std.fs.cwd().makePath(data_root);
    const addr_str = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ host, port });
    defer alloc.free(addr_str);
    const addr = try std.net.Address.parseIpAndPort(addr_str);
    const sock = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(sock);
    const one: c_int = 1;
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(one)) catch {};
    try posix.bind(sock, &addr.any, addr.getOsSockLen());
    try posix.listen(sock, 16);
    const out = std.fs.File.stdout();
    const listen_msg = try std.fmt.allocPrint(alloc, "st-server listening on {s}:{d} data={s} version={s}\n", .{ host, port, data_root, protocol.VERSION });
    defer alloc.free(listen_msg);
    out.writeAll(listen_msg) catch {};
    while (true) {
        var cli_addr: posix.sockaddr = undefined;
        var cli_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const conn = posix.accept(sock, &cli_addr, &cli_len, posix.SOCK.CLOEXEC) catch continue;
        handleClient(conn);
    }
}
