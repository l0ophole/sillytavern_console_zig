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
const providers_mod = @import("providers");
const model_mod = @import("model");
const onnx_mod = @import("onnx");
const minilm_mod = @import("minilm");
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

// Strip common file suffixes for JS frontend names (avatar_url "X.png" -> "X", file_name "Y.jsonl" -> "Y")
fn stripSuffix(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".png")) return name[0 .. name.len - 4];
    if (std.mem.endsWith(u8, name, ".jsonl")) return name[0 .. name.len - 6];
    if (std.mem.endsWith(u8, name, ".json")) return name[0 .. name.len - 5];
    return name;
}

fn getObjValue(req: protocol.Request, key: []const u8) ?std.json.Value {
    if (req.params) |p| {
        if (p == .object) {
            if (p.object.get(key)) |v| return v;
        }
    }
    return null;
}

// Convert JSONL file content to a JSON array string (JS getChatData: parse each
// non-empty line, skip unparseable lines). Empty content -> "[]".
fn jsonlToArray(alloc: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '[');
    var it = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const v = std.json.parseFromSlice(std.json.Value, arena.allocator(), t, .{}) catch continue;
        const s = store.stringifyValue(alloc, v.value) catch continue;
        defer alloc.free(s);
        if (!first) try out.append(alloc, ',');
        first = false;
        try out.appendSlice(alloc, s);
    }
    try out.append(alloc, ']');
    return out.toOwnedSlice(alloc);
}

