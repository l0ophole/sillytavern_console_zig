const std = @import("std");
const protocol = @import("common");
const store = @import("store");
const crud = @import("crud");
const tokenizer = @import("tokenizer");
const backend = @import("backend");
const png = @import("png");
const users_mod = @import("users");
const vectors_mod = @import("vectors");
const zipm = @import("zipm");
const posix = std.posix;

var data_root: []const u8 = "data";
var port: u16 = 8000;
var host: []const u8 = "127.0.0.1";

fn printUsage() void {
    const stderr = std.fs.File.stderr();
    stderr.writeAll("Usage: st-server [--host 127.0.0.1] [--port 8000] [--data-dir ./data]\n") catch {};
}

fn lowerCase(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
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

// Generic text/binary file handler for files/backgrounds/avatars/sprites/images/assets/thumbnails.
fn genericFiles(alloc: std.mem.Allocator, udir: []const u8, subdir: []const u8, action: []const u8, req: protocol.Request) ![]u8 {
    const dir = try std.fs.path.join(alloc, &.{ udir, subdir });
    defer alloc.free(dir);
    std.fs.cwd().makePath(dir) catch {};
    if (std.mem.eql(u8, action, "list")) {
        const names = crud.listNames(alloc, dir) catch return protocol.encodeOk(alloc, "[]");
        defer { for (names) |nm| alloc.free(nm); alloc.free(names); }
        const arr = try crud.jsonArrayOfNames(alloc, names);
        defer alloc.free(arr);
        return protocol.encodeOk(alloc, arr);
    } else if (std.mem.eql(u8, action, "save") or std.mem.eql(u8, action, "upload") or std.mem.eql(u8, action, "create")) {
        const name = getStr(req, "name") orelse return protocol.encodeErr(alloc, "bad_request");
        if (!protocol.isSafeName(name)) return protocol.encodeErr(alloc, "bad_name");
        const content = getStr(req, "content") orelse getStr(req, "data") orelse return protocol.encodeErr(alloc, "bad_request");
        const path = try std.fs.path.join(alloc, &.{ dir, name });
        defer alloc.free(path);
        try store.writeAtomic(path, content);
        return protocol.encodeOk(alloc, "{\"saved\":true}");
    } else if (std.mem.eql(u8, action, "get") or std.mem.eql(u8, action, "load")) {
        const name = getStr(req, "name") orelse return protocol.encodeErr(alloc, "bad_request");
        if (!protocol.isSafeName(name)) return protocol.encodeErr(alloc, "bad_name");
        const content = crud.loadFile(alloc, dir, name) catch return protocol.encodeErr(alloc, "not_found");
        defer alloc.free(content);
        const q = try protocol.jsonQuote(alloc, content);
        defer alloc.free(q);
        const inner = try std.fmt.allocPrint(alloc, "{{\"content\":{s}}}", .{q});
        defer alloc.free(inner);
        return protocol.encodeOk(alloc, inner);
    } else if (std.mem.eql(u8, action, "delete")) {
        const name = getStr(req, "name") orelse return protocol.encodeErr(alloc, "bad_request");
        if (!protocol.isSafeName(name)) return protocol.encodeErr(alloc, "bad_name");
        crud.deleteFile(alloc, dir, name) catch return protocol.encodeErr(alloc, "not_found");
        return protocol.encodeOk(alloc, "{\"deleted\":true}");
    } else if (std.mem.eql(u8, action, "verify")) {
        // verify {urls:[...]} -> {url:exists}
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        try out.append(alloc, '{');
        if (getObjValue(req, "urls")) |uv| {
            if (uv == .array) {
                for (uv.array.items, 0..) |item, idx| {
                    if (idx > 0) try out.append(alloc, ',');
                    if (item == .string) {
                        const exists = blk: {
                            const p = std.fs.path.join(alloc, &.{ dir, item.string }) catch break :blk false;
                            defer alloc.free(p);
                            std.fs.cwd().access(p, .{}) catch break :blk false;
                            break :blk true;
                        };
                        const kq = try protocol.jsonQuote(alloc, item.string);
                        defer alloc.free(kq);
                        try out.appendSlice(alloc, kq);
                        try out.append(alloc, ':');
                        try out.appendSlice(alloc, if (exists) "true" else "false");
                    }
                }
            }
        }
        try out.append(alloc, '}');
        const s = try out.toOwnedSlice(alloc);
        defer alloc.free(s);
        return protocol.encodeOk(alloc, s);
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
    } else if (std.mem.startsWith(u8, req.method, "files.") or std.mem.startsWith(u8, req.method, "backgrounds.") or std.mem.startsWith(u8, req.method, "avatars.") or std.mem.startsWith(u8, req.method, "sprites.") or std.mem.startsWith(u8, req.method, "images.") or std.mem.startsWith(u8, req.method, "assets.") or std.mem.startsWith(u8, req.method, "thumbnails.")) {
        const dot = std.mem.indexOfScalar(u8, req.method, '.') orelse {
            resp = protocol.encodeErr(alloc, "unknown_method") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const prefix = req.method[0..dot];
        const action = req.method[dot + 1 ..];
        resp = genericFiles(alloc, udir, prefix, action, req) catch {
            resp = protocol.encodeErr(alloc, "io_error") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
    } else if (std.mem.eql(u8, req.method, "data-maid.scan")) {
        // Walk one level under user dir, return file count per subdir.
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        out.append(alloc, '{') catch return;
        var first = true;
        var root = std.fs.cwd().openDir(udir, .{ .iterate = true }) catch {
            resp = protocol.encodeOk(alloc, "{}") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer root.close();
        var it = root.iterate();
        while (it.next() catch null) |e| {
            if (e.kind != .directory) continue;
            const sub = std.fs.path.join(alloc, &.{ udir, e.name }) catch continue;
            defer alloc.free(sub);
            const names = crud.listNames(alloc, sub) catch &[_][]u8{};
            if (!first) out.append(alloc, ',') catch return;
            first = false;
            const kq = protocol.jsonQuote(alloc, e.name) catch return;
            defer alloc.free(kq);
            out.appendSlice(alloc, kq) catch return;
            out.append(alloc, ':') catch return;
            const cs = std.fmt.allocPrint(alloc, "{d}", .{names.len}) catch return;
            defer alloc.free(cs);
            out.appendSlice(alloc, cs) catch return;
        }
        out.append(alloc, '}') catch return;
        const s = out.toOwnedSlice(alloc) catch return;
        defer alloc.free(s);
        resp = protocol.encodeOk(alloc, s) catch return;
    } else if (std.mem.startsWith(u8, req.method, "presets.") or std.mem.startsWith(u8, req.method, "worldinfo.") or std.mem.startsWith(u8, req.method, "groups.") or std.mem.startsWith(u8, req.method, "themes.") or std.mem.startsWith(u8, req.method, "moving-ui.") or std.mem.startsWith(u8, req.method, "quick-replies.")) {
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
        if (std.mem.eql(u8, prefix, "moving-ui")) subdir = "moving-ui";
        if (std.mem.eql(u8, prefix, "quick-replies")) subdir = "quick-replies";
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
        if (getStr(req, "url")) |u| {
            // HTTPS-capable path via std.http.Client
            const fetched = backend.fetchUrl(alloc, u, "POST", body_str) catch {
                resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            defer alloc.free(fetched.body);
            const q2 = protocol.jsonQuote(alloc, fetched.body) catch return;
            defer alloc.free(q2);
            const inner2 = std.fmt.allocPrint(alloc, "{{\"status\":{d},\"body\":{s}}}", .{ fetched.status, q2 }) catch return;
            defer alloc.free(inner2);
            resp = protocol.encodeOk(alloc, inner2) catch return;
            // fall through to common write below (resp already set; skip forwardHttp by returning via goto-like)
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
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
    } else if (std.mem.eql(u8, req.method, "stats.summary")) {
        const subs = [_][]const u8{ "characters", "presets", "worldinfo", "groups", "themes", "backups" };
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        out.append(alloc, '{') catch return;
        var first = true;
        for (subs) |s| {
            const d = std.fs.path.join(alloc, &.{ udir, s }) catch return;
            defer alloc.free(d);
            const names = crud.listNames(alloc, d) catch &[_][]u8{};
            if (!first) out.append(alloc, ',') catch return;
            first = false;
            const key = protocol.jsonQuote(alloc, s) catch return;
            defer alloc.free(key);
            out.appendSlice(alloc, key) catch return;
            out.append(alloc, ':') catch return;
            const cnt_s = std.fmt.allocPrint(alloc, "{d}", .{names.len}) catch return;
            defer alloc.free(cnt_s);
            out.appendSlice(alloc, cnt_s) catch return;
        }
        // chats count
        const chat_root = std.fs.path.join(alloc, &.{ udir, "chats" }) catch return;
        defer alloc.free(chat_root);
        var chat_count: usize = 0;
        if (std.fs.cwd().openDir(chat_root, .{ .iterate = true })) |cd| {
            var cdir = cd;
            defer cdir.close();
            var it = cdir.iterate();
            while (it.next() catch null) |ch_entry| {
                if (ch_entry.kind != .directory) continue;
                const sub = std.fs.path.join(alloc, &.{ chat_root, ch_entry.name }) catch continue;
                defer alloc.free(sub);
                if (crud.listNames(alloc, sub)) |ns| {
                    chat_count += ns.len;
                    for (ns) |nm| alloc.free(nm);
                    alloc.free(ns);
                } else |_| {}
            }
        } else |_| {}
        out.append(alloc, ',') catch return;
        const ck = protocol.jsonQuote(alloc, "chats") catch return;
        defer alloc.free(ck);
        out.appendSlice(alloc, ck) catch return;
        out.append(alloc, ':') catch return;
        const cc_s = std.fmt.allocPrint(alloc, "{d}", .{chat_count}) catch return;
        defer alloc.free(cc_s);
        out.appendSlice(alloc, cc_s) catch return;
        out.append(alloc, '}') catch return;
        const s = out.toOwnedSlice(alloc) catch return;
        defer alloc.free(s);
        resp = protocol.encodeOk(alloc, s) catch return;
    } else if (std.mem.eql(u8, req.method, "backups.create")) {
        const bname = getStr(req, "name") orelse "backup";
        if (!protocol.isSafeName(bname)) {
            resp = protocol.encodeErr(alloc, "bad_name") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        const spath = std.fs.path.join(alloc, &.{ udir, "settings.json" }) catch return;
        defer alloc.free(spath);
        const content = store.readFileAlloc(alloc, spath) catch alloc.dupe(u8, "{}") catch return;
        defer alloc.free(content);
        const bdir = std.fs.path.join(alloc, &.{ udir, "backups" }) catch return;
        defer alloc.free(bdir);
        std.fs.cwd().makePath(bdir) catch {};
        const fname = std.fmt.allocPrint(alloc, "{s}.json", .{bname}) catch return;
        defer alloc.free(fname);
        const bpath = std.fs.path.join(alloc, &.{ bdir, fname }) catch return;
        defer alloc.free(bpath);
        store.writeAtomic(bpath, content) catch {
            resp = protocol.encodeErr(alloc, "io_error") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        resp = protocol.encodeOk(alloc, "{\"saved\":true}") catch return;
    } else if (std.mem.eql(u8, req.method, "backups.list")) {
        const bdir = std.fs.path.join(alloc, &.{ udir, "backups" }) catch return;
        defer alloc.free(bdir);
        const names = crud.listNames(alloc, bdir) catch {
            resp = protocol.encodeOk(alloc, "[]") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer { for (names) |nm| alloc.free(nm); alloc.free(names); }
        const arr = crud.jsonArrayOfNames(alloc, names) catch return;
        defer alloc.free(arr);
        resp = protocol.encodeOk(alloc, arr) catch return;
    } else if (std.mem.eql(u8, req.method, "characters.import_png") or std.mem.eql(u8, req.method, "characters.import")) {
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
        const content_b64 = getStr(req, "content") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        // content may be base64 PNG or plain JSON card
        var card_json: []u8 = undefined;
        if (std.mem.startsWith(u8, std.mem.trim(u8, content_b64, " \t\r\n"), "{")) {
            card_json = alloc.dupe(u8, content_b64) catch return;
        } else {
            const dec = std.base64.standard.Decoder;
            const sz = dec.calcSizeForSlice(content_b64) catch {
                resp = protocol.encodeErr(alloc, "bad_base64") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            const raw = alloc.alloc(u8, sz) catch return;
            defer alloc.free(raw);
            dec.decode(raw, content_b64) catch {
                resp = protocol.encodeErr(alloc, "bad_base64") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            if (png.isPng(raw)) {
                const txt = png.extractTextChunk(alloc, raw, "chara") catch {
                    resp = protocol.encodeErr(alloc, "no_chara") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                };
                if (txt == null) {
                    resp = protocol.encodeErr(alloc, "no_chara") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                }
                defer alloc.free(txt.?);
                card_json = png.decodeChara(alloc, txt.?) catch {
                    resp = protocol.encodeErr(alloc, "bad_card") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                };
            } else {
                card_json = alloc.dupe(u8, raw) catch return;
            }
        }
        defer alloc.free(card_json);
        const cdir = std.fs.path.join(alloc, &.{ udir, "characters" }) catch return;
        defer alloc.free(cdir);
        const fname = std.fmt.allocPrint(alloc, "{s}.json", .{name}) catch return;
        defer alloc.free(fname);
        const cpath = std.fs.path.join(alloc, &.{ cdir, fname }) catch return;
        defer alloc.free(cpath);
        store.writeAtomic(cpath, card_json) catch {
            resp = protocol.encodeErr(alloc, "io_error") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        resp = protocol.encodeOk(alloc, "{\"saved\":true}") catch return;
    } else if (std.mem.eql(u8, req.method, "image-metadata.get") or std.mem.eql(u8, req.method, "image-metadata.detect")) {
        var raw: []u8 = undefined;
        if (getStr(req, "content")) |cb64| {
            const dec = std.base64.standard.Decoder;
            const sz = dec.calcSizeForSlice(cb64) catch {
                resp = protocol.encodeErr(alloc, "bad_base64") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            raw = alloc.alloc(u8, sz) catch return;
            dec.decode(raw, cb64) catch {
                resp = protocol.encodeErr(alloc, "bad_base64") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
        } else if (getStr(req, "name")) |fname| {
            if (!protocol.isSafeName(fname)) {
                resp = protocol.encodeErr(alloc, "bad_name") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            }
            const idir = std.fs.path.join(alloc, &.{ udir, "images" }) catch return;
            defer alloc.free(idir);
            raw = crud.loadFile(alloc, idir, fname) catch {
                resp = protocol.encodeErr(alloc, "not_found") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
        } else {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        const fmt = png.detectFormat(raw);
        var w: u32 = 0;
        var h: u32 = 0;
        if (png.pngSize(raw)) |sz| {
            w = sz[0];
            h = sz[1];
        }
        const inner = std.fmt.allocPrint(alloc, "{{\"format\":\"{s}\",\"width\":{d},\"height\":{d},\"bytes\":{d}}}", .{ fmt, w, h, raw.len }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.startsWith(u8, req.method, "users.") or std.mem.startsWith(u8, req.method, "users-admin.") or std.mem.startsWith(u8, req.method, "users-private.") or std.mem.startsWith(u8, req.method, "users-public.")) {
        const dot = std.mem.indexOfScalar(u8, req.method, '.') orelse {
            resp = protocol.encodeErr(alloc, "unknown_method") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const action = req.method[dot + 1 ..];
        const upath = std.fs.path.join(alloc, &.{ data_root, "users.json" }) catch return;
        defer alloc.free(upath);
        var umap = std.json.ObjectMap.init(alloc);
        if (store.readFileAlloc(alloc, upath)) |existing| {
            if (std.json.parseFromSlice(std.json.Value, alloc, existing, .{})) |parsed| {
                if (parsed.value == .object) umap = parsed.value.object;
            } else |_| {}
        } else |_| {}
        if (std.mem.eql(u8, action, "create")) {
            const handle_s = getStr(req, "handle") orelse {
                resp = protocol.encodeErr(alloc, "bad_request") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            const pw = getStr(req, "password") orelse {
                resp = protocol.encodeErr(alloc, "bad_request") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            if (!protocol.isSafeName(handle_s)) {
                resp = protocol.encodeErr(alloc, "bad_name") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            }
            const h = users_mod.hashPassword(alloc, pw) catch return;
            defer alloc.free(h);
            const nm = getStr(req, "name") orelse handle_s;
            var inner = std.json.ObjectMap.init(alloc);
            inner.put("name", .{ .string = nm }) catch return;
            inner.put("password_hash", .{ .string = h }) catch return;
            var is_admin = false;
            if (getObjValue(req, "admin")) |av| {
                if (av == .bool) is_admin = av.bool;
            }
            inner.put("admin", .{ .bool = is_admin }) catch return;
            umap.put(handle_s, .{ .object = inner }) catch return;
            const uv: std.json.Value = .{ .object = umap };
            const s = store.stringifyValue(alloc, uv) catch return;
            defer alloc.free(s);
            store.writeAtomic(upath, s) catch {
                resp = protocol.encodeErr(alloc, "io_error") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            // Ensure user data dir exists
            const ndir = std.fs.path.join(alloc, &.{ data_root, handle_s }) catch return;
            defer alloc.free(ndir);
            store.ensureUserDirs(ndir) catch {};
            resp = protocol.encodeOk(alloc, "{\"saved\":true}") catch return;
        } else if (std.mem.eql(u8, action, "list")) {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(alloc);
            out.append(alloc, '[') catch return;
            var it = umap.iterator();
            var first = true;
            while (it.next()) |kv| {
                if (!first) out.append(alloc, ',') catch return;
                first = false;
                const q = protocol.jsonQuote(alloc, kv.key_ptr.*) catch return;
                defer alloc.free(q);
                out.appendSlice(alloc, q) catch return;
            }
            out.append(alloc, ']') catch return;
            const s = out.toOwnedSlice(alloc) catch return;
            defer alloc.free(s);
            resp = protocol.encodeOk(alloc, s) catch return;
        } else if (std.mem.eql(u8, action, "delete")) {
            const handle_s = getStr(req, "handle") orelse {
                resp = protocol.encodeErr(alloc, "bad_request") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            _ = umap.orderedRemove(handle_s);
            const uv: std.json.Value = .{ .object = umap };
            const s = store.stringifyValue(alloc, uv) catch return;
            defer alloc.free(s);
            store.writeAtomic(upath, s) catch {
                resp = protocol.encodeErr(alloc, "io_error") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            resp = protocol.encodeOk(alloc, "{\"deleted\":true}") catch return;
        } else if (std.mem.eql(u8, action, "login")) {
            const handle_s = getStr(req, "handle") orelse {
                resp = protocol.encodeErr(alloc, "bad_request") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            const pw = getStr(req, "password") orelse {
                resp = protocol.encodeErr(alloc, "bad_request") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            const entry = umap.get(handle_s) orelse {
                resp = protocol.encodeErr(alloc, "bad_credentials") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            if (entry != .object) {
                resp = protocol.encodeErr(alloc, "bad_credentials") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            }
            const stored = entry.object.get("password_hash") orelse {
                resp = protocol.encodeErr(alloc, "bad_credentials") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            if (stored != .string) {
                resp = protocol.encodeErr(alloc, "bad_credentials") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            }
            const ok = users_mod.verifyPassword(alloc, pw, stored.string) catch false;
            if (!ok) {
                resp = protocol.encodeErr(alloc, "bad_credentials") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            }
            // Create session (24h expiry)
            const token = users_mod.generateSessionToken(alloc) catch return;
            defer alloc.free(token);
            const spath = std.fs.path.join(alloc, &.{ data_root, "sessions.json" }) catch return;
            defer alloc.free(spath);
            var smap = std.json.ObjectMap.init(alloc);
            if (store.readFileAlloc(alloc, spath)) |existing| {
                if (std.json.parseFromSlice(std.json.Value, alloc, existing, .{})) |parsed| {
                    if (parsed.value == .object) smap = parsed.value.object;
                } else |_| {}
            } else |_| {}
            const now_s: i64 = @intCast(@divFloor(std.time.milliTimestamp(), 1000));
            var sess = std.json.ObjectMap.init(alloc);
            sess.put("handle", .{ .string = handle_s }) catch return;
            sess.put("expires", .{ .integer = now_s + 86400 }) catch return;
            smap.put(token, .{ .object = sess }) catch return;
            const sv: std.json.Value = .{ .object = smap };
            const ss = store.stringifyValue(alloc, sv) catch return;
            defer alloc.free(ss);
            store.writeAtomic(spath, ss) catch {};
            const inner = std.fmt.allocPrint(alloc, "{{\"token\":\"{s}\",\"handle\":\"{s}\",\"expires\":{d}}}", .{ token, handle_s, now_s + 86400 }) catch return;
            defer alloc.free(inner);
            resp = protocol.encodeOk(alloc, inner) catch return;
        } else if (std.mem.eql(u8, action, "validate") or std.mem.eql(u8, action, "validate_session")) {
            const token = getStr(req, "token") orelse {
                resp = protocol.encodeErr(alloc, "bad_request") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            const spath = std.fs.path.join(alloc, &.{ data_root, "sessions.json" }) catch return;
            defer alloc.free(spath);
            const content = store.readFileAlloc(alloc, spath) catch {
                resp = protocol.encodeErr(alloc, "invalid_session") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch {
                resp = protocol.encodeErr(alloc, "invalid_session") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            if (parsed.value != .object) {
                resp = protocol.encodeErr(alloc, "invalid_session") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            }
            const sess = parsed.value.object.get(token) orelse {
                resp = protocol.encodeErr(alloc, "invalid_session") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            if (sess != .object) {
                resp = protocol.encodeErr(alloc, "invalid_session") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            }
            const exp = sess.object.get("expires") orelse {
                resp = protocol.encodeErr(alloc, "invalid_session") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            const now_s: i64 = @intCast(@divFloor(std.time.milliTimestamp(), 1000));
            if (exp == .integer and exp.integer < now_s) {
                resp = protocol.encodeErr(alloc, "session_expired") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            }
            const handle_s = sess.object.get("handle") orelse {
                resp = protocol.encodeErr(alloc, "invalid_session") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            if (handle_s != .string) {
                resp = protocol.encodeErr(alloc, "invalid_session") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            }
            const inner = std.fmt.allocPrint(alloc, "{{\"handle\":\"{s}\",\"valid\":true}}", .{handle_s.string}) catch return;
            defer alloc.free(inner);
            resp = protocol.encodeOk(alloc, inner) catch return;
        } else if (std.mem.eql(u8, action, "logout")) {
            const token = getStr(req, "token") orelse {
                resp = protocol.encodeOk(alloc, "{\"deleted\":true}") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            const spath = std.fs.path.join(alloc, &.{ data_root, "sessions.json" }) catch return;
            defer alloc.free(spath);
            if (store.readFileAlloc(alloc, spath)) |existing| {
                if (std.json.parseFromSlice(std.json.Value, alloc, existing, .{})) |parsed| {
                    if (parsed.value == .object) {
                        var smap = parsed.value.object;
                        _ = smap.orderedRemove(token);
                        const sv: std.json.Value = .{ .object = smap };
                        if (store.stringifyValue(alloc, sv)) |s| {
                            defer alloc.free(s);
                            store.writeAtomic(spath, s) catch {};
                        } else |_| {}
                    }
                } else |_| {}
            } else |_| {}
            resp = protocol.encodeOk(alloc, "{\"deleted\":true}") catch return;
        } else {
            resp = protocol.encodeErr(alloc, "unknown_method") catch return;
        }
    } else if (std.mem.startsWith(u8, req.method, "vectors.")) {
        const dot = std.mem.indexOfScalar(u8, req.method, '.') orelse {
            resp = protocol.encodeErr(alloc, "unknown_method") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const action = req.method[dot + 1 ..];
        const coll = getStr(req, "collection") orelse "default";
        if (!protocol.isSafeName(coll)) {
            resp = protocol.encodeErr(alloc, "bad_name") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        const cdir = std.fs.path.join(alloc, &.{ udir, "vectors", coll }) catch return;
        defer alloc.free(cdir);
        std.fs.cwd().makePath(cdir) catch {};
        if (std.mem.eql(u8, action, "save") or std.mem.eql(u8, action, "insert") or std.mem.eql(u8, action, "create")) {
            const vid = getStr(req, "id") orelse {
                resp = protocol.encodeErr(alloc, "bad_request") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            if (!protocol.isSafeName(vid)) {
                resp = protocol.encodeErr(alloc, "bad_name") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            }
            var val: std.json.Value = req.params.?;
            if (getObjValue(req, "value")) |v| val = v;
            if (getObjValue(req, "data")) |v| val = v;
            // val should be object with vector; if params has vector directly, wrap
            crud.saveJson(alloc, cdir, vid, val) catch {
                resp = protocol.encodeErr(alloc, "io_error") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            resp = protocol.encodeOk(alloc, "{\"saved\":true}") catch return;
        } else if (std.mem.eql(u8, action, "list")) {
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
        } else if (std.mem.eql(u8, action, "delete")) {
            const vid = getStr(req, "id") orelse {
                resp = protocol.encodeErr(alloc, "bad_request") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            const fname = std.fmt.allocPrint(alloc, "{s}.json", .{vid}) catch return;
            defer alloc.free(fname);
            crud.deleteFile(alloc, cdir, fname) catch {
                resp = protocol.encodeErr(alloc, "not_found") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            resp = protocol.encodeOk(alloc, "{\"deleted\":true}") catch return;
        } else if (std.mem.eql(u8, action, "query") or std.mem.eql(u8, action, "search")) {
            // query vector from params.vector (array of numbers)
            var qvec: []f64 = &[_]f64{};
            var qowned = false;
            if (getObjValue(req, "vector")) |vv| {
                if (vv == .array) {
                    qvec = alloc.alloc(f64, vv.array.items.len) catch return;
                    qowned = true;
                    for (vv.array.items, 0..) |item, idx| {
                        qvec[idx] = switch (item) {
                            .integer => @as(f64, @floatFromInt(item.integer)),
                            .float => item.float,
                            else => 0,
                        };
                    }
                }
            }
            defer if (qowned) alloc.free(qvec);
            var limit: usize = 5;
            if (getObjValue(req, "limit")) |lv| {
                if (lv == .integer) limit = @intCast(lv.integer);
            }
            const names = crud.listNames(alloc, cdir) catch {
                resp = protocol.encodeOk(alloc, "[]") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            defer { for (names) |nm| alloc.free(nm); alloc.free(names); }
            const Scored = struct { id: []const u8, score: f64 };
            var scored: std.ArrayListUnmanaged(Scored) = .empty;
            defer scored.deinit(alloc);
            for (names) |nm| {
                const content = crud.loadFile(alloc, cdir, nm) catch continue;
                defer alloc.free(content);
                if (std.json.parseFromSlice(std.json.Value, alloc, content, .{})) |parsed| {
                    if (parsed.value == .object) {
                        if (parsed.value.object.get("vector")) |vv| {
                            if (vv == .array and vv.array.items.len == qvec.len and qvec.len > 0) {
                                var svec = alloc.alloc(f64, vv.array.items.len) catch continue;
                                defer alloc.free(svec);
                                for (vv.array.items, 0..) |item, idx| {
                                    svec[idx] = switch (item) {
                                        .integer => @as(f64, @floatFromInt(item.integer)),
                                        .float => item.float,
                                        else => 0,
                                    };
                                }
                                const sc = vectors_mod.cosine(qvec, svec);
                                scored.append(alloc, .{ .id = nm, .score = sc }) catch continue;
                            }
                        }
                    }
                } else |_| {}
            }
            std.mem.sort(Scored, scored.items, {}, struct {
                fn lt(_: void, a: Scored, b: Scored) bool {
                    return a.score > b.score;
                }
            }.lt);
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(alloc);
            out.append(alloc, '[') catch return;
            const ntop = @min(limit, scored.items.len);
            for (scored.items[0..ntop], 0..) |s, idx| {
                if (idx > 0) out.append(alloc, ',') catch return;
                const iq = protocol.jsonQuote(alloc, s.id) catch return;
                defer alloc.free(iq);
                const ss = std.fmt.allocPrint(alloc, "{{\"id\":{s},\"score\":{d}}}", .{ iq, s.score }) catch return;
                defer alloc.free(ss);
                out.appendSlice(alloc, ss) catch return;
            }
            out.append(alloc, ']') catch return;
            const arr = out.toOwnedSlice(alloc) catch return;
            defer alloc.free(arr);
            resp = protocol.encodeOk(alloc, arr) catch return;
        } else {
            resp = protocol.encodeErr(alloc, "unknown_method") catch return;
        }
    } else if (std.mem.eql(u8, req.method, "search.query")) {
        const query = getStr(req, "query") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const lower_q = lowerCase(alloc, query) catch return;
        defer alloc.free(lower_q);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        out.append(alloc, '[') catch return;
        var first = true;
        const search_dirs = [_][]const u8{ "characters", "worldinfo", "presets" };
        for (search_dirs) |sd| {
            const d = std.fs.path.join(alloc, &.{ udir, sd }) catch continue;
            defer alloc.free(d);
            const names = crud.listNames(alloc, d) catch continue;
            defer { for (names) |nm| alloc.free(nm); alloc.free(names); }
            for (names) |nm| {
                const content = crud.loadFile(alloc, d, nm) catch continue;
                defer alloc.free(content);
                const lower_c = lowerCase(alloc, content) catch continue;
                defer alloc.free(lower_c);
                var count: usize = 0;
                var pos: usize = 0;
                while (std.mem.indexOf(u8, lower_c[pos..], lower_q)) |idx| {
                    count += 1;
                    pos += idx + lower_q.len;
                    if (pos >= lower_c.len) break;
                }
                if (count > 0) {
                    if (!first) out.append(alloc, ',') catch return;
                    first = false;
                    const fq = std.fmt.allocPrint(alloc, "{s}/{s}", .{ sd, nm }) catch continue;
                    defer alloc.free(fq);
                    const fqq = protocol.jsonQuote(alloc, fq) catch continue;
                    defer alloc.free(fqq);
                    const cs = std.fmt.allocPrint(alloc, "{{\"file\":{s},\"matches\":{d}}}", .{ fqq, count }) catch continue;
                    defer alloc.free(cs);
                    out.appendSlice(alloc, cs) catch return;
                }
            }
        }
        out.append(alloc, ']') catch return;
        const s = out.toOwnedSlice(alloc) catch return;
        defer alloc.free(s);
        resp = protocol.encodeOk(alloc, s) catch return;
    } else if (std.mem.startsWith(u8, req.method, "speech.") or std.mem.startsWith(u8, req.method, "caption.") or std.mem.startsWith(u8, req.method, "classify.") or std.mem.startsWith(u8, req.method, "translate.") or std.mem.startsWith(u8, req.method, "stable-diffusion.") or std.mem.startsWith(u8, req.method, "openai.") or std.mem.startsWith(u8, req.method, "anthropic.") or std.mem.startsWith(u8, req.method, "google.") or std.mem.startsWith(u8, req.method, "azure.") or std.mem.startsWith(u8, req.method, "openrouter.") or std.mem.startsWith(u8, req.method, "novelai.") or std.mem.startsWith(u8, req.method, "horde.") or std.mem.startsWith(u8, req.method, "minimax.") or std.mem.startsWith(u8, req.method, "volcengine.") or std.mem.startsWith(u8, req.method, "nanogpt.") or std.mem.startsWith(u8, req.method, "backends.")) {
        // Generic HTTP proxy to third-party APIs (speech TTS/STT, caption, classify,
        // translate, SD image gen, LLM providers, horde, backends/*).
        // Params: {host, port, path, body} — same shape as backend.chat.
        const bhost = getStr(req, "host") orelse "127.0.0.1";
        const bpath = getStr(req, "path") orelse "/";
        var bport: u16 = 11434;
        if (getObjValue(req, "port")) |pv| {
            if (pv == .integer) bport = @intCast(pv.integer);
        }
        var body_str: []u8 = undefined;
        if (getObjValue(req, "body")) |bv| {
            body_str = store.stringifyValue(alloc, bv) catch return;
        } else if (getStr(req, "text")) |tx| {
            body_str = alloc.dupe(u8, tx) catch return;
        } else {
            body_str = alloc.dupe(u8, "{}") catch return;
        }
        defer alloc.free(body_str);
        const raw = backend.forwardHttp(alloc, bhost, bport, bpath, body_str) catch {
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
    } else if (std.mem.startsWith(u8, req.method, "extensions.") or std.mem.startsWith(u8, req.method, "content-manager.")) {
        const dot = std.mem.indexOfScalar(u8, req.method, '.') orelse {
            resp = protocol.encodeErr(alloc, "unknown_method") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const prefix = req.method[0..dot];
        const action = req.method[dot + 1 ..];
        if (std.mem.eql(u8, prefix, "extensions")) {
            resp = genericFiles(alloc, udir, "extensions", action, req) catch {
                resp = protocol.encodeErr(alloc, "io_error") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
        } else {
            // content-manager.import {name, kind, content} / content-manager.list
            if (std.mem.eql(u8, action, "import")) {
                const name = getStr(req, "name") orelse {
                    resp = protocol.encodeErr(alloc, "bad_request") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                };
                const kind = getStr(req, "kind") orelse "characters";
                const content = getStr(req, "content") orelse {
                    resp = protocol.encodeErr(alloc, "bad_request") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                };
                if (!protocol.isSafeName(name) or !protocol.isSafeName(kind)) {
                    resp = protocol.encodeErr(alloc, "bad_name") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                }
                const tdir = std.fs.path.join(alloc, &.{ udir, kind }) catch return;
                defer alloc.free(tdir);
                std.fs.cwd().makePath(tdir) catch {};
                const fname = std.fmt.allocPrint(alloc, "{s}.json", .{name}) catch return;
                defer alloc.free(fname);
                const tpath = std.fs.path.join(alloc, &.{ tdir, fname }) catch return;
                defer alloc.free(tpath);
                store.writeAtomic(tpath, content) catch {
                    resp = protocol.encodeErr(alloc, "io_error") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                };
                resp = protocol.encodeOk(alloc, "{\"saved\":true}") catch return;
            } else if (std.mem.eql(u8, action, "list")) {
                const kind = getStr(req, "kind") orelse "characters";
                if (!protocol.isSafeName(kind)) {
                    resp = protocol.encodeErr(alloc, "bad_name") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                }
                const tdir = std.fs.path.join(alloc, &.{ udir, kind }) catch return;
                defer alloc.free(tdir);
                const names = crud.listNames(alloc, tdir) catch {
                    resp = protocol.encodeOk(alloc, "[]") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                };
                defer { for (names) |nm| alloc.free(nm); alloc.free(names); }
                const arr = crud.jsonArrayOfNames(alloc, names) catch return;
                defer alloc.free(arr);
                resp = protocol.encodeOk(alloc, arr) catch return;
            } else {
                resp = protocol.encodeErr(alloc, "unknown_method") catch return;
            }
        }
    } else if (std.mem.eql(u8, req.method, "charx.import") or std.mem.eql(u8, req.method, "byaf.import") or std.mem.eql(u8, req.method, "characters.import_zip")) {
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
        const content_b64 = getStr(req, "content") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const dec = std.base64.standard.Decoder;
        const sz = dec.calcSizeForSlice(content_b64) catch {
            resp = protocol.encodeErr(alloc, "bad_base64") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const raw = alloc.alloc(u8, sz) catch return;
        dec.decode(raw, content_b64) catch {
            resp = protocol.encodeErr(alloc, "bad_base64") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        if (!zipm.isZip(raw)) {
            resp = protocol.encodeErr(alloc, "not_zip") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        var card: ?[]u8 = zipm.extractFile(alloc, raw, "card.json") catch null;
        if (card == null) card = zipm.extractFile(alloc, raw, "character.json") catch null;
        if (card == null) {
            resp = protocol.encodeErr(alloc, "no_card") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        defer alloc.free(card.?);
        const cdir = std.fs.path.join(alloc, &.{ udir, "characters" }) catch return;
        defer alloc.free(cdir);
        const fname = std.fmt.allocPrint(alloc, "{s}.json", .{name}) catch return;
        defer alloc.free(fname);
        const cpath = std.fs.path.join(alloc, &.{ cdir, fname }) catch return;
        defer alloc.free(cpath);
        store.writeAtomic(cpath, card.?) catch {
            resp = protocol.encodeErr(alloc, "io_error") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        resp = protocol.encodeOk(alloc, "{\"saved\":true}") catch return;
    } else if (std.mem.eql(u8, req.method, "backend.fetch")) {
        const url = getStr(req, "url") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const fmethod = getStr(req, "method") orelse "GET";
        var payload: ?[]const u8 = null;
        if (getObjValue(req, "body")) |bv| {
            payload = store.stringifyValue(alloc, bv) catch return;
        } else if (getStr(req, "text")) |tx| {
            payload = tx;
        }
        const fetched = backend.fetchUrl(alloc, url, fmethod, payload) catch {
            resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(fetched.body);
        const q = protocol.jsonQuote(alloc, fetched.body) catch return;
        defer alloc.free(q);
        const inner = std.fmt.allocPrint(alloc, "{{\"status\":{d},\"body\":{s}}}", .{ fetched.status, q }) catch return;
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
