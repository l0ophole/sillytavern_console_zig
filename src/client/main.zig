const std = @import("std");
const protocol = @import("common");
const posix = std.posix;
var unix_path: ?[]const u8 = null;

fn printUsage() void {
    const e = std.fs.File.stderr();
    e.writeAll("Usage: st-client [--host 127.0.0.1] [--port 8000] <method> [params-json]\n") catch {};
    e.writeAll("  e.g. st-client ping\n       st-client version\n       st-client settings.get '{}'\n") catch {};
    e.writeAll("  No method: interactive REPL (/help, /ping, /characters, /exit)\n") catch {};
}

fn loadToken(alloc: std.mem.Allocator) ?[]u8 {
    if (std.posix.getenv("ST_TOKEN")) |v| {
        if (v.len > 0) return alloc.dupe(u8, v) catch null;
    }
    const candidates = [_][]const u8{ std.posix.getenv("ST_TOKEN_FILE") orelse "", "./data/token" };
    for (candidates) |c| {
        if (c.len == 0) continue;
        var buf: [256]u8 = undefined;
        const f = std.fs.cwd().openFile(c, .{}) catch continue;
        defer f.close();
        const n = f.readAll(&buf) catch continue;
        const t = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (t.len >= 16) return alloc.dupe(u8, t) catch null;
    }
    return null;
}

fn sendRequest(alloc: std.mem.Allocator, host: []const u8, port: u16, method: []const u8, params_in: []const u8) ![]u8 {
    // Inject auth token into params object if present
    var params_owned: ?[]u8 = null;
    defer if (params_owned) |p| alloc.free(p);
    var params = params_in;
    if (loadToken(alloc)) |tok| {
        defer alloc.free(tok);
        const t = std.mem.trim(u8, params_in, " \t\r\n");
        if (std.mem.startsWith(u8, t, "{") and std.mem.indexOf(u8, t, "\"token\"") == null) {
            const tq = try protocol.jsonQuote(alloc, tok);
            defer alloc.free(tq);
            if (t.len <= 2) {
                params_owned = try std.fmt.allocPrint(alloc, "{{\"token\":{s}}}", .{tq});
            } else {
                params_owned = try std.fmt.allocPrint(alloc, "{{\"token\":{s},{s}", .{ tq, t[1..] });
            }
            params = params_owned.?;
        }
    }
    const sock: posix.fd_t = blk: {
        if (unix_path) |up| {
            const s = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
            var sa: posix.sockaddr.un = undefined;
            sa.family = posix.AF.UNIX;
            @memset(&sa.path, 0);
            if (up.len >= sa.path.len) return error.PathTooLong;
            @memcpy(sa.path[0..up.len], up);
            try posix.connect(s, @as(*posix.sockaddr, @ptrCast(&sa)), @sizeOf(posix.sockaddr.un));
            break :blk s;
        }
        const addr_str = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ host, port });
        defer alloc.free(addr_str);
        const addr = try std.net.Address.parseIpAndPort(addr_str);
        const s = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
        try posix.connect(s, &addr.any, addr.getOsSockLen());
        break :blk s;
    };
    defer posix.close(sock);
    const mq = try protocol.jsonQuote(alloc, method);
    defer alloc.free(mq);
    const req_line = try std.fmt.allocPrint(alloc, "{{\"method\":{s},\"params\":{s}}}\n", .{ mq, params });
    defer alloc.free(req_line);
    var off: usize = 0;
    while (off < req_line.len) {
        const w = try posix.write(sock, req_line[off..]);
        if (w == 0) return error.Closed;
        off += w;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = try posix.read(sock, &chunk);
        if (n == 0) break;
        try out.appendSlice(alloc, chunk[0..n]);
        if (std.mem.indexOfScalar(u8, chunk[0..n], '\n') != null) break;
    }
    return out.toOwnedSlice(alloc);
}