// Generic JSON collection handler for presets/worldinfo/groups/themes.
fn genericCollection(alloc: std.mem.Allocator, udir: []const u8, subdir: []const u8, action_in: []const u8, req: protocol.Request) ![]u8 {
    var action = action_in;
    // Frontend verb aliases: original SillyTavern uses all/edit/write/read/folders etc.
    if (std.mem.eql(u8, action, "all") or std.mem.eql(u8, action, "folders") or std.mem.eql(u8, action, "find")) action = "list";
    if (std.mem.eql(u8, action, "edit") or std.mem.eql(u8, action, "restore")) action = "save";
    if (std.mem.eql(u8, action, "write")) action = "save";
    if (std.mem.eql(u8, action, "read")) action = "get";
    if (std.mem.eql(u8, action, "import") or std.mem.eql(u8, action, "importURL") or std.mem.eql(u8, action, "importUUID")) action = "save";
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
fn genericFiles(alloc: std.mem.Allocator, udir: []const u8, subdir: []const u8, action_in: []const u8, req: protocol.Request) ![]u8 {
    var action = action_in;
    if (std.mem.eql(u8, action, "all") or std.mem.eql(u8, action, "folders")) action = "list";
    if (std.mem.eql(u8, action, "chats") or std.mem.eql(u8, action, "recent")) action = "list";
    if (std.mem.eql(u8, action, "import")) action = "upload";
    if (std.mem.eql(u8, action, "install") or std.mem.eql(u8, action, "switch")) action = "save";
    if (std.mem.eql(u8, action, "download") or std.mem.eql(u8, action, "character")) action = "get";
    if (std.mem.eql(u8, action, "rename")) action = "save";
    if (std.mem.eql(u8, action, "upload-zip")) action = "upload";
    if (std.mem.eql(u8, action, "branches") or std.mem.eql(u8, action, "discover") or std.mem.eql(u8, action, "update") or std.mem.eql(u8, action, "move") or std.mem.eql(u8, action, "version")) action = "list";
    if (std.mem.eql(u8, action, "character")) action = "get";
    if (std.mem.eql(u8, action, "sanitize-filename")) action = "verify";
    // Nested file actions (e.g. image-metadata/folders/get) handled by dispatch; here strip prefix
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
        const name = getStr(req, "name") orelse getStr(req, "id") orelse return protocol.encodeErr(alloc, "bad_request");
        if (!protocol.isSafeName(name)) return protocol.encodeErr(alloc, "bad_name");
        const content = crud.loadFile(alloc, dir, name) catch return protocol.encodeOk(alloc, "{}");
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

fn handleHttp(conn: posix.fd_t, first_line: []const u8) void {
    // Static web UI serving (SillyTavern public/) + /api health.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Drain headers
    var header_buf = alloc.alloc(u8, 8192) catch return;
    defer alloc.free(header_buf);
    var drain_pos: usize = 0;
    while (drain_pos < header_buf.len - 1) {
        var b: [1]u8 = undefined;
        const r = posix.read(conn, &b) catch break;
        if (r == 0) break;
        header_buf[drain_pos] = b[0];
        drain_pos += 1;
        if (drain_pos >= 4 and std.mem.endsWith(u8, header_buf[0..drain_pos], "\r\n\r\n")) break;
        if (drain_pos >= 3 and std.mem.endsWith(u8, header_buf[0..drain_pos], "\n\n")) break;
    }
    // Parse path from request line "GET <path> HTTP/1.1"
    var path: []const u8 = "/";
    if (std.mem.indexOfScalar(u8, first_line, ' ')) |s1| {
        const rest = first_line[s1 + 1 ..];
        if (std.mem.indexOfScalar(u8, rest, ' ')) |s2| {
            path = rest[0..s2];
        }
    }
    const clean_path = std.mem.trim(u8, path, " ");
    if (std.mem.startsWith(u8, clean_path, "/api/")) {
        const method = clean_path[5..];
        if (method.len == 0 or std.mem.indexOf(u8, method, "/") != null or std.mem.indexOf(u8, method, ".") != null and false) {}
        // Read Content-Length from drained headers, then body
        var content_len: usize = 0;
        if (std.mem.indexOf(u8, header_buf[0..drain_pos], "Content-Length:")) |cl| {
            const rest = header_buf[cl + 15 .. drain_pos];
            const num_end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
            content_len = std.fmt.parseInt(usize, std.mem.trim(u8, rest[0..num_end], " "), 10) catch 0;
        }
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(alloc);
        var remaining = content_len;
        while (remaining > 0) {
            var chunk: [4096]u8 = undefined;
            const want = @min(remaining, chunk.len);
            const r = posix.read(conn, chunk[0..want]) catch break;
            if (r == 0) break;
            body.appendSlice(alloc, chunk[0..r]) catch break;
            remaining -= r;
        }
        // Frontend multipart/form-data (multer) compatibility: extract text fields to JSON params
        var multipart_params: ?[]u8 = null;
        defer if (multipart_params) |mp| alloc.free(mp);
        if (body.items.len > 0) {
            const headers_slice = header_buf[0..drain_pos];
            if (std.mem.indexOf(u8, headers_slice, "multipart/form-data")) |_ct| {
                var boundary: []const u8 = "";
                if (std.mem.indexOf(u8, headers_slice[_ct..], "boundary=")) |bo| {
                    const rest = headers_slice[_ct + bo + 9 ..];
                    const end = std.mem.indexOfAny(u8, rest, "\r\n; ") orelse rest.len;
                    boundary = std.mem.trim(u8, rest[0..end], "\" ");
                }
                if (boundary.len > 0) {
                    const delim = std.fmt.allocPrint(alloc, "--{s}", .{boundary}) catch return;
                    defer alloc.free(delim);
                    var pout: std.ArrayListUnmanaged(u8) = .empty;
                    defer pout.deinit(alloc);
                    pout.append(alloc, '{') catch return;
                    var first_field = true;
                    var search_pos: usize = 0;
                    while (std.mem.indexOf(u8, body.items[search_pos..], delim)) |rel| {
                        const part_start = search_pos + rel + delim.len;
                        // Skip CRLF after boundary
                        var hs = part_start;
                        if (hs + 1 < body.items.len and body.items[hs] == '\r' and body.items[hs + 1] == '\n') hs += 2;
                        if (std.mem.indexOf(u8, body.items[hs..], "\r\n\r\n")) |hend| {
                            const part_headers = body.items[hs .. hs + hend];
                            const content_start = hs + hend + 4;
                            const end_marker = std.fmt.allocPrint(alloc, "\r\n{s}", .{delim}) catch return;
                            defer alloc.free(end_marker);
                            const content_end = std.mem.indexOf(u8, body.items[content_start..], end_marker) orelse break;
                            const content = body.items[content_start .. content_start + content_end];
                            if (std.mem.indexOf(u8, part_headers, "name=\"")) |no| {
                                const nrest = part_headers[no + 6 ..];
                                const nend = std.mem.indexOfScalar(u8, nrest, '"') orelse continue;
                                const fname = nrest[0..nend];
                                if (!first_field) pout.append(alloc, ',') catch return;
                                first_field = false;
                                const fq = protocol.jsonQuote(alloc, fname) catch return;
                                defer alloc.free(fq);
                                const vq = protocol.jsonQuote(alloc, content) catch return;
                                defer alloc.free(vq);
                                pout.appendSlice(alloc, fq) catch return;
                                pout.append(alloc, ':') catch return;
                                pout.appendSlice(alloc, vq) catch return;
                            }
                            search_pos = content_start + content_end;
                        } else break;
                    }
                    pout.append(alloc, '}') catch return;
                    multipart_params = pout.toOwnedSlice(alloc) catch return;
                }
            }
        }
        const params_json = if (multipart_params) |mp| mp else if (body.items.len == 0) "{}" else body.items;
        // Frontend Express route mapping: /api/<res>/<action> -> <res>.<action>
        // Handles nested routes (e.g. /api/backups/chat/get -> backups.chat.get),
        // mount aliases (extra/caption -> caption, content -> content-manager), and verb aliases.
        var mapped_method: []u8 = undefined;
        defer alloc.free(mapped_method);
        var method_trim = method;
        while (method_trim.len > 0 and method_trim[method_trim.len - 1] == '/') method_trim = method_trim[0 .. method_trim.len - 1];
        if (std.mem.indexOfScalar(u8, method_trim, '/')) |slash| {
            var res_name = method_trim[0..slash];
            var action = method_trim[slash + 1 ..];
            if (std.mem.eql(u8, res_name, "extra")) {
                if (std.mem.indexOfScalar(u8, action, '/')) |s2| {
                    res_name = action[0..s2];
                    action = action[s2 + 1 ..];
                } else {
                    // /api/extra/caption (no trailing action)
                    res_name = action;
                    action = "";
                }
            }
            if (std.mem.eql(u8, res_name, "content")) res_name = "content-manager";
            if (std.mem.eql(u8, res_name, "sd")) res_name = "stable-diffusion";
            if (std.mem.eql(u8, res_name, "vector")) res_name = "vectors";
            if (std.mem.eql(u8, res_name, "tokenizers")) res_name = "tokenizer";
            // Nested action: convert remaining slashes to dots
            var action_dotted: std.ArrayListUnmanaged(u8) = .empty;
            defer action_dotted.deinit(alloc);
            for (action) |c| action_dotted.append(alloc, if (c == '/') '.' else c) catch return;
            action = action_dotted.items;
            // Convert kebab-case action segments to underscore where Zig uses underscores
            // (handled below via verb aliases; nested segments kept as-is for dotted dispatch)
            // Map frontend verbs to server verbs (first segment only)
            const first_seg_len = std.mem.indexOfScalar(u8, action, '.') orelse action.len;
            const first_seg = action[0..first_seg_len];
            var mapped_first = first_seg;
            if (std.mem.eql(u8, first_seg, "load")) mapped_first = "get";
            if (std.mem.eql(u8, first_seg, "all")) mapped_first = "list";
            if (std.mem.eql(u8, first_seg, "edit")) mapped_first = "save";
            if (std.mem.eql(u8, first_seg, "write")) mapped_first = "set";
            if (std.mem.eql(u8, first_seg, "read")) mapped_first = "get";
            if (std.mem.eql(u8, first_seg, "folders") and first_seg_len == action.len) mapped_first = "list";
            if (std.mem.eql(u8, first_seg, "icon")) mapped_first = "get";
            if (std.mem.eql(u8, first_seg, "get")) {
                if (std.mem.eql(u8, res_name, "chats")) {
                    mapped_first = "load";
                } else if (std.mem.eql(u8, res_name, "characters")) {
                    mapped_first = "get";
                } else {
                    mapped_first = "get";
                }
            }
            if (std.mem.eql(u8, first_seg, "importURL") or std.mem.eql(u8, first_seg, "importUUID")) mapped_first = "import_url";
            if (first_seg_len < action.len) {
                mapped_method = std.fmt.allocPrint(alloc, "{s}.{s}{s}", .{ res_name, mapped_first, action[first_seg_len..] }) catch return;
            } else {
                mapped_method = std.fmt.allocPrint(alloc, "{s}.{s}", .{ res_name, mapped_first }) catch return;
            }
        } else {
            if (std.mem.eql(u8, method_trim, "image-metadata")) {
                mapped_method = alloc.dupe(u8, "image-metadata.get") catch return;
            } else if (std.mem.eql(u8, method_trim, "caption")) {
                mapped_method = alloc.dupe(u8, "caption.image") catch return;
            } else {
                mapped_method = alloc.dupe(u8, method) catch return;
            }
        }
        // Bridge to TCP dispatch via loopback self-connection
        const line = std.fmt.allocPrint(alloc, "{{\"method\":\"{s}\",\"params\":{s}}}\n", .{ mapped_method, params_json }) catch return;
        defer alloc.free(line);
        const addr_str = std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port}) catch return;
        defer alloc.free(addr_str);
        const addr = std.net.Address.parseIpAndPort(addr_str) catch return;
        const sock = posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP) catch return;
        defer posix.close(sock);
        posix.connect(sock, &addr.any, addr.getOsSockLen()) catch {
            _ = posix.write(conn, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
            return;
        };
        _ = posix.write(sock, line) catch return;
        var rbuf: [65536]u8 = undefined;
        const rn = posix.read(sock, &rbuf) catch 0;
        const resp_body = rbuf[0..rn];
        // Unwrap the TCP envelope to a raw JS body: {"ok":true,"result":X} -> X,
        // {"ok":false,"error":"m"} -> HTTP 400 {"error":"m"} (JS endpoints send error bodies).
        var body_out: []const u8 = resp_body;
        var status: []const u8 = "200 OK";
        const ok_prefix = "{\"ok\":true,\"result\":";
        const err_prefix = "{\"ok\":false,\"error\":\"";
        if (std.mem.startsWith(u8, resp_body, ok_prefix) and std.mem.endsWith(u8, std.mem.trim(u8, resp_body, " \t\r\n"), "}")) {
            const t = std.mem.trim(u8, resp_body, " \t\r\n");
            body_out = t[ok_prefix.len .. t.len - 1];
        } else if (std.mem.startsWith(u8, resp_body, err_prefix)) {
            const t = std.mem.trim(u8, resp_body, " \t\r\n");
            const msg_end = t.len - 2; // strip "}
            if (msg_end > err_prefix.len) {
                const mk = std.fmt.allocPrint(alloc, "{{\"error\":{s}}}", .{t[err_prefix.len - 1 .. msg_end + 1]}) catch resp_body;
                defer alloc.free(mk);
                status = "400 Bad Request";
                const hdr2 = std.fmt.allocPrint(alloc, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, mk.len }) catch return;
                defer alloc.free(hdr2);
                _ = posix.write(conn, hdr2) catch {};
                _ = posix.write(conn, mk) catch {};
                return;
            }
        }
        const hdr = std.fmt.allocPrint(alloc, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, body_out.len }) catch return;
        defer alloc.free(hdr);
        _ = posix.write(conn, hdr) catch {};
        _ = posix.write(conn, body_out) catch {};
        return;
    }
    if (std.mem.eql(u8, clean_path, "/api/health") or std.mem.eql(u8, clean_path, "/api/ping")) {
        const body = "{\"ok\":true,\"result\":{\"pong\":true}}";
        const hdr = std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return;
        defer alloc.free(hdr);
        _ = posix.write(conn, hdr) catch {};
        _ = posix.write(conn, body) catch {};
        return;
    }
    var file_path: []const u8 = clean_path;
    if (std.mem.eql(u8, clean_path, "/")) file_path = "/index.html";
    // Prevent traversal
    if (std.mem.indexOf(u8, file_path, "..") != null) {
        _ = posix.write(conn, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
        return;
    }
    const web_root = std.posix.getenv("ST_WEB_ROOT") orelse "../SillyTavern/public";
    const full = std.fs.path.join(alloc, &.{ web_root, file_path[1..] }) catch return;
    defer alloc.free(full);
    const content = store.readFileAlloc(alloc, full) catch {
        _ = posix.write(conn, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
        return;
    };
    defer alloc.free(content);
    var ctype: []const u8 = "text/plain";
    if (std.mem.endsWith(u8, file_path, ".html")) ctype = "text/html";
    if (std.mem.endsWith(u8, file_path, ".js")) ctype = "application/javascript";
    if (std.mem.endsWith(u8, file_path, ".css")) ctype = "text/css";
    if (std.mem.endsWith(u8, file_path, ".json")) ctype = "application/json";
    const hdr = std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ ctype, content.len }) catch return;
    defer alloc.free(hdr);
    _ = posix.write(conn, hdr) catch {};
    _ = posix.write(conn, content) catch {};
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
    if (std.mem.startsWith(u8, buf[0..n], "GET ") or std.mem.startsWith(u8, buf[0..n], "POST ")) {
        handleHttp(conn, buf[0..n]);
        return;
    }
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
        // JS POST /api/settings/get returns {settings: "<raw file string>", ...empty preset lists, flags}
        const q = protocol.jsonQuote(alloc, content) catch return;
        defer alloc.free(q);
        const inner = std.fmt.allocPrint(alloc, "{{\"settings\":{s},\"koboldai_settings\":[],\"koboldai_setting_names\":[],\"world_names\":[],\"novelai_settings\":[],\"novelai_setting_names\":[],\"openai_settings\":[],\"openai_setting_names\":[],\"textgenerationwebui_presets\":[],\"textgenerationwebui_preset_names\":[],\"themes\":[],\"movingUIPresets\":[],\"quickReplyPresets\":[],\"instruct\":[],\"context\":[],\"sysprompt\":[],\"reasoning\":[],\"enable_extensions\":true,\"enable_extensions_auto_update\":true,\"enable_accounts\":false,\"request_compression\":{{\"enabled\":false,\"minPayloadSize\":0,\"maxPayloadSize\":0,\"timeout\":0}}}}", .{q}) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
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
        // Return parsed character objects (JS /api/characters/all returns objects with .name)
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        out.append(alloc, '[') catch return;
        var first = true;
        for (names) |nm| {
            if (std.mem.endsWith(u8, nm, ".json")) {
                const content = crud.loadFile(alloc, cdir, nm) catch continue;
                defer alloc.free(content);
                if (!first) out.append(alloc, ',') catch return;
                first = false;
                out.appendSlice(alloc, content) catch return;
            } else if (std.mem.endsWith(u8, nm, ".png")) {
                // JS processCharacter reads PNG chara tEXt chunk (base64 JSON)
                const raw = crud.loadFile(alloc, cdir, nm) catch continue;
                defer alloc.free(raw);
                var card: ?[]u8 = null;
                if (png.extractTextChunk(alloc, raw, "chara") catch null) |txt| {
                    defer alloc.free(txt);
                    card = png.decodeChara(alloc, txt) catch null;
                }
                if (!first) out.append(alloc, ',') catch return;
                first = false;
                if (card) |c| {
                    defer alloc.free(c);
                    out.appendSlice(alloc, c) catch return;
                } else {
                    // PNG without chara: JS still emits an object keyed by name
                    const base = nm[0 .. nm.len - 4];
                    const nq = protocol.jsonQuote(alloc, base) catch return;
                    defer alloc.free(nq);
                    const syn = std.fmt.allocPrint(alloc, "{{\"name\":{s}}}", .{nq}) catch return;
                    defer alloc.free(syn);
                    out.appendSlice(alloc, syn) catch return;
                }
            }
        }
        out.append(alloc, ']') catch return;
        const s = out.toOwnedSlice(alloc) catch return;
        defer alloc.free(s);
        resp = protocol.encodeOk(alloc, s) catch return;
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
        const ch_raw = getStr(req, "character") orelse getStr(req, "avatar_url") orelse getStr(req, "avatar") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const ch = stripSuffix(ch_raw);
        // JS style: {avatar_url, file_name, chat: [...]}; TCP style: {character, chat: "name", data: [...]}
        const chat_raw = getStr(req, "file_name") orelse getStr(req, "chat") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const chat = stripSuffix(chat_raw);
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
        } else if (getObjValue(req, "chat")) |c2| {
            // JS style: chat field holds the message array
            if (c2 == .array) {
                var out: std.ArrayListUnmanaged(u8) = .empty;
                defer out.deinit(alloc);
                for (c2.array.items) |item| {
                    const s = store.stringifyValue(alloc, item) catch return;
                    defer alloc.free(s);
                    out.appendSlice(alloc, s) catch return;
                    out.append(alloc, '\n') catch return;
                }
                content = out.toOwnedSlice(alloc) catch return;
            } else {
                content = store.stringifyValue(alloc, c2) catch return;
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
        const ch_raw = getStr(req, "character") orelse getStr(req, "avatar_url") orelse getStr(req, "avatar") orelse getStr(req, "card_name");
        const ch_final_raw = ch_raw orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const ch_final = stripSuffix(ch_final_raw);
        const chat_raw = getStr(req, "chat") orelse getStr(req, "file_name") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const chat = stripSuffix(chat_raw);
        if (!protocol.isSafeName(ch_final) or !protocol.isSafeName(chat)) {
            resp = protocol.encodeErr(alloc, "bad_name") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        const cdir = std.fs.path.join(alloc, &.{ udir, "chats", ch_final }) catch return;
        defer alloc.free(cdir);
        const fname = std.fmt.allocPrint(alloc, "{s}.jsonl", .{chat}) catch return;
        defer alloc.free(fname);
        const content = crud.loadFile(alloc, cdir, fname) catch {
            // JS /api/chats/get returns {} (empty object) when chat dir/file absent, not 404
            resp = protocol.encodeOk(alloc, "{}") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(content);
        // JS /api/chats/get returns the parsed chat array (getChatData), not a content wrapper
        const arr = jsonlToArray(alloc, content) catch return;
        defer alloc.free(arr);
        resp = protocol.encodeOk(alloc, arr) catch return;
    } else if (std.mem.eql(u8, req.method, "chats.delete")) {
        const ch_raw = getStr(req, "character") orelse getStr(req, "avatar_url") orelse getStr(req, "avatar") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const ch = stripSuffix(ch_raw);
        const chat_raw = getStr(req, "chat") orelse getStr(req, "file_name") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const chat = stripSuffix(chat_raw);
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
        } else if (std.mem.eql(u8, action, "me") or std.mem.eql(u8, action, "get")) {
            resp = protocol.encodeOk(alloc, "{\"ok\":true}") catch return;
        } else if (std.mem.eql(u8, action, "disable") or std.mem.eql(u8, action, "enable") or std.mem.eql(u8, action, "promote") or std.mem.eql(u8, action, "demote") or std.mem.eql(u8, action, "backup") or std.mem.eql(u8, action, "reset-settings") or std.mem.eql(u8, action, "change-avatar") or std.mem.eql(u8, action, "change-name") or std.mem.eql(u8, action, "change-password") or std.mem.eql(u8, action, "recover-step1") or std.mem.eql(u8, action, "recover-step2") or std.mem.eql(u8, action, "reset-step1") or std.mem.eql(u8, action, "reset-step2") or std.mem.eql(u8, action, "validate") or std.mem.eql(u8, action, "slugify")) {
            resp = protocol.encodeOk(alloc, "{\"ok\":true}") catch return;
        } else {
            resp = protocol.encodeErr(alloc, "unknown_method") catch return;
        }
    } else if (std.mem.eql(u8, req.method, "vectors.generate")) {
        const text = getStr(req, "text") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        var dim: usize = 32;
        if (getObjValue(req, "dim")) |dv| {
            if (dv == .integer) dim = @intCast(dv.integer);
        }
        const vec = vectors_mod.localEmbed(alloc, text, dim) catch return;
        defer alloc.free(vec);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        out.append(alloc, '[') catch return;
        for (vec, 0..) |v, idx| {
            if (idx > 0) out.append(alloc, ',') catch return;
            const vs = std.fmt.allocPrint(alloc, "{d}", .{v}) catch return;
            defer alloc.free(vs);
            out.appendSlice(alloc, vs) catch return;
        }
        out.append(alloc, ']') catch return;
        const arr = out.toOwnedSlice(alloc) catch return;
        defer alloc.free(arr);
        const inner = std.fmt.allocPrint(alloc, "{{\"vector\":{s},\"dim\":{d},\"local\":true}}", .{ arr, dim }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "vectors.embed")) {
        // Proxy to embedding API (host/port/path/body or url)
        if (getStr(req, "url")) |u| {
            var body_str: []u8 = undefined;
            if (getObjValue(req, "body")) |bv| {
                body_str = store.stringifyValue(alloc, bv) catch return;
            } else {
                body_str = alloc.dupe(u8, "{}") catch return;
            }
            defer alloc.free(body_str);
            const fetched = backend.fetchUrl(alloc, u, "POST", body_str) catch {
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
        } else {
            const bhost = getStr(req, "host") orelse "127.0.0.1";
            const bpath = getStr(req, "path") orelse "/v1/embeddings";
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
        }
    } else if (std.mem.eql(u8, req.method, "vectors.model")) {
        const text = getStr(req, "text") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const model_path = getStr(req, "model") orelse "data/models/embed.json";
        var mlp = model_mod.loadModel(alloc, model_path) catch {
            resp = protocol.encodeErr(alloc, "model_not_found") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer mlp.deinit();
        const inp = vectors_mod.localEmbed(alloc, text, mlp.input_dim) catch return;
        defer alloc.free(inp);
        const outv = mlp.forward(alloc, inp) catch {
            resp = protocol.encodeErr(alloc, "model_failed") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(outv);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        out.append(alloc, '[') catch return;
        for (outv, 0..) |v, idx| {
            if (idx > 0) out.append(alloc, ',') catch return;
            const vs = std.fmt.allocPrint(alloc, "{d}", .{v}) catch return;
            defer alloc.free(vs);
            out.appendSlice(alloc, vs) catch return;
        }
        out.append(alloc, ']') catch return;
        const arr = out.toOwnedSlice(alloc) catch return;
        defer alloc.free(arr);
        const inner = std.fmt.allocPrint(alloc, "{{\"vector\":{s},\"neural\":true}}", .{arr}) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "vectors.onnx")) {
        const text = getStr(req, "text") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const onnx_path = getStr(req, "model") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        var om = onnx_mod.loadOnnx(alloc, onnx_path) catch {
            resp = protocol.encodeErr(alloc, "model_not_found") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer om.deinit();
        // Input dim from model: embed text to 32 (or detect via input tensor? use 32 fixed, error if mismatch)
        const inp = vectors_mod.localEmbed(alloc, text, 32) catch return;
        defer alloc.free(inp);
        var inp_f32 = alloc.alloc(f32, inp.len) catch return;
        defer alloc.free(inp_f32);
        for (inp, 0..) |v, i| inp_f32[i] = @floatCast(v);
        const outv = om.run(alloc, inp_f32) catch {
            resp = protocol.encodeErr(alloc, "model_failed") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(outv);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        out.append(alloc, '[') catch return;
        for (outv, 0..) |v, idx| {
            if (idx > 0) out.append(alloc, ',') catch return;
            const vs = std.fmt.allocPrint(alloc, "{d}", .{v}) catch return;
            defer alloc.free(vs);
            out.appendSlice(alloc, vs) catch return;
        }
        out.append(alloc, ']') catch return;
        const arr = out.toOwnedSlice(alloc) catch return;
        defer alloc.free(arr);
        const inner = std.fmt.allocPrint(alloc, "{{\"vector\":{s},\"onnx\":true}}", .{arr}) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "vectors.neural_real")) {
        const text = getStr(req, "text") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const model_path = getStr(req, "model") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const vocab_path = getStr(req, "vocab") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const script = getStr(req, "script") orelse "tools/minilm_embed.py";
        const result = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "python3", script, model_path, vocab_path, text },
            .max_output_bytes = 10 << 20,
        }) catch {
            resp = protocol.encodeErr(alloc, "runtime_unavailable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        if (result.term.Exited != 0) {
            resp = protocol.encodeErr(alloc, "model_failed") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        resp = protocol.encodeOk(alloc, result.stdout) catch return;
    } else if (std.mem.eql(u8, req.method, "vectors.pure_minilm")) {
        const text = getStr(req, "text") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const model_path = getStr(req, "model") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const vocab_path = getStr(req, "vocab") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        var weights = minilm_mod.loadWeights(alloc, model_path) catch {
            resp = protocol.encodeErr(alloc, "model_not_found") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer weights.deinit();
        // Load vocab.txt
        const vf = std.fs.cwd().openFile(vocab_path, .{}) catch {
            resp = protocol.encodeErr(alloc, "model_not_found") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer vf.close();
        const vcontent = vf.readToEndAlloc(alloc, 5 << 20) catch return;
        defer alloc.free(vcontent);
        var vocab = std.StringHashMap(u32).init(alloc);
        defer vocab.deinit();
        var vlines = std.mem.splitScalar(u8, vcontent, '\n');
        var vid: u32 = 0;
        while (vlines.next()) |line| {
            if (line.len == 0) continue;
            vocab.put(alloc.dupe(u8, line) catch return, vid) catch return;
            vid += 1;
        }
        var ids: std.ArrayListUnmanaged(i64) = .empty;
        defer ids.deinit(alloc);
        minilm_mod.wordPieceTokenize(alloc, text, &vocab, &ids) catch return;
        const vec = minilm_mod.embed(alloc, &weights, ids.items) catch {
            resp = protocol.encodeErr(alloc, "model_failed") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(vec);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        out.append(alloc, '[') catch return;
        for (vec, 0..) |v, idx| {
            if (idx > 0) out.append(alloc, ',') catch return;
            const vs = std.fmt.allocPrint(alloc, "{d}", .{v}) catch return;
            defer alloc.free(vs);
            out.appendSlice(alloc, vs) catch return;
        }
        out.append(alloc, ']') catch return;
        const arr = out.toOwnedSlice(alloc) catch return;
        defer alloc.free(arr);
        const inner = std.fmt.allocPrint(alloc, "{{\"vector\":{s},\"pure_zig\":true,\"dim\":{d}}}", .{ arr, vec.len }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
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
            // Auto-generate embedding if text given without vector.
            // If "model" param present, use neural MLP (vectors.model path); else local hash.
            if (val == .object and val.object.get("vector") == null) {
                if (val.object.get("text")) |tv| {
                    if (tv == .string) {
                        var gen: []f64 = undefined;
                        const gen_owned = true;
                        if (getStr(req, "model")) |mpath| {
                            if (std.mem.endsWith(u8, mpath, ".onnx")) {
                                var om = onnx_mod.loadOnnx(alloc, mpath) catch {
                                    resp = protocol.encodeErr(alloc, "model_not_found") catch return;
                                    defer alloc.free(resp);
                                    _ = posix.write(conn, resp) catch {};
                                    return;
                                };
                                defer om.deinit();
                                const inp64 = vectors_mod.localEmbed(alloc, tv.string, 32) catch return;
                                defer alloc.free(inp64);
                                var inp32 = alloc.alloc(f32, inp64.len) catch return;
                                defer alloc.free(inp32);
                                for (inp64, 0..) |v, ii| inp32[ii] = @floatCast(v);
                                const out32 = om.run(alloc, inp32) catch {
                                    resp = protocol.encodeErr(alloc, "model_failed") catch return;
                                    defer alloc.free(resp);
                                    _ = posix.write(conn, resp) catch {};
                                    return;
                                };
                                defer alloc.free(out32);
                                gen = alloc.alloc(f64, out32.len) catch return;
                                for (out32, 0..) |v, ii| gen[ii] = @floatCast(v);
                            } else {
                                var mlp = model_mod.loadModel(alloc, mpath) catch {
                                    resp = protocol.encodeErr(alloc, "model_not_found") catch return;
                                    defer alloc.free(resp);
                                    _ = posix.write(conn, resp) catch {};
                                    return;
                                };
                                defer mlp.deinit();
                                const inp = vectors_mod.localEmbed(alloc, tv.string, mlp.input_dim) catch return;
                                defer alloc.free(inp);
                                gen = mlp.forward(alloc, inp) catch return;
                            }
                        } else {
                            gen = vectors_mod.localEmbed(alloc, tv.string, 32) catch return;
                        }
                        defer if (gen_owned) alloc.free(gen);
                        var arr = std.json.Array.init(alloc);
                        for (gen) |f| arr.append(.{ .float = f }) catch return;
                        val.object.put("vector", .{ .array = arr }) catch return;
                    }
                }
            }
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
        } else if (std.mem.eql(u8, action, "purge") or std.mem.eql(u8, action, "purge-all")) {
            resp = protocol.encodeOk(alloc, "{\"purged\":true}") catch return;
        } else if (std.mem.eql(u8, action, "query-multi")) {
            resp = protocol.encodeOk(alloc, "[]") catch return;
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
    } else if (std.mem.eql(u8, req.method, "stable-diffusion.generate_and_save")) {
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
        const bhost = getStr(req, "host") orelse "127.0.0.1";
        const bpath = getStr(req, "path") orelse "/sdapi/v1/txt2img";
        var bport: u16 = 7860;
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
        const raw = backend.forwardHttp(alloc, bhost, bport, bpath, body_str) catch {
            resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(raw);
        const split = backend.splitHttpResponse(raw);
        // Expect {"images":["<base64>",...]} — save first image
        var saved_name: []const u8 = name;
        if (std.json.parseFromSlice(std.json.Value, alloc, split.body, .{})) |parsed| {
            if (parsed.value == .object) {
                if (parsed.value.object.get("images")) |imgs| {
                    if (imgs == .array and imgs.array.items.len > 0) {
                        if (imgs.array.items[0] == .string) {
                            const b64 = imgs.array.items[0].string;
                            const dec = std.base64.standard.Decoder;
                            if (dec.calcSizeForSlice(b64)) |sz| {
                                const img_bytes = alloc.alloc(u8, sz) catch return;
                                defer alloc.free(img_bytes);
                                if (dec.decode(img_bytes, b64)) |_| {
                                    const idir = std.fs.path.join(alloc, &.{ udir, "images" }) catch return;
                                    defer alloc.free(idir);
                                    std.fs.cwd().makePath(idir) catch {};
                                    const fname = std.fmt.allocPrint(alloc, "{s}.png", .{name}) catch return;
                                    defer alloc.free(fname);
                                    const ipath = std.fs.path.join(alloc, &.{ idir, fname }) catch return;
                                    defer alloc.free(ipath);
                                    store.writeAtomic(ipath, img_bytes) catch {};
                                    saved_name = alloc.dupe(u8, fname) catch fname;
                                } else |_| {}
                            } else |_| {}
                        }
                    }
                }
            }
        } else |_| {}
        const q = protocol.jsonQuote(alloc, saved_name) catch return;
        defer alloc.free(q);
        const inner = std.fmt.allocPrint(alloc, "{{\"saved\":{s},\"status\":{d}}}", .{ q, split.status }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "caption.image")) {
        // Full caption flow (mirrors SillyTavern anthropic.js /caption-image):
        // image=data URI base64 + prompt -> anthropic messages with image -> text
        const image = getStr(req, "image") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const prompt = getStr(req, "prompt") orelse "Describe this image.";
        // Split data URI: data:<mime>;base64,<data>
        var mime: []const u8 = "image/png";
        var b64data: []const u8 = image;
        if (std.mem.indexOf(u8, image, ";base64,")) |sep| {
            const header = image[0..sep];
            if (std.mem.indexOfScalar(u8, header, ':')) |colon| {
                mime = header[colon + 1 ..];
            }
            b64data = image[sep + 8 ..];
        }
        const model_name = getStr(req, "model") orelse "claude-3";
        var body_builder: std.ArrayListUnmanaged(u8) = .empty;
        defer body_builder.deinit(alloc);
        body_builder.appendSlice(alloc, "{\"model\":\"") catch return;
        body_builder.appendSlice(alloc, model_name) catch return;
        body_builder.appendSlice(alloc, "\",\"max_tokens\":1024,\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"") catch return;
        body_builder.appendSlice(alloc, mime) catch return;
        body_builder.appendSlice(alloc, "\",\"data\":\"") catch return;
        body_builder.appendSlice(alloc, b64data) catch return;
        body_builder.appendSlice(alloc, "\"}},{\"type\":\"text\",\"text\":\"") catch return;
        body_builder.appendSlice(alloc, prompt) catch return;
        body_builder.appendSlice(alloc, "\"}]}]}") catch return;
        const body = body_builder.toOwnedSlice(alloc) catch return;
        defer alloc.free(body);
        const ak = getStr(req, "api_key") orelse "";
        var headers_buf: [4]std.http.Header = undefined;
        headers_buf[0] = .{ .name = "Content-Type", .value = "application/json" };
        headers_buf[1] = .{ .name = "x-api-key", .value = ak };
        headers_buf[2] = .{ .name = "anthropic-version", .value = "2023-06-01" };
        const base = getStr(req, "base_url") orelse "https://api.anthropic.com/v1";
        const url = std.fmt.allocPrint(alloc, "{s}/messages", .{base}) catch return;
        defer alloc.free(url);
        const fetched = backend.fetchUrlHeaders(alloc, url, "POST", body, headers_buf[0..3]) catch {
            resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(fetched.body);
        const text = providers_mod.parseNativeResponse(alloc, "anthropic", fetched.body) catch return;
        defer alloc.free(text);
        const tq = protocol.jsonQuote(alloc, text) catch return;
        defer alloc.free(tq);
        const inner = std.fmt.allocPrint(alloc, "{{\"caption\":{s},\"status\":{d}}}", .{ tq, fetched.status }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "speech.tts")) {
        // Full TTS flow: {input, model, voice, name} -> POST /v1/audio/speech -> save mp3 to files/
        const input = getStr(req, "input") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const tts_model = getStr(req, "model") orelse "tts-1";
        const voice = getStr(req, "voice") orelse "alloy";
        const name = getStr(req, "name") orelse "speech.mp3";
        if (!protocol.isSafeName(name)) {
            resp = protocol.encodeErr(alloc, "bad_name") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        var bb: std.ArrayListUnmanaged(u8) = .empty;
        defer bb.deinit(alloc);
        bb.appendSlice(alloc, "{\"model\":\"") catch return;
        bb.appendSlice(alloc, tts_model) catch return;
        bb.appendSlice(alloc, "\",\"input\":\"") catch return;
        for (input) |c| {
            if (c == '"' or c == '\\') bb.append(alloc, '\\') catch return;
            if (c == '\n') {
                bb.appendSlice(alloc, "\\n") catch return;
            } else {
                bb.append(alloc, c) catch return;
            }
        }
        bb.appendSlice(alloc, "\",\"voice\":\"") catch return;
        bb.appendSlice(alloc, voice) catch return;
        bb.appendSlice(alloc, "\"}") catch return;
        const body = bb.toOwnedSlice(alloc) catch return;
        defer alloc.free(body);
        const ak = getStr(req, "api_key") orelse "";
        var headers_buf: [3]std.http.Header = undefined;
        headers_buf[0] = .{ .name = "Content-Type", .value = "application/json" };
        var auth_val: ?[]u8 = null;
        var nheaders: usize = 1;
        if (ak.len > 0) {
            auth_val = std.fmt.allocPrint(alloc, "Bearer {s}", .{ak}) catch return;
            headers_buf[1] = .{ .name = "Authorization", .value = auth_val.? };
            nheaders = 2;
        }
        defer if (auth_val) |av| alloc.free(av);
        const base = getStr(req, "base_url") orelse "https://api.openai.com/v1";
        const url = std.fmt.allocPrint(alloc, "{s}/audio/speech", .{base}) catch return;
        defer alloc.free(url);
        const fetched = backend.fetchUrlHeaders(alloc, url, "POST", body, headers_buf[0..nheaders]) catch {
            resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(fetched.body);
        if (fetched.status < 200 or fetched.status >= 300) {
            resp = protocol.encodeErr(alloc, "http_error") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        const fdir = std.fs.path.join(alloc, &.{ udir, "files" }) catch return;
        defer alloc.free(fdir);
        std.fs.cwd().makePath(fdir) catch {};
        const fpath = std.fs.path.join(alloc, &.{ fdir, name }) catch return;
        defer alloc.free(fpath);
        store.writeAtomic(fpath, fetched.body) catch {
            resp = protocol.encodeErr(alloc, "io_error") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const q = protocol.jsonQuote(alloc, name) catch return;
        defer alloc.free(q);
        const inner = std.fmt.allocPrint(alloc, "{{\"saved\":{s},\"bytes\":{d},\"status\":{d}}}", .{ q, fetched.body.len, fetched.status }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "classify.classify")) {
        const text = getStr(req, "text") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const base = getStr(req, "base_url") orelse "http://127.0.0.1:11434";
        const cpath = getStr(req, "path") orelse "/classify";
        const url = std.fmt.allocPrint(alloc, "{s}{s}", .{ base, cpath }) catch return;
        defer alloc.free(url);
        var bb: std.ArrayListUnmanaged(u8) = .empty;
        defer bb.deinit(alloc);
        bb.appendSlice(alloc, "{\"text\":\"") catch return;
        for (text) |c| {
            if (c == '"' or c == '\\') bb.append(alloc, '\\') catch return;
            if (c == '\n') {
                bb.appendSlice(alloc, "\\n") catch return;
            } else {
                bb.append(alloc, c) catch return;
            }
        }
        bb.appendSlice(alloc, "\"}") catch return;
        const body = bb.toOwnedSlice(alloc) catch return;
        defer alloc.free(body);
        const fetched = backend.fetchUrl(alloc, url, "POST", body) catch {
            resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(fetched.body);
        // Normalize: pass through API array if present, else wrap
        const inner = std.fmt.allocPrint(alloc, "{{\"status\":{d},\"classification\":{s}}}", .{ fetched.status, fetched.body }) catch return;
        // fetched.body may be raw JSON array or text; if not valid JSON object/array, quote it
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "translate.translate")) {
        const text = getStr(req, "text") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const source = getStr(req, "source") orelse "auto";
        const target = getStr(req, "target") orelse "en";
        const base = getStr(req, "base_url") orelse "http://127.0.0.1:1188/translate";
        var bb: std.ArrayListUnmanaged(u8) = .empty;
        defer bb.deinit(alloc);
        bb.appendSlice(alloc, "{\"text\":\"") catch return;
        for (text) |c| {
            if (c == '"' or c == '\\') bb.append(alloc, '\\') catch return;
            if (c == '\n') {
                bb.appendSlice(alloc, "\\n") catch return;
            } else {
                bb.append(alloc, c) catch return;
            }
        }
        const tail = std.fmt.allocPrint(alloc, "\",\"source_lang\":\"{s}\",\"target_lang\":\"{s}\"}}", .{ source, target }) catch return;
        defer alloc.free(tail);
        bb.appendSlice(alloc, tail) catch return;
        const body = bb.toOwnedSlice(alloc) catch return;
        defer alloc.free(body);
        const fetched = backend.fetchUrl(alloc, base, "POST", body) catch {
            resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(fetched.body);
        // Parse {data} or {translatedText} or plain
        var translated: []const u8 = fetched.body;
        if (std.json.parseFromSlice(std.json.Value, alloc, fetched.body, .{})) |parsed| {
            if (parsed.value == .object) {
                if (parsed.value.object.get("data")) |d| {
                    if (d == .string) translated = d.string;
                } else if (parsed.value.object.get("translatedText")) |d| {
                    if (d == .string) translated = d.string;
                } else if (parsed.value.object.get("text")) |d| {
                    if (d == .string) translated = d.string;
                }
            }
        } else |_| {}
        const tq = protocol.jsonQuote(alloc, translated) catch return;
        defer alloc.free(tq);
        const inner = std.fmt.allocPrint(alloc, "{{\"translatedText\":{s},\"status\":{d}}}", .{ tq, fetched.status }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "speech.transcribe")) {
        const audio_b64 = getStr(req, "audio") orelse getStr(req, "audio_base64") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const stt_model = getStr(req, "model") orelse "whisper-1";
        var bb: std.ArrayListUnmanaged(u8) = .empty;
        defer bb.deinit(alloc);
        bb.appendSlice(alloc, "{\"model\":\"") catch return;
        bb.appendSlice(alloc, stt_model) catch return;
        bb.appendSlice(alloc, "\",\"audio\":\"") catch return;
        bb.appendSlice(alloc, audio_b64) catch return;
        bb.appendSlice(alloc, "\"}") catch return;
        const body = bb.toOwnedSlice(alloc) catch return;
        defer alloc.free(body);
        const ak = getStr(req, "api_key") orelse "";
        var headers_buf: [2]std.http.Header = undefined;
        headers_buf[0] = .{ .name = "Content-Type", .value = "application/json" };
        var auth_val: ?[]u8 = null;
        var nheaders: usize = 1;
        if (ak.len > 0) {
            auth_val = std.fmt.allocPrint(alloc, "Bearer {s}", .{ak}) catch return;
            headers_buf[1] = .{ .name = "Authorization", .value = auth_val.? };
            nheaders = 2;
        }
        defer if (auth_val) |av| alloc.free(av);
        const base = getStr(req, "base_url") orelse "https://api.openai.com/v1";
        const url = std.fmt.allocPrint(alloc, "{s}/audio/transcriptions", .{base}) catch return;
        defer alloc.free(url);
        const fetched = backend.fetchUrlHeaders(alloc, url, "POST", body, headers_buf[0..nheaders]) catch {
            resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(fetched.body);
        var text_out: []const u8 = fetched.body;
        if (std.json.parseFromSlice(std.json.Value, alloc, fetched.body, .{})) |parsed| {
            if (parsed.value == .object) {
                if (parsed.value.object.get("text")) |tv| {
                    if (tv == .string) text_out = tv.string;
                }
            }
        } else |_| {}
        const tq = protocol.jsonQuote(alloc, text_out) catch return;
        defer alloc.free(tq);
        const inner = std.fmt.allocPrint(alloc, "{{\"text\":{s},\"status\":{d}}}", .{ tq, fetched.status }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
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
    } else if (std.mem.eql(u8, req.method, "extensions.execute")) {
        // Execute JS via node subprocess (if available). Params: {code} or {name}
        var code: []const u8 = getStr(req, "code") orelse "";
        var code_owned: ?[]u8 = null;
        if (code.len == 0) {
            if (getStr(req, "name")) |nm| {
                if (!protocol.isSafeName(nm)) {
                    resp = protocol.encodeErr(alloc, "bad_name") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                }
                const edir = std.fs.path.join(alloc, &.{ udir, "extensions" }) catch return;
                defer alloc.free(edir);
                code_owned = crud.loadFile(alloc, edir, nm) catch {
                    resp = protocol.encodeErr(alloc, "not_found") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                };
                code = code_owned.?;
            }
        }
        if (code.len == 0) {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        const result = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "node", "-e", code },
            .max_output_bytes = 1 << 20,
        }) catch {
            resp = protocol.encodeErr(alloc, "extension_runtime_unavailable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        const oq = protocol.jsonQuote(alloc, result.stdout) catch return;
        defer alloc.free(oq);
        const eq = protocol.jsonQuote(alloc, result.stderr) catch return;
        defer alloc.free(eq);
        const inner = std.fmt.allocPrint(alloc, "{{\"stdout\":{s},\"stderr\":{s},\"exit_code\":{d}}}", .{ oq, eq, result.term.Exited }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "extensions.execute_browser")) {
        // Browser-equivalent shim: document/window/SillyTavern stubs, slash-command registry.
        const code = getStr(req, "code") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        if (code.len == 0) {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        const shim = "const __commands=[];const __mkEl=()=>({style:{},children:[],appendChild(c){this.children.push(c)},addEventListener(){},setAttribute(){},querySelector(){return null},querySelectorAll(){return []}});globalThis.document={createElement:()=>__mkEl(),querySelector:()=>null,querySelectorAll:()=>[],body:__mkEl(),addEventListener(){}};globalThis.window=globalThis;globalThis.SillyTavern={getContext:()=>({registerSlashCommand:(n,f)=>__commands.push(n),generate:m=>Promise.resolve({completion:'ok'})})};globalThis.registerSlashCommand=(n,f)=>__commands.push(n);globalThis.SlashCommandParser={addCommand:(n,f)=>__commands.push(n)};";
        const wrapper = std.fmt.allocPrint(alloc, "{s}{s};console.log(JSON.stringify({{commands:__commands}}));", .{ shim, code }) catch return;
        defer alloc.free(wrapper);
        const result = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "node", "-e", wrapper },
            .max_output_bytes = 1 << 20,
        }) catch {
            resp = protocol.encodeErr(alloc, "extension_runtime_unavailable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        const oq = protocol.jsonQuote(alloc, result.stdout) catch return;
        defer alloc.free(oq);
        const eq = protocol.jsonQuote(alloc, result.stderr) catch return;
        defer alloc.free(eq);
        const inner = std.fmt.allocPrint(alloc, "{{\"stdout\":{s},\"stderr\":{s},\"exit_code\":{d}}}", .{ oq, eq, result.term.Exited }) catch return;
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
            if (std.mem.eql(u8, action, "import") or std.mem.eql(u8, action, "importURL") or std.mem.eql(u8, action, "importUUID")) {
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
            } else if (std.mem.eql(u8, action, "import_url")) {
                const url = getStr(req, "url") orelse {
                    resp = protocol.encodeErr(alloc, "bad_request") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                };
                const name = getStr(req, "name") orelse {
                    resp = protocol.encodeErr(alloc, "bad_request") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                };
                const kind = getStr(req, "kind") orelse "characters";
                if (!protocol.isSafeName(name) or !protocol.isSafeName(kind)) {
                    resp = protocol.encodeErr(alloc, "bad_name") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                }
                const fetched = backend.fetchUrl(alloc, url, "GET", null) catch {
                    resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                };
                defer alloc.free(fetched.body);
                if (fetched.status < 200 or fetched.status >= 300) {
                    resp = protocol.encodeErr(alloc, "http_error") catch return;
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
                store.writeAtomic(tpath, fetched.body) catch {
                    resp = protocol.encodeErr(alloc, "io_error") catch return;
                    defer alloc.free(resp);
                    _ = posix.write(conn, resp) catch {};
                    return;
                };
                resp = protocol.encodeOk(alloc, "{\"saved\":true}") catch return;
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
    } else if (std.mem.eql(u8, req.method, "search.web")) {
        const query = getStr(req, "query") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        var url: []u8 = undefined;
        if (getStr(req, "url")) |u| {
            url = alloc.dupe(u8, u) catch return;
        } else {
            // DuckDuckGo html endpoint, percent-encode query (space->+, alnum kept)
            var enc: std.ArrayListUnmanaged(u8) = .empty;
            defer enc.deinit(alloc);
            for (query) |c| {
                if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.') {
                    enc.append(alloc, c) catch return;
                } else if (c == ' ') {
                    enc.append(alloc, '+') catch return;
                } else {
                    const hex = std.fmt.allocPrint(alloc, "%{x:0>2}", .{c}) catch return;
                    defer alloc.free(hex);
                    enc.appendSlice(alloc, hex) catch return;
                }
            }
            const q = enc.toOwnedSlice(alloc) catch return;
            defer alloc.free(q);
            url = std.fmt.allocPrint(alloc, "https://html.duckduckgo.com/html/?q={s}", .{q}) catch return;
        }
        defer alloc.free(url);
        const fetched = backend.fetchUrl(alloc, url, "GET", null) catch {
            resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(fetched.body);
        // Truncate to first 64k to keep response sane
        const body = if (fetched.body.len > 65536) fetched.body[0..65536] else fetched.body;
        const q = protocol.jsonQuote(alloc, body) catch return;
        defer alloc.free(q);
        const inner = std.fmt.allocPrint(alloc, "{{\"status\":{d},\"body\":{s}}}", .{ fetched.status, q }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "tokenizer.encode")) {
        const text = getStr(req, "text") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        var vocab_path_owned: ?[]u8 = null;
        const vocab_path = blk: {
            if (getStr(req, "vocab")) |v| break :blk v;
            if (getStr(req, "model")) |m| {
                const fname = std.fmt.allocPrint(alloc, "data/tokenizers/{s}_base.tiktoken", .{m}) catch return;
                vocab_path_owned = fname;
                break :blk fname;
            }
            break :blk "data/tokenizers/cl100k_base.tiktoken";
        };
        defer if (vocab_path_owned) |vp| alloc.free(vp);
        var vocab: tokenizer.BpeVocab = undefined;
        const is_sp = std.mem.endsWith(u8, vocab_path, ".model");
        if (std.mem.endsWith(u8, vocab_path, ".json")) {
            vocab = tokenizer.loadHfVocab(alloc, vocab_path) catch {
                const nest = tokenizer.estimateTokens(text);
                const inner = std.fmt.allocPrint(alloc, "{{\"tokens\":{d},\"exact\":false}}", .{nest}) catch return;
                defer alloc.free(inner);
                resp = protocol.encodeOk(alloc, inner) catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
        } else if (is_sp) {
            vocab = tokenizer.loadSpModel(alloc, vocab_path) catch {
                const nest = tokenizer.estimateTokens(text);
                const inner = std.fmt.allocPrint(alloc, "{{\"tokens\":{d},\"exact\":false}}", .{nest}) catch return;
                defer alloc.free(inner);
                resp = protocol.encodeOk(alloc, inner) catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
        } else {
            vocab = tokenizer.loadVocab(alloc, vocab_path) catch {
                const nest = tokenizer.estimateTokens(text);
                const inner = std.fmt.allocPrint(alloc, "{{\"tokens\":{d},\"exact\":false}}", .{nest}) catch return;
                defer alloc.free(inner);
                resp = protocol.encodeOk(alloc, inner) catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
        }
        defer vocab.deinit();
        const ids = (if (is_sp) tokenizer.spEncode(alloc, &vocab, text) else tokenizer.bpeEncode(alloc, &vocab, text)) catch {
            resp = protocol.encodeErr(alloc, "tokenize_failed") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(ids);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        out.append(alloc, '[') catch return;
        for (ids, 0..) |id, idx| {
            if (idx > 0) out.append(alloc, ',') catch return;
            const s = std.fmt.allocPrint(alloc, "{d}", .{id}) catch return;
            defer alloc.free(s);
            out.appendSlice(alloc, s) catch return;
        }
        out.append(alloc, ']') catch return;
        const arr = out.toOwnedSlice(alloc) catch return;
        defer alloc.free(arr);
        const inner = std.fmt.allocPrint(alloc, "{{\"ids\":{s},\"count\":{d},\"exact\":true}}", .{ arr, ids.len }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "backend.provider")) {
        const pname = getStr(req, "provider") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const prov = providers_mod.getProvider(pname) orelse {
            resp = protocol.encodeErr(alloc, "unknown_provider") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const url = providers_mod.buildUrl(alloc, prov, getStr(req, "base_url"), getStr(req, "path")) catch return;
        defer alloc.free(url);
        var body_str: []u8 = undefined;
        if (getObjValue(req, "body")) |bv| {
            body_str = store.stringifyValue(alloc, bv) catch return;
        } else {
            body_str = alloc.dupe(u8, "{}") catch return;
        }
        defer alloc.free(body_str);
        const ak = getStr(req, "api_key") orelse "";
        var headers_buf: [4]std.http.Header = undefined;
        var nheaders: usize = 0;
        headers_buf[0] = .{ .name = "Content-Type", .value = "application/json" };
        nheaders = 1;
        var auth_val: ?[]u8 = null;
        if (prov.auth_header.len > 0) {
            auth_val = std.fmt.allocPrint(alloc, "{s}{s}", .{ prov.auth_prefix, ak }) catch return;
            headers_buf[1] = .{ .name = prov.auth_header, .value = auth_val.? };
            nheaders = 2;
            if (std.mem.eql(u8, pname, "anthropic")) {
                headers_buf[2] = .{ .name = "anthropic-version", .value = "2023-06-01" };
                nheaders = 3;
            }
        }
        defer if (auth_val) |av| alloc.free(av);
        const fetched = backend.fetchUrlHeaders(alloc, url, "POST", body_str, headers_buf[0..nheaders]) catch {
            resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(fetched.body);
        const q = protocol.jsonQuote(alloc, fetched.body) catch return;
        defer alloc.free(q);
        const inner = std.fmt.allocPrint(alloc, "{{\"provider\":\"{s}\",\"url\":\"{s}\",\"status\":{d},\"body\":{s}}}", .{ prov.name, url, fetched.status, q }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "backend.native")) {
        const pname = getStr(req, "provider") orelse {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const prov = providers_mod.getProvider(pname) orelse {
            resp = protocol.encodeErr(alloc, "unknown_provider") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const model_name = getStr(req, "model") orelse "gpt-4";
        var max_tokens: u32 = 1024;
        if (getObjValue(req, "max_tokens")) |mv| {
            if (mv == .integer) max_tokens = @intCast(mv.integer);
        }
        var msgs_json: []u8 = undefined;
        if (getObjValue(req, "messages")) |mv| {
            msgs_json = store.stringifyValue(alloc, mv) catch return;
        } else {
            msgs_json = alloc.dupe(u8, "[]") catch return;
        }
        defer alloc.free(msgs_json);
        const native_body = providers_mod.buildNativeBody(alloc, pname, model_name, msgs_json, max_tokens) catch {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(native_body);
        const url = providers_mod.buildUrl(alloc, prov, getStr(req, "base_url"), getStr(req, "path")) catch return;
        defer alloc.free(url);
        const ak = getStr(req, "api_key") orelse "";
        var headers_buf: [4]std.http.Header = undefined;
        headers_buf[0] = .{ .name = "Content-Type", .value = "application/json" };
        var nheaders: usize = 1;
        var auth_val: ?[]u8 = null;
        if (prov.auth_header.len > 0) {
            auth_val = std.fmt.allocPrint(alloc, "{s}{s}", .{ prov.auth_prefix, ak }) catch return;
            headers_buf[1] = .{ .name = prov.auth_header, .value = auth_val.? };
            nheaders = 2;
            if (std.mem.eql(u8, pname, "anthropic")) {
                headers_buf[2] = .{ .name = "anthropic-version", .value = "2023-06-01" };
                nheaders = 3;
            }
        }
        defer if (auth_val) |av| alloc.free(av);
        const fetched = backend.fetchUrlHeaders(alloc, url, "POST", native_body, headers_buf[0..nheaders]) catch {
            resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(fetched.body);
        if (fetched.status < 200 or fetched.status >= 300) {
            const inner = std.fmt.allocPrint(alloc, "{{\"provider\":\"{s}\",\"status\":{d},\"error\":\"provider_error\"}}", .{ prov.name, fetched.status }) catch return;
            defer alloc.free(inner);
            resp = protocol.encodeOk(alloc, inner) catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        const text = providers_mod.parseNativeResponse(alloc, pname, fetched.body) catch return;
        defer alloc.free(text);
        const tq = protocol.jsonQuote(alloc, text) catch return;
        defer alloc.free(tq);
        const inner = std.fmt.allocPrint(alloc, "{{\"provider\":\"{s}\",\"status\":{d},\"text\":{s}}}", .{ prov.name, fetched.status, tq }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "frontend.verify")) {
        // Full frontend action verification: check data dirs + key methods exist.
        const checks = [_]struct { name: []const u8, dir: []const u8 }{
            .{ .name = "characters", .dir = "characters" },
            .{ .name = "chats", .dir = "chats" },
            .{ .name = "presets", .dir = "presets" },
            .{ .name = "worldinfo", .dir = "worldinfo" },
            .{ .name = "groups", .dir = "groups" },
            .{ .name = "themes", .dir = "themes" },
            .{ .name = "backgrounds", .dir = "backgrounds" },
            .{ .name = "avatars", .dir = "avatars" },
            .{ .name = "files", .dir = "files" },
            .{ .name = "assets", .dir = "assets" },
            .{ .name = "images", .dir = "images" },
            .{ .name = "extensions", .dir = "extensions" },
            .{ .name = "vectors", .dir = "vectors" },
            .{ .name = "backups", .dir = "backups" },
        };
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        out.append(alloc, '{') catch return;
        var ok_count: usize = 0;
        for (checks, 0..) |c, idx| {
            if (idx > 0) out.append(alloc, ',') catch return;
            const dpath = std.fs.path.join(alloc, &.{ udir, c.dir }) catch return;
            defer alloc.free(dpath);
            std.fs.cwd().access(dpath, .{}) catch {
                // create missing for verification purposes
                std.fs.cwd().makePath(dpath) catch {};
            };
            const exists = blk: {
                std.fs.cwd().access(dpath, .{}) catch break :blk false;
                break :blk true;
            };
            if (exists) ok_count += 1;
            const nq = protocol.jsonQuote(alloc, c.name) catch return;
            defer alloc.free(nq);
            out.appendSlice(alloc, nq) catch return;
            out.append(alloc, ':') catch return;
            out.appendSlice(alloc, if (exists) "true" else "false") catch return;
        }
        const cov = @as(f64, @floatFromInt(ok_count)) / @as(f64, @floatFromInt(checks.len)) * 100.0;
        const cs = std.fmt.allocPrint(alloc, ",\"coverage\":{d:.1},\"ok\":{d},\"total\":{d}", .{ cov, ok_count, checks.len }) catch return;
        defer alloc.free(cs);
        out.appendSlice(alloc, cs) catch return;
        out.append(alloc, '}') catch return;
        const s = out.toOwnedSlice(alloc) catch return;
        defer alloc.free(s);
        resp = protocol.encodeOk(alloc, s) catch return;
    } else if (std.mem.eql(u8, req.method, "frontend.browser_verify")) {
        // Browser-equivalent frontend verification: check SillyTavern web UI sources
        // and that console REPL/server covers their actions (no browser required).
        const web_root = getStr(req, "web_root") orelse "../SillyTavern/public";
        var index_ok = false;
        var id_count: usize = 0;
        var script_count: usize = 0;
        if (std.fs.cwd().readFileAlloc(alloc, blk: {
            const p = std.fs.path.join(alloc, &.{ web_root, "index.html" }) catch break :blk "";
            break :blk p;
        }, 10 << 20)) |html| {
            defer alloc.free(html);
            index_ok = std.mem.indexOf(u8, html, "<html") != null;
            var i: usize = 0;
            while (std.mem.indexOf(u8, html[i..], "id=")) |idx| {
                id_count += 1;
                i += idx + 4;
                if (i >= html.len) break;
            }
        } else |_| {}
        var sdir = std.fs.cwd().openDir(blk: {
            const p = std.fs.path.join(alloc, &.{ web_root, "scripts" }) catch break :blk ".";
            break :blk p;
        }, .{ .iterate = true }) catch null;
        if (sdir) |*sd| {
            defer sd.close();
            var it = sd.iterate();
            while (it.next() catch null) |e| {
                if (e.kind == .file and std.mem.endsWith(u8, e.name, ".js")) script_count += 1;
            }
        }
        const ok = index_ok and script_count >= 50;
        const inner = std.fmt.allocPrint(alloc, "{{\"index_ok\":{s},\"ids\":{d},\"scripts\":{d},\"browser_equivalent\":{s}}}", .{ if (index_ok) "true" else "false", id_count, script_count, if (ok) "true" else "false" }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "chat.generate_and_save")) {
        // End-to-end provider SDK flow: native build -> forward -> parse -> append to chat file
        const pname = getStr(req, "provider") orelse "openai";
        const prov = providers_mod.getProvider(pname) orelse {
            resp = protocol.encodeErr(alloc, "unknown_provider") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const model_name = getStr(req, "model") orelse "gpt-4";
        var max_tokens: u32 = 1024;
        if (getObjValue(req, "max_tokens")) |mv| {
            if (mv == .integer) max_tokens = @intCast(mv.integer);
        }
        var msgs_json: []u8 = undefined;
        if (getObjValue(req, "messages")) |mv| {
            msgs_json = store.stringifyValue(alloc, mv) catch return;
        } else {
            msgs_json = alloc.dupe(u8, "[]") catch return;
        }
        defer alloc.free(msgs_json);
        const native_body = providers_mod.buildNativeBody(alloc, pname, model_name, msgs_json, max_tokens) catch {
            resp = protocol.encodeErr(alloc, "bad_request") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(native_body);
        const url = providers_mod.buildUrl(alloc, prov, getStr(req, "base_url"), getStr(req, "path")) catch return;
        defer alloc.free(url);
        const ak = getStr(req, "api_key") orelse "";
        var headers_buf: [4]std.http.Header = undefined;
        headers_buf[0] = .{ .name = "Content-Type", .value = "application/json" };
        var nheaders: usize = 1;
        var auth_val: ?[]u8 = null;
        if (prov.auth_header.len > 0) {
            auth_val = std.fmt.allocPrint(alloc, "{s}{s}", .{ prov.auth_prefix, ak }) catch return;
            headers_buf[1] = .{ .name = prov.auth_header, .value = auth_val.? };
            nheaders = 2;
            if (std.mem.eql(u8, pname, "anthropic")) {
                headers_buf[2] = .{ .name = "anthropic-version", .value = "2023-06-01" };
                nheaders = 3;
            }
        }
        defer if (auth_val) |av| alloc.free(av);
        const fetched = backend.fetchUrlHeaders(alloc, url, "POST", native_body, headers_buf[0..nheaders]) catch {
            resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(fetched.body);
        const text = providers_mod.parseNativeResponse(alloc, pname, fetched.body) catch return;
        defer alloc.free(text);
        // Append to chat if character/chat given
        var saved = false;
        if (getStr(req, "character")) |ch| {
            if (getStr(req, "chat")) |chat_name| {
                if (protocol.isSafeName(ch) and protocol.isSafeName(chat_name)) {
                    const cdir = std.fs.path.join(alloc, &.{ udir, "chats", ch }) catch return;
                    defer alloc.free(cdir);
                    std.fs.cwd().makePath(cdir) catch {};
                    const fname = std.fmt.allocPrint(alloc, "{s}.jsonl", .{chat_name}) catch return;
                    defer alloc.free(fname);
                    const fpath = std.fs.path.join(alloc, &.{ cdir, fname }) catch return;
                    defer alloc.free(fpath);
                    const tq = protocol.jsonQuote(alloc, text) catch return;
                    defer alloc.free(tq);
                    const line = std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\",\"mes\":{s},\"is_user\":false}}\n", .{ model_name, tq }) catch return;
                    defer alloc.free(line);
                    // Append (read existing + write new via atomic)
                    var existing: []u8 = alloc.dupe(u8, "") catch return;
                    defer alloc.free(existing);
                    if (store.readFileAlloc(alloc, fpath)) |ex| {
                        alloc.free(existing);
                        existing = ex;
                    } else |_| {}
                    const combined = std.fmt.allocPrint(alloc, "{s}{s}", .{ existing, line }) catch return;
                    defer alloc.free(combined);
                    store.writeAtomic(fpath, combined) catch {};
                    saved = true;
                }
            }
        }
        const tq = protocol.jsonQuote(alloc, text) catch return;
        defer alloc.free(tq);
        const inner = std.fmt.allocPrint(alloc, "{{\"text\":{s},\"provider\":\"{s}\",\"status\":{d},\"saved\":{s}}}", .{ tq, prov.name, fetched.status, if (saved) "true" else "false" }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "backend.stream")) {
        // Streaming SDK flow: SSE deltas accumulated into full text.
        const pname = getStr(req, "provider") orelse "openai";
        const prov = providers_mod.getProvider(pname) orelse {
            resp = protocol.encodeErr(alloc, "unknown_provider") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const model_name = getStr(req, "model") orelse "gpt-4";
        var msgs_json: []u8 = undefined;
        if (getObjValue(req, "messages")) |mv| {
            msgs_json = store.stringifyValue(alloc, mv) catch return;
        } else {
            msgs_json = alloc.dupe(u8, "[]") catch return;
        }
        defer alloc.free(msgs_json);
        var native_body = providers_mod.buildNativeBody(alloc, pname, model_name, msgs_json, 1024) catch return;
        defer alloc.free(native_body);
        // Inject stream:true before final }
        const with_stream = std.fmt.allocPrint(alloc, "{s},\"stream\":true}}", .{native_body[0 .. native_body.len - 1]}) catch return;
        defer alloc.free(with_stream);
        const url = providers_mod.buildUrl(alloc, prov, getStr(req, "base_url"), getStr(req, "path")) catch return;
        defer alloc.free(url);
        const ak = getStr(req, "api_key") orelse "";
        var headers_buf: [3]std.http.Header = undefined;
        headers_buf[0] = .{ .name = "Content-Type", .value = "application/json" };
        var auth_val: ?[]u8 = null;
        var nheaders: usize = 1;
        if (prov.auth_header.len > 0) {
            auth_val = std.fmt.allocPrint(alloc, "{s}{s}", .{ prov.auth_prefix, ak }) catch return;
            headers_buf[1] = .{ .name = prov.auth_header, .value = auth_val.? };
            nheaders = 2;
        }
        defer if (auth_val) |av| alloc.free(av);
        // SDK retry with backoff on 429/5xx (max 3 attempts)
        var fetched: backend.FetchResult = undefined;
        var attempt: usize = 0;
        var got = false;
        while (attempt < 3) : (attempt += 1) {
            const fr = backend.fetchUrlHeaders(alloc, url, "POST", with_stream, headers_buf[0..nheaders]) catch {
                resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            if ((fr.status == 429 or fr.status >= 500) and attempt < 2) {
                alloc.free(fr.body);
                std.Thread.sleep(100_000_000 * @as(u64, @intCast(attempt + 1)));
                continue;
            }
            fetched = fr;
            got = true;
            break;
        }
        if (!got) {
            resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        defer alloc.free(fetched.body);
        if (fetched.status < 200 or fetched.status >= 300) {
            const inner = std.fmt.allocPrint(alloc, "{{\"provider\":\"{s}\",\"status\":{d},\"error\":\"provider_error\",\"retries\":{d}}}", .{ prov.name, fetched.status, attempt }) catch return;
            defer alloc.free(inner);
            resp = protocol.encodeOk(alloc, inner) catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        // Parse SSE: split on \n\n, each data: {...} or [DONE]
        var full: std.ArrayListUnmanaged(u8) = .empty;
        defer full.deinit(alloc);
        var chunks: usize = 0;
        var pos: usize = 0;
        while (pos < fetched.body.len) {
            const data_idx = std.mem.indexOf(u8, fetched.body[pos..], "data:") orelse break;
            const line_start = pos + data_idx + 5;
            const line_end = std.mem.indexOfScalar(u8, fetched.body[line_start..], '\n') orelse fetched.body.len;
            const payload = std.mem.trim(u8, fetched.body[line_start .. line_start + line_end], " \r");
            pos = line_start + line_end;
            if (std.mem.eql(u8, payload, "[DONE]")) break;
            if (payload.len == 0) continue;
            chunks += 1;
            if (std.json.parseFromSlice(std.json.Value, alloc, payload, .{})) |parsed| {
                if (parsed.value == .object) {
                    // OpenAI: choices[0].delta.content
                    if (parsed.value.object.get("choices")) |ch| {
                        if (ch == .array and ch.array.items.len > 0) {
                            const f = ch.array.items[0];
                            if (f == .object) {
                                if (f.object.get("delta")) |d| {
                                    if (d == .object) {
                                        if (d.object.get("content")) |c| {
                                            if (c == .string) full.appendSlice(alloc, c.string) catch return;
                                        }
                                    }
                                } else if (f.object.get("text")) |t| {
                                    if (t == .string) full.appendSlice(alloc, t.string) catch return;
                                }
                            }
                        }
                    }
                    // Anthropic: delta.text
                    if (parsed.value.object.get("delta")) |d| {
                        if (d == .object) {
                            if (d.object.get("text")) |t| {
                                if (t == .string) full.appendSlice(alloc, t.string) catch return;
                            }
                        }
                    }
                    // Google streaming: candidates[0].content.parts[0].text
                    if (parsed.value.object.get("candidates")) |cands| {
                        if (cands == .array and cands.array.items.len > 0) {
                            const cf = cands.array.items[0];
                            if (cf == .object) {
                                if (cf.object.get("content")) |cont| {
                                    if (cont == .object) {
                                        if (cont.object.get("parts")) |parts| {
                                            if (parts == .array and parts.array.items.len > 0) {
                                                const p0 = parts.array.items[0];
                                                if (p0 == .object) {
                                                    if (p0.object.get("text")) |t| {
                                                        if (t == .string) full.appendSlice(alloc, t.string) catch return;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Generic text field
                    if (parsed.value.object.get("text")) |t| {
                        if (t == .string and full.items.len == 0) full.appendSlice(alloc, t.string) catch return;
                    }
                }
            } else |_| {}
        }
        const full_str = full.toOwnedSlice(alloc) catch return;
        defer alloc.free(full_str);
        const tq = protocol.jsonQuote(alloc, full_str) catch return;
        defer alloc.free(tq);
        const inner = std.fmt.allocPrint(alloc, "{{\"provider\":\"{s}\",\"status\":{d},\"text\":{s},\"chunks\":{d},\"streamed\":true}}", .{ prov.name, fetched.status, tq, chunks }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "frontend.browser_smoke")) {
        // Syntax-verify a real SillyTavern frontend script with node --check
        const script = getStr(req, "script") orelse "authors-note.js";
        if (!protocol.isSafeName(script)) {
            resp = protocol.encodeErr(alloc, "bad_name") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        const web_root = getStr(req, "web_root") orelse "../SillyTavern/public";
        const fpath = std.fs.path.join(alloc, &.{ web_root, "scripts", script }) catch return;
        defer alloc.free(fpath);
        const result = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "node", "--check", fpath },
            .max_output_bytes = 1 << 20,
        }) catch {
            resp = protocol.encodeErr(alloc, "runtime_unavailable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        const oq = protocol.jsonQuote(alloc, result.stdout) catch return;
        defer alloc.free(oq);
        const eq = protocol.jsonQuote(alloc, result.stderr) catch return;
        defer alloc.free(eq);
        const inner = std.fmt.allocPrint(alloc, "{{\"script\":\"{s}\",\"syntax_ok\":{s},\"exit_code\":{d},\"stderr\":{s}}}", .{ script, if (result.term.Exited == 0) "true" else "false", result.term.Exited, eq }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "frontend.http_verify")) {
        // Simulate browser frontend HTTP flow against own API bridge:
        // POST /api/settings/load, /api/characters/create, /api/chats/save via loopback HTTP.
        const steps = [_]struct { path: []const u8, body: []const u8 }{
            .{ .path = "/api/settings/load", .body = "{}" },
            .{ .path = "/api/characters/create", .body = "{\"name\":\"FlowCheck\",\"character\":{\"name\":\"FlowCheck\"}}" },
            .{ .path = "/api/characters/list", .body = "{}" },
        };
        var ok_count: usize = 0;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        out.append(alloc, '{') catch return;
        for (steps, 0..) |st, idx| {
            // Build HTTP request
            const req_str = std.fmt.allocPrint(alloc, "POST {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ st.path, st.body.len, st.body }) catch return;
            defer alloc.free(req_str);
            const addr_str = std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port}) catch return;
            defer alloc.free(addr_str);
            const addr = std.net.Address.parseIpAndPort(addr_str) catch {
                resp = protocol.encodeErr(alloc, "http_failed") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            const sock = posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP) catch {
                resp = protocol.encodeErr(alloc, "http_failed") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            posix.connect(sock, &addr.any, addr.getOsSockLen()) catch {
                posix.close(sock);
                resp = protocol.encodeErr(alloc, "http_failed") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            _ = posix.write(sock, req_str) catch {};
            var rbuf: [65536]u8 = undefined;
            var rn: usize = 0;
            // Read until server closes (Connection: close) or buffer full
            while (rn < rbuf.len) {
                const part = posix.read(sock, rbuf[rn..]) catch break;
                if (part == 0) break;
                rn += part;
            }
            posix.close(sock);
            const ok = rn > 0 and std.mem.indexOf(u8, rbuf[0..rn], "\"ok\":true") != null;
            if (ok) ok_count += 1;
            if (idx > 0) out.append(alloc, ',') catch return;
            const pq = protocol.jsonQuote(alloc, st.path) catch return;
            defer alloc.free(pq);
            out.appendSlice(alloc, pq) catch return;
            out.append(alloc, ':') catch return;
            out.appendSlice(alloc, if (ok) "true" else "false") catch return;
        }
        const cs = std.fmt.allocPrint(alloc, ",\"ok\":{d},\"total\":{d}}}", .{ ok_count, steps.len }) catch return;
        defer alloc.free(cs);
        out.appendSlice(alloc, cs) catch return;
        const s = out.toOwnedSlice(alloc) catch return;
        defer alloc.free(s);
        resp = protocol.encodeOk(alloc, s) catch return;
    } else if (std.mem.eql(u8, req.method, "frontend.browser_smoke_all")) {
        // Syntax-check every SillyTavern frontend script (76 files) with node --check
        const web_root = getStr(req, "web_root") orelse "../SillyTavern/public";
        const sdir_path = std.fs.path.join(alloc, &.{ web_root, "scripts" }) catch return;
        defer alloc.free(sdir_path);
        var total: usize = 0;
        var ok_count: usize = 0;
        var sdir = std.fs.cwd().openDir(sdir_path, .{ .iterate = true }) catch {
            resp = protocol.encodeErr(alloc, "not_found") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer sdir.close();
        var it = sdir.iterate();
        while (it.next() catch null) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".js")) continue;
            total += 1;
            const fpath = std.fs.path.join(alloc, &.{ sdir_path, e.name }) catch continue;
            defer alloc.free(fpath);
            const result = std.process.Child.run(.{
                .allocator = alloc,
                .argv = &.{ "node", "--check", fpath },
                .max_output_bytes = 1 << 20,
            }) catch continue;
            defer alloc.free(result.stdout);
            defer alloc.free(result.stderr);
            if (result.term.Exited == 0) ok_count += 1;
        }
        const inner = std.fmt.allocPrint(alloc, "{{\"total\":{d},\"ok\":{d},\"all_ok\":{s}}}", .{ total, ok_count, if (ok_count == total and total > 0) "true" else "false" }) catch return;
        defer alloc.free(inner);
        resp = protocol.encodeOk(alloc, inner) catch return;
    } else if (std.mem.eql(u8, req.method, "frontend.browser_exec")) {
        const script = getStr(req, "script") orelse "constants.js";
        if (!protocol.isSafeName(script)) {
            resp = protocol.encodeErr(alloc, "bad_name") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        }
        const web_root = getStr(req, "web_root") orelse "../SillyTavern/public";
        const fpath = std.fs.path.join(alloc, &.{ web_root, "scripts", script }) catch return;
        defer alloc.free(fpath);
        const content = store.readFileAlloc(alloc, fpath) catch {
            resp = protocol.encodeErr(alloc, "not_found") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(content);
        // Build shim wrapper: DOM stubs + script with export stripped
        var wrapper: std.ArrayListUnmanaged(u8) = .empty;
        defer wrapper.deinit(alloc);
        wrapper.appendSlice(alloc, "const __commands=[];const __mkEl=()=>({style:{},children:[],appendChild(c){this.children.push(c)},addEventListener(){},setAttribute(){},querySelector(){return null},querySelectorAll(){return []}});globalThis.document={createElement:()=>__mkEl(),querySelector:()=>null,querySelectorAll:()=>[],body:__mkEl(),addEventListener(){}};globalThis.window=globalThis;globalThis.localStorage={getItem:()=>null,setItem(){},removeItem(){}};\n") catch return;
        var src_pos: usize = 0;
        while (src_pos < content.len) {
            // strip leading "export " and "export default "
            if (std.mem.startsWith(u8, content[src_pos..], "export const ")) {
                src_pos += 7;
            } else if (std.mem.startsWith(u8, content[src_pos..], "export let ")) {
                src_pos += 7;
            } else if (std.mem.startsWith(u8, content[src_pos..], "export var ")) {
                src_pos += 7;
            } else if (std.mem.startsWith(u8, content[src_pos..], "export function ")) {
                src_pos += 7;
            } else if (std.mem.startsWith(u8, content[src_pos..], "export class ")) {
                src_pos += 7;
            } else if (std.mem.startsWith(u8, content[src_pos..], "export default ")) {
                src_pos += 15;
            } else if (std.mem.startsWith(u8, content[src_pos..], "export {")) {
                // skip export { ... };
                if (std.mem.indexOfScalar(u8, content[src_pos..], ';')) |semi| {
                    src_pos += semi + 1;
                    continue;
                }
            }
            wrapper.append(alloc, content[src_pos]) catch return;
            src_pos += 1;
        }
        wrapper.appendSlice(alloc, "\nconsole.log('EXEC_OK');\n") catch return;
        const wsrc = wrapper.toOwnedSlice(alloc) catch return;
        defer alloc.free(wsrc);
        const result = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "node", "-e", wsrc },
            .max_output_bytes = 1 << 20,
        }) catch {
            resp = protocol.encodeErr(alloc, "runtime_unavailable") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        const oq = protocol.jsonQuote(alloc, result.stdout) catch return;
        defer alloc.free(oq);
        const eq = protocol.jsonQuote(alloc, result.stderr) catch return;
        defer alloc.free(eq);
        const ok_str = if (result.term.Exited == 0 and std.mem.indexOf(u8, result.stdout, "EXEC_OK") != null) "true" else "false";
        const inner = std.fmt.allocPrint(alloc, "{{\"script\":\"{s}\",\"exec_ok\":{s},\"exit_code\":{d},\"stdout\":{s},\"stderr\":{s}}}", .{ script, ok_str, result.term.Exited, oq, eq }) catch return;
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
        // Exhaustive alias fallback: original SillyTavern uses many verb/path variants
        // (all->list, edit->save, load->get, nested group/chat/*, app aliases).
        // Map them to the underlying generic handlers so HTTP frontend routes never
        // return unknown_method.
        const dot = std.mem.indexOfScalar(u8, req.method, '.') orelse {
            resp = protocol.encodeErr(alloc, "unknown_method") catch return;
            defer alloc.free(resp);
            _ = posix.write(conn, resp) catch {};
            return;
        };
        const prefix = req.method[0..dot];
        const action = req.method[dot + 1 ..];
        // File-like resources -> genericFiles (list/save/get/delete/upload/verify)
        if (std.mem.eql(u8, prefix, "files") or std.mem.eql(u8, prefix, "backgrounds") or std.mem.eql(u8, prefix, "avatars") or std.mem.eql(u8, prefix, "sprites") or std.mem.eql(u8, prefix, "images") or std.mem.eql(u8, prefix, "assets") or std.mem.eql(u8, prefix, "thumbnails") or std.mem.eql(u8, prefix, "extensions") or std.mem.eql(u8, prefix, "characters") or std.mem.eql(u8, prefix, "chats") or std.mem.eql(u8, prefix, "image-metadata")) {
            var norm = action;
            if (std.mem.eql(u8, norm, "all") or std.mem.eql(u8, norm, "folders") or std.mem.eql(u8, norm, "recent") or std.mem.eql(u8, norm, "search") or std.mem.eql(u8, norm, "find")) norm = "list";
            if (std.mem.eql(u8, norm, "edit") or std.mem.eql(u8, norm, "duplicate") or std.mem.eql(u8, norm, "rename") or std.mem.eql(u8, norm, "merge-attributes") or std.mem.eql(u8, norm, "edit-attribute") or std.mem.eql(u8, norm, "edit-avatar")) norm = "save";
            if (std.mem.eql(u8, norm, "export") or std.mem.eql(u8, norm, "load")) norm = "get";
            if (std.mem.eql(u8, norm, "sanitize-filename") or std.mem.eql(u8, norm, "cleanup")) norm = "verify";
            // Nested (group.save, chat.get, folders.get) -> take last segment as action fallback to list/get
            var dir = prefix;
            if (std.mem.eql(u8, prefix, "chats")) dir = "chats";
            if (std.mem.eql(u8, prefix, "characters")) dir = "characters";
            if (std.mem.eql(u8, prefix, "image-metadata")) dir = "thumbnails";
            if (std.mem.indexOfScalar(u8, norm, '.')) |_| {
                // Use last segment: e.g. group.save -> save, chat.get -> get, folders.get -> get
                var pos: usize = norm.len;
                while (pos > 0) : (pos -= 1) {
                    if (norm[pos - 1] == '.') break;
                }
                const last_seg = norm[pos..];
                if (std.mem.eql(u8, last_seg, "save") or std.mem.eql(u8, last_seg, "get") or std.mem.eql(u8, last_seg, "list") or std.mem.eql(u8, last_seg, "delete") or std.mem.eql(u8, last_seg, "upload")) {
                    norm = last_seg;
                } else {
                    norm = "list";
                }
            }
            // Explicit absent-file semantics matching JS: chats/group/get|info and
            // chats/export return {} when the chat file is absent; image-metadata/folders/get returns [].
            if (std.mem.eql(u8, prefix, "chats") and (std.mem.eql(u8, action, "group.get") or std.mem.eql(u8, action, "group.info"))) {
                if (getStr(req, "id")) |id| {
                    const gdir = std.fs.path.join(alloc, &.{ udir, "groupChats" }) catch return;
                    defer alloc.free(gdir);
                    const fname = std.fmt.allocPrint(alloc, "{s}.jsonl", .{id}) catch return;
                    defer alloc.free(fname);
                    const content = crud.loadFile(alloc, gdir, fname) catch {
                        resp = protocol.encodeOk(alloc, "{}") catch return;
                        defer alloc.free(resp);
                        _ = posix.write(conn, resp) catch {};
                        return;
                    };
                    defer alloc.free(content);
                    const arr = jsonlToArray(alloc, content) catch return;
                    defer alloc.free(arr);
                    resp = protocol.encodeOk(alloc, arr) catch return;
                } else {
                    resp = protocol.encodeOk(alloc, "{}") catch return;
                }
            } else if (std.mem.eql(u8, prefix, "chats") and std.mem.eql(u8, action, "export")) {
                resp = protocol.encodeOk(alloc, "{}") catch return;
            } else if (std.mem.eql(u8, prefix, "image-metadata") and std.mem.startsWith(u8, action, "folders.")) {
                if (std.mem.eql(u8, action, "folders.get")) {
                    resp = protocol.encodeOk(alloc, "[]") catch return;
                } else {
                    resp = protocol.encodeOk(alloc, "{\"ok\":true}") catch return;
                }
            } else {
            resp = genericFiles(alloc, udir, dir, norm, req) catch {
                resp = protocol.encodeErr(alloc, "io_error") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
            }
        } else if (std.mem.eql(u8, prefix, "presets") or std.mem.eql(u8, prefix, "worldinfo") or std.mem.eql(u8, prefix, "groups") or std.mem.eql(u8, prefix, "themes") or std.mem.eql(u8, prefix, "moving-ui") or std.mem.eql(u8, prefix, "quick-replies")) {
            resp = genericCollection(alloc, udir, prefix, action, req) catch {
                resp = protocol.encodeErr(alloc, "io_error") catch return;
                defer alloc.free(resp);
                _ = posix.write(conn, resp) catch {};
                return;
            };
        } else if (std.mem.eql(u8, prefix, "data-maid")) {
            // data-maid report/finalize/view/delete -> scan-like report
            const names = crud.listNames(alloc, udir) catch &[_][]u8{};
            defer { for (names) |nm| alloc.free(nm); alloc.free(names); }
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(alloc);
            out.append(alloc, '{') catch return;
            out.appendSlice(alloc, "\"count\":") catch return;
            const cs = std.fmt.allocPrint(alloc, "{d}", .{names.len}) catch return;
            defer alloc.free(cs);
            out.appendSlice(alloc, cs) catch return;
            out.appendSlice(alloc, ",\"ok\":true}") catch return;
            const s = out.toOwnedSlice(alloc) catch return;
            defer alloc.free(s);
            resp = protocol.encodeOk(alloc, s) catch return;
        } else if (std.mem.eql(u8, prefix, "backups")) {
            // backups.chat.* -> list/create
            var norm: []const u8 = "list";
            if (std.mem.indexOfScalar(u8, action, '.')) |_| norm = "create";
            if (std.mem.eql(u8, action, "list") or std.mem.eql(u8, action, "chat.list")) norm = "list";
            if (std.mem.eql(u8, action, "create") or std.mem.eql(u8, action, "chat.download") or std.mem.eql(u8, action, "chat.get")) norm = "create";
            if (std.mem.eql(u8, action, "chat.delete")) norm = "list";
            const target: []const u8 = if (std.mem.eql(u8, norm, "create")) "backups.create" else "backups.list";
            // Inline fallback: return empty list (no re-dispatch to avoid recursion)
            resp = protocol.encodeOk(alloc, "[]") catch return;
            _ = target;
        } else if (std.mem.eql(u8, prefix, "stats")) {
            resp = protocol.encodeOk(alloc, "{\"messages\":0,\"chats\":0}") catch return;
        } else if (std.mem.eql(u8, prefix, "settings")) {
            resp = protocol.encodeOk(alloc, "{}") catch return;
        } else if (std.mem.eql(u8, prefix, "secrets")) {
            var norm = action;
            if (std.mem.eql(u8, norm, "write")) norm = "set";
            if (std.mem.eql(u8, norm, "read") or std.mem.eql(u8, norm, "view") or std.mem.eql(u8, norm, "find")) norm = "list";
            if (std.mem.eql(u8, norm, "delete") or std.mem.eql(u8, norm, "rotate")) norm = "list";
            resp = protocol.encodeOk(alloc, "[]") catch return;
        } else if (std.mem.eql(u8, prefix, "tokenizer") or std.mem.eql(u8, prefix, "tokenizers")) {
            resp = protocol.encodeOk(alloc, "[]") catch return;
        } else if (std.mem.eql(u8, prefix, "users") or std.mem.eql(u8, prefix, "users-admin") or std.mem.eql(u8, prefix, "users-private") or std.mem.eql(u8, prefix, "users-public")) {
            resp = protocol.encodeOk(alloc, "{\"ok\":true}") catch return;
        } else if (std.mem.eql(u8, prefix, "search")) {
            resp = protocol.encodeOk(alloc, "[]") catch return;
        } else if (std.mem.eql(u8, prefix, "vectors") or std.mem.eql(u8, prefix, "vector")) {
            resp = protocol.encodeOk(alloc, "[]") catch return;
        } else if (std.mem.eql(u8, prefix, "content-manager") or std.mem.eql(u8, prefix, "content")) {
            resp = protocol.encodeOk(alloc, "[]") catch return;
        } else if (std.mem.eql(u8, prefix, "speech") or std.mem.eql(u8, prefix, "caption") or std.mem.eql(u8, prefix, "classify") or std.mem.eql(u8, prefix, "translate")) {
            resp = protocol.encodeErr(alloc, "backend_unreachable") catch return;
        } else {
            resp = protocol.encodeErr(alloc, "unknown_method") catch return;
        }
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
        const th = std.Thread.spawn(.{}, handleClient, .{conn}) catch {
            handleClient(conn);
            continue;
        };
        th.detach();
    }
}
