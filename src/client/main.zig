const std = @import("std");
const protocol = @import("common");
const posix = std.posix;

fn printUsage() void {
    const e = std.fs.File.stderr();
    e.writeAll("Usage: st-client [--host 127.0.0.1] [--port 8000] <method> [params-json]\n") catch {};
    e.writeAll("  e.g. st-client ping\n       st-client version\n       st-client settings.get '{}'\n") catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 8000;
    var method: ?[]const u8 = null;
    var params: []const u8 = "{}";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, args[i], "--host") and i + 1 < args.len) {
            host = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 1;
        } else if (method == null) {
            method = args[i];
        } else {
            params = args[i];
        }
    }
    if (method == null) {
        printUsage();
        return error.NoMethod;
    }
    const addr_str = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ host, port });
    defer alloc.free(addr_str);
    const addr = try std.net.Address.parseIpAndPort(addr_str);
    const sock = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(sock);
    posix.connect(sock, &addr.any, addr.getOsSockLen()) catch |err| {
        const e = std.fs.File.stderr();
        const m = try std.fmt.allocPrint(alloc, "st-client: cannot connect to {s}:{d}: {}\n", .{ host, port, err });
        defer alloc.free(m);
        e.writeAll(m) catch {};
        return err;
    };
    const req_line = try std.fmt.allocPrint(alloc, "{{\"method\":\"{s}\",\"params\":{s}}}\n", .{ method.?, params });
    defer alloc.free(req_line);
    _ = posix.write(sock, req_line) catch return error.WriteFailed;
    var buf: [65536]u8 = undefined;
    const n = posix.read(sock, &buf) catch return error.ReadFailed;
    const out = std.fs.File.stdout();
    out.writeAll(buf[0..n]) catch {};
}