fn repl(alloc: std.mem.Allocator, host: []const u8, port: u16) !void {
    const out = std.fs.File.stdout();
    const err_out = std.fs.File.stderr();
    out.writeAll("st-client REPL — /help for commands, /exit to quit\n") catch {};
    var read_chunk: [4096]u8 = undefined;
    var pending: std.ArrayListUnmanaged(u8) = .empty;
    defer pending.deinit(alloc);
    var eof = false;
    while (true) {
        out.writeAll("> ") catch {};
        // Fill until newline or EOF
        while (std.mem.indexOfScalar(u8, pending.items, '\n') == null and !eof) {
            const nread = posix.read(posix.STDIN_FILENO, &read_chunk) catch 0;
            if (nread == 0) {
                eof = true;
                break;
            }
            pending.appendSlice(alloc, read_chunk[0..nread]) catch break;
        }
        const nl = std.mem.indexOfScalar(u8, pending.items, '\n') orelse break;
        const line = pending.items[0..nl];
        pending.items = pending.items[nl + 1 ..];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "/exit") or std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "/quit")) break;
        if (std.mem.eql(u8, trimmed, "/help")) {
            out.writeAll("Commands: /ping /version /health /characters /settings /chats /presets /worldinfo /groups /themes /search /vectors /extensions /backups /stats /secrets /users /exit\n  Usage: /<method> [params-json]\n") catch {};
            continue;
        }
        var method: []const u8 = trimmed;
        var params: []const u8 = "{}";
        if (trimmed[0] == '/') {
            method = trimmed[1..];
            if (std.mem.indexOfScalar(u8, method, ' ')) |sp| {
                params = std.mem.trim(u8, method[sp + 1 ..], " ");
                method = method[0..sp];
            }
        }
        // Map frontend-style names to server methods
        if (std.mem.eql(u8, method, "characters")) method = "characters.list";
        if (std.mem.eql(u8, method, "settings")) method = "settings.get";
        if (std.mem.eql(u8, method, "chats")) method = "chats.list";
        if (std.mem.eql(u8, method, "presets")) method = "presets.list";
        if (std.mem.eql(u8, method, "worldinfo")) method = "worldinfo.list";
        if (std.mem.eql(u8, method, "groups")) method = "groups.list";
        if (std.mem.eql(u8, method, "themes")) method = "themes.list";
        if (std.mem.eql(u8, method, "search")) method = "search.query";
        if (std.mem.eql(u8, method, "vectors")) method = "vectors.list";
        if (std.mem.eql(u8, method, "extensions")) method = "extensions.list";
        if (std.mem.eql(u8, method, "backups")) method = "backups.list";
        if (std.mem.eql(u8, method, "stats")) method = "stats.summary";
        if (std.mem.eql(u8, method, "secrets")) method = "secrets.list";
        if (std.mem.eql(u8, method, "users")) method = "users.list";
        const resp = sendRequest(alloc, host, port, method, params) catch |e| {
            const m = std.fmt.allocPrint(alloc, "error: {}\n", .{e}) catch "";
            err_out.writeAll(m) catch {};
            continue;
        };
        defer alloc.free(resp);
        out.writeAll(resp) catch {};
    }
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
        } else if (std.mem.eql(u8, args[i], "--repl")) {
            method = null;
        } else if (std.mem.eql(u8, args[i], "--unix") and i + 1 < args.len) {
            unix_path = args[i + 1];
            i += 1;
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
        try repl(alloc, host, port);
        return;
    }
    const resp = sendRequest(alloc, host, port, method.?, params) catch |err| {
        const e = std.fs.File.stderr();
        const m = try std.fmt.allocPrint(alloc, "st-client: cannot connect to {s}:{d}: {}\n", .{ host, port, err });
        defer alloc.free(m);
        e.writeAll(m) catch {};
        return err;
    };
    defer alloc.free(resp);
    const out = std.fs.File.stdout();
    out.writeAll(resp) catch {};
}
