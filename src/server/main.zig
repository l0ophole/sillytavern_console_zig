const std = @import("std");
const protocol = @import("common");
const store = @import("store");
const crud = @import("crud");
const tokenizer = @import("tokenizer");
const backend = @import("backend");
const posix = std.posix;

var data_root: []const u8 = "data";
var port: u16 = 8000;
var host: []const u8 = "127.0.0.1";

fn printUsage() void {
    const stderr = std.fs.File.stderr();
    stderr.writeAll("Usage: st-server [--host 127.0.0.1] [--port 8000] [--data-dir ./data]\n") catch {};
}

fn getStr(req: protocol.Request, key: []const u8) ?[]const u8 {
    if (req.params) |p| {
        if (p == .object) {
            if (p.object.get(key)) |v| {
                if (v == .string) return v.string;
            }
        }
    }
    return null;
}

fn getObjValue(req: protocol.Request, key: []const u8) ?std.json.Value {
    if (req.params) |p| {
        if (p == .object) {
            if (p.object.get(key)) |v| return v;
        }
    }
    return null;
}

// Generic JSON collection handler for presets/worldinfo/groups/themes.
fn genericCollection(alloc: std.mem.Allocator, udir: []const u8, subdir: []const u8, action: []const u8, req: protocol.Request) ![]u8 {
    const dir = try std.fs.path.join(alloc, &.{ udir, subdir });
    defer alloc.free(dir);
    std.fs.cwd().makePath(dir) catch {};
    if (std.mem.eql(u8, action, "list")) {
        const names = crud.listNames(alloc, dir) catch return protocol.encodeOk(alloc, "[]");
        defer { for (names) |nm| alloc.free(nm); alloc.free(names); }
        const arr = try crud.jsonArrayOfNames(alloc, names);
        defer alloc.free(arr);
        return protocol.encodeOk(alloc, arr);
    } else if (std.mem.eql(u8, action, "save") or std.mem.eql(u8, action, "create")) {
        const name = getStr(req, "name") orelse return protocol.encodeErr(alloc, "bad_request");
        if (!protocol.isSafeName(name)) return protocol.encodeErr(alloc, "bad_name");
        var val: std.json.Value = req.params.?;
        if (getObjValue(req, "value")) |v| val = v;
        if (getObjValue(req, "data")) |v| val = v;
        try crud.saveJson(alloc, dir, name, val);
        return protocol.encodeOk(alloc, "{\"saved\":true}");
    } else if (std.mem.eql(u8, action, "load") or std.mem.eql(u8, action, "get")) {
        const name = getStr(req, "name") orelse return protocol.encodeErr(alloc, "bad_request");
        if (!protocol.isSafeName(name)) return protocol.encodeErr(alloc, "bad_name");
        const fname = try std.fmt.allocPrint(alloc, "{s}.json", .{name});
        defer alloc.free(fname);
        const content = crud.loadFile(alloc, dir, fname) catch return protocol.encodeErr(alloc, "not_found");
        defer alloc.free(content);
        return protocol.encodeOk(alloc, content);
    } else if (std.mem.eql(u8, action, "delete")) {
        const name = getStr(req, "name") orelse return protocol.encodeErr(alloc, "bad_request");
        if (!protocol.isSafeName(name)) return protocol.encodeErr(alloc, "bad_name");
        const fname = try std.fmt.allocPrint(alloc, "{s}.json", .{name});
        defer alloc.free(fname);
        crud.deleteFile(alloc, dir, fname) catch return protocol.encodeErr(alloc, "not_found");
        return protocol.encodeOk(alloc, "{\"deleted\":true}");
    }
    return protocol.encodeErr(alloc, "unknown_method");
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
    // Resolve user (default-user) for data methods.
    var user: []const u8 = "default-user";
    if (req.params) |p| {
        if (p == .object) {
            if (p.object.get("user")) |uv| {
                if (uv == .string) user = uv.string;
            }
        }
    }
    const udir = store.userDir(alloc, data_root, user) catch {
        const e = protocol.encodeErr(alloc, "bad_user") catch return;
        defer alloc.free(e);
        _ = posix.write(conn, e) catch {};
        return;
    };
    defer alloc.free(udir);
    store.ensureUserDirs(udir) catch {};
    var resp: []u8 = undefined;
    if (std.mem.eql(u8, req.method, "settings.get")) {
        const path = std.fs.path.join(alloc, &.{ udir, "settings.json" }) catch return;
        defer alloc.free(path);
        const content = store.readFileAlloc(alloc, path) catch blk: {
            const d = alloc.dupe(u8, "{}") catch return;
            break :blk d;
        };
        defer alloc.free(content);
        resp = protocol.encodeOk(alloc, content) catch return;
    } else if (std.mem.eql(u8, req.method, "settings.save")) {
        const path = std.fs.path.join(alloc, &.{ udir, "settings.json" }) catch return;
        defer alloc.free(path);
        var to_save: std.json.Value = .{ .object = undefined };
        var have = false;
        if (req.params) |p| {
            if (p == .object and p.object.get("settings") != null) {
                to_save = p.object.get("settings").?;
                have = true;
            } else {
                to_save = p;
                have = true;
            }
        }
        if (!have) {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
        } else {
            const s = store.stringifyValue(alloc, to_save) catch return;
            defer alloc.free(s);
            store.writeAtomic(path, s) catch {
                resp = protocol.encodeErr(alloc, "io_error") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            resp = protocol.encodeOk(alloc, "{\"saved\":true}") catch return;
        }
    } else if (std.mem.eql(u8, req.method, "characters.list")) {
        const cdir = std.fs.path.join(alloc, &.{ udir, "characters" }) catch return;
        defer alloc.free(cdir);
        const names = crud.listNames(alloc, cdir) catch {
            resp = protocol.encodeOk(alloc, "[]") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer { for (names) |nm| alloc.free(nm); alloc.free(names); }
        const arr = crud.jsonArrayOfNames(alloc, names) catch return;
        defer alloc.free(arr);
        resp = protocol.encodeOk(alloc, arr) catch return;
    } else if (std.mem.eql(u8, req.method, "characters.create") or std.mem.eql(u8, req.method, "characters.save")) {
        const name = getStr(req, "name") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        if (!protocol.isSafeName(name)) {
            resp = protocol.encodeErr(alloc, "bad_name") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        const cdir = std.fs.path.join(alloc, &.{ udir, "characters" }) catch return;
        defer alloc.free(cdir);
        var val: std.json.Value = req.params.?;
        if (getObjValue(req, "character")) |cv| val = cv;
        crud.saveJson(alloc, cdir, name, val) catch {
            resp = protocol.encodeErr(alloc, "io_error") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        resp = protocol.encodeOk(alloc, "{\"saved\":true}") catch return;
    } else if (std.mem.eql(u8, req.method, "characters.get")) {
        const name = getStr(req, "name") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const cdir = std.fs.path.join(alloc, &.{ udir, "characters" }) catch return;
        defer alloc.free(cdir);
        const fname = std.fmt.allocPrint(alloc, "{s}.json", .{name}) catch return;
        defer alloc.free(fname);
        const content = crud.loadFile(alloc, cdir, fname) catch {
            resp = protocol.encodeErr(alloc, "not_found") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(content);
        resp = protocol.encodeOk(alloc, content) catch return;
    } else if (std.mem.eql(u8, req.method, "characters.delete")) {
        const name = getStr(req, "name") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const cdir = std.fs.path.join(alloc, &.{ udir, "characters" }) catch return;
        defer alloc.free(cdir);
        const fname = std.fmt.allocPrint(alloc, "{s}.json", .{name}) catch return;
        defer alloc.free(fname);
        crud.deleteFile(alloc, cdir, fname) catch {
            resp = protocol.encodeErr(alloc, "not_found") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        resp = protocol.encodeOk(alloc, "{\"deleted\":true}") catch return;
    } else if (std.mem.eql(u8, req.method, "chats.list")) {
        const ch = getStr(req, "character") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        if (!protocol.isSafeName(ch)) {
            resp = protocol.encodeErr(alloc, "bad_name") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        const cdir = std.fs.path.join(alloc, &.{ udir, "chats", ch }) catch return;
        defer alloc.free(cdir);
        std.fs.cwd().makePath(cdir) catch {};
        const names = crud.listNames(alloc, cdir) catch {
            resp = protocol.encodeOk(alloc, "[]") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer { for (names) |nm| alloc.free(nm); alloc.free(names); }
        const arr = crud.jsonArrayOfNames(alloc, names) catch return;
        defer alloc.free(arr);
        resp = protocol.encodeOk(alloc, arr) catch return;
    } else if (std.mem.eql(u8, req.method, "chats.save")) {
        const ch = getStr(req, "character") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const chat = getStr(req, "chat") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        if (!protocol.isSafeName(ch) or !protocol.isSafeName(chat)) {
            resp = protocol.encodeErr(alloc, "bad_name") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        const cdir = std.fs.path.join(alloc, &.{ udir, "chats", ch }) catch return;
        defer alloc.free(cdir);
        std.fs.cwd().makePath(cdir) catch {};
        const fname = std.fmt.allocPrint(alloc, "{s}.jsonl", .{chat}) catch return;
        defer alloc.free(fname);
        const path = std.fs.path.join(alloc, &.{ cdir, fname }) catch return;
        defer alloc.free(path);
        var content: []u8 = undefined;
        if (getStr(req, "content")) |c| {
            content = alloc.dupe(u8, c) catch return;
        } else if (getObjValue(req, "data")) |d| {
            if (d == .array) {
                var out: std.ArrayListUnmanaged(u8) = .empty;
                defer out.deinit(alloc);
                for (d.array.items) |item| {
                    const s = store.stringifyValue(alloc, item) catch return;
                    defer alloc.free(s);
                    out.appendSlice(alloc, s) catch return;
                    out.append(alloc, '\n') catch return;
                }
                content = out.toOwnedSlice(alloc) catch return;
            } else {
                content = store.stringifyValue(alloc, d) catch return;
            }
        } else {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        defer alloc.free(content);
        store.writeAtomic(path, content) catch {
            resp = protocol.encodeErr(alloc, "io_error") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        resp = protocol.encodeOk(alloc, "{\"saved\":true}") catch return;
    } else if (std.mem.eql(u8, req.method, "chats.load")) {
        const ch = getStr(req, "character") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const chat = getStr(req, "chat") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        if (!protocol.isSafeName(ch) or !protocol.isSafeName(chat)) {
            resp = protocol.encodeErr(alloc, "bad_name") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        const cdir = std.fs.path.join(alloc, &.{ udir, "chats", ch }) catch return;
        defer alloc.free(cdir);
        const fname = std.fmt.allocPrint(alloc, "{s}.jsonl", .{chat}) catch return;
        defer alloc.free(fname);
        const content = crud.loadFile(alloc, cdir, fname) catch {
            resp = protocol.encodeErr(alloc, "not_found") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(content);
        const q = protocol.jsonQuote(alloc, content) catch return;
        defer alloc.free(q);
        const inner = std.fmt.allocPrint(alloc, "{{\"content\":{s}}}", .{q}) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "chats.delete")) {
        const ch = getStr(req, "character") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const chat = getStr(req, "chat") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const cdir = std.fs.path.join(alloc, &.{ udir, "chats", ch }) catch return;
        defer alloc.free(cdir);
        const fname = std.fmt.allocPrint(alloc, "{s}.jsonl", .{chat}) catch return;
        defer alloc.free(fname);
        crud.deleteFile(alloc, cdir, fname) catch {
            resp = protocol.encodeErr(alloc, "not_found") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        resp = protocol.encodeOk(alloc, "{\"deleted\":true}") catch return;
    } else if (std.mem.startsWith(u8, req.method, "presets.") or std.mem.startsWith(u8, req.method, "worldinfo.") or std.mem.startsWith(u8, req.method, "groups.") or std.mem.startsWith(u8, req.method, "themes.")) {
        const dot = std.mem.indexOfScalar(u8, req.method, '.') orelse {
            resp = protocol.encodeErr(alloc, "unknown_method") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const prefix = req.method[0..dot];
        const action = req.method[dot + 1 ..];
        var subdir: []const u8 = prefix;
        if (std.mem.eql(u8, prefix, "presets")) subdir = "presets";
        if (std.mem.eql(u8, prefix, "worldinfo")) subdir = "worldinfo";
        if (std.mem.eql(u8, prefix, "groups")) subdir = "groups";
        if (std.mem.eql(u8, prefix, "themes")) subdir = "themes";
        resp = genericCollection(alloc, udir, subdir, action, req) catch {
            resp = protocol.encodeErr(alloc, "io_error") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
    } else if (std.mem.eql(u8, req.method, "secrets.set")) {
        const key = getStr(req, "key") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const val = getStr(req, "value") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        if (!protocol.isSafeName(key)) {
            resp = protocol.encodeErr(alloc, "bad_name") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        const spath = std.fs.path.join(alloc, &.{ udir, "secrets.json" }) catch return;
        defer alloc.free(spath);
        // Load existing or {}
        var obj_map = std.json.ObjectMap.init(alloc);
        if (store.readFileAlloc(alloc, spath)) |existing| {
            defer alloc.free(existing);
            if (std.json.parseFromSlice(std.json.Value, alloc, existing, .{})) |parsed| {
                if (parsed.value == .object) obj_map = parsed.value.object;
            } else |_| {}
        } else |_| {}
        obj_map.put(key, .{ .string = val }) catch return;
        const tmp_val: std.json.Value = .{ .object = obj_map };
        const s = store.stringifyValue(alloc, tmp_val) catch return;
        defer alloc.free(s);
        store.writeAtomic(spath, s) catch {
            resp = protocol.encodeErr(alloc, "io_error") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        // chmod 0600 best-effort
        if (std.fs.cwd().openFile(spath, .{})) |f| {
            defer f.close();
            posix.fchmod(f.handle, 0o600) catch {};
        } else |_| {}
        resp = protocol.encodeOk(alloc, "{\"saved\":true}") catch return;
    } else if (std.mem.eql(u8, req.method, "secrets.list") or std.mem.eql(u8, req.method, "secrets.get")) {
        const spath = std.fs.path.join(alloc, &.{ udir, "secrets.json" }) catch return;
        defer alloc.free(spath);
        const content = store.readFileAlloc(alloc, spath) catch {
            resp = protocol.encodeOk(alloc, "{}") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(content);
        // Mask values: parse and rebuild with "****"
        if (std.json.parseFromSlice(std.json.Value, alloc, content, .{})) |parsed| {
            if (parsed.value == .object) {
                var masked = std.json.ObjectMap.init(alloc);
                var it = parsed.value.object.iterator();
                while (it.next()) |kv| {
                    masked.put(kv.key_ptr.*, .{ .string = "****" }) catch return;
                }
                const mv: std.json.Value = .{ .object = masked };
                const s = store.stringifyValue(alloc, mv) catch return;
                defer alloc.free(s);
                resp = protocol.encodeOk(alloc, s) catch return;
            } else {
                resp = protocol.encodeOk(alloc, "{}") catch return;
            }
        } else |_| {
            resp = protocol.encodeOk(alloc, "{}") catch return;
        }
    } else if (std.mem.eql(u8, req.method, "tokenizer.estimate")) {
        const text = getStr(req, "text") orelse "";
        const ntok = tokenizer.estimateTokens(text);
        const inner = std.fmt.allocPrint(alloc, "{{\"tokens\":{d},\"estimate\":true}}", .{ntok}) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "backend.chat")) {
        const bhost = getStr(req, "host") orelse "127.0.0.1";
        const bpath = getStr(req, "path") orelse "/v1/chat/completions";
        var bport: u16 = 11434;
        if (getObjValue(req, "port")) |pv| {
            if (pv == .integer) bport = @intCast(pv.integer);
        }
        var body_str: []u8 = undefined;
        if (getObjValue(req, "body")) |bv| {
            body_str = store.stringifyValue(alloc, bv) catch return;
        } else {
            body_str = alloc.dupe(u8, "{}") catch return;
        }
        defer alloc.free(body_str);
        const raw = backend.forwardHttp(alloc, bhost, bport, bpath, body_str) catch |ferr| {
            const emsg = std.fmt.allocPrint(alloc, "backend {s}:{d}{s} err={}\n", .{ bhost, bport, bpath, ferr }) catch "";
            std.fs.File.stderr().writeAll(emsg) catch {};
            resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(raw);
        const split = backend.splitHttpResponse(raw);
        const q = protocol.jsonQuote(alloc, split.body) catch return;
        defer alloc.free(q);
        const inner = std.fmt.allocPrint(alloc, "{{\"status\":{d},\"body\":{s}}}", .{ split.status, q }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "ping")) {
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
