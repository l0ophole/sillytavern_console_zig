const std = @import("std");

pub const Provider = struct {
    name: []const u8,
    base_url: []const u8,
    path: []const u8,
    auth_header: []const u8, // empty = no auth
    auth_prefix: []const u8,
};

pub const providers = [_]Provider{
    .{ .name = "openai", .base_url = "https://api.openai.com", .path = "/v1/chat/completions", .auth_header = "Authorization", .auth_prefix = "Bearer " },
    .{ .name = "anthropic", .base_url = "https://api.anthropic.com", .path = "/v1/messages", .auth_header = "x-api-key", .auth_prefix = "" },
    .{ .name = "google", .base_url = "https://generativelanguage.googleapis.com", .path = "/v1beta/models/gemini-pro:generateContent", .auth_header = "x-goog-api-key", .auth_prefix = "" },
    .{ .name = "azure", .base_url = "https://resource.openai.azure.com", .path = "/openai/deployments/gpt-4/chat/completions", .auth_header = "api-key", .auth_prefix = "" },
    .{ .name = "openrouter", .base_url = "https://openrouter.ai/api/v1", .path = "/chat/completions", .auth_header = "Authorization", .auth_prefix = "Bearer " },
    .{ .name = "novelai", .base_url = "https://api.novelai.net", .path = "/ai/generate", .auth_header = "Authorization", .auth_prefix = "Bearer " },
    .{ .name = "horde", .base_url = "https://stablehorde.net", .path = "/api/v2/generate/text", .auth_header = "Apikey", .auth_prefix = "" },
    .{ .name = "kobold", .base_url = "http://localhost:5000", .path = "/api/v1/generate", .auth_header = "", .auth_prefix = "" },
    .{ .name = "minimax", .base_url = "https://api.minimax.io", .path = "/v1/text/chatcompletion_v2", .auth_header = "Authorization", .auth_prefix = "Bearer " },
    .{ .name = "volcengine", .base_url = "https://ark.cn-beijing.volces.com", .path = "/api/v3/chat/completions", .auth_header = "Authorization", .auth_prefix = "Bearer " },
    .{ .name = "nanogpt", .base_url = "https://api.nanogpt.com", .path = "/v1/chat/completions", .auth_header = "Authorization", .auth_prefix = "Bearer " },
};

pub fn getProvider(name: []const u8) ?Provider {
    for (providers) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

pub fn buildUrl(alloc: std.mem.Allocator, provider: Provider, base_override: ?[]const u8, path_override: ?[]const u8) ![]u8 {
    const base = base_override orelse provider.base_url;
    const path = path_override orelse provider.path;
    // Trim trailing slash from base
    var b = base;
    while (b.len > 0 and b[b.len - 1] == '/') b = b[0 .. b.len - 1];
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ b, path });
}

pub fn concatPrompt(alloc: std.mem.Allocator, messages_json: []const u8) ![]u8 {
    const mq = try std.json.parseFromSlice(std.json.Value, alloc, messages_json, .{});
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    if (mq.value == .array) {
        for (mq.value.array.items) |m| {
            if (m == .object) {
                if (m.object.get("content")) |c| {
                    if (c == .string) try out.appendSlice(alloc, c.string);
                }
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

fn jsonEscaped(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var esc: std.ArrayListUnmanaged(u8) = .empty;
    defer esc.deinit(alloc);
    for (s) |ch| {
        if (ch == '"' or ch == '\\') try esc.append(alloc, '\\');
        if (ch == '\n') {
            try esc.appendSlice(alloc, "\\n");
        } else {
            try esc.append(alloc, ch);
        }
    }
    return esc.toOwnedSlice(alloc);
}

/// Normalize provider-specific chat request body.
pub fn buildNativeBody(alloc: std.mem.Allocator, provider_name: []const u8, model: []const u8, messages_json: []const u8, max_tokens: u32) ![]u8 {
    if (std.mem.eql(u8, provider_name, "novelai") or std.mem.eql(u8, provider_name, "horde") or std.mem.eql(u8, provider_name, "kobold")) {
        const prompt = try concatPrompt(alloc, messages_json);
        defer alloc.free(prompt);
        const eq = try jsonEscaped(alloc, prompt);
        defer alloc.free(eq);
        const mt = try std.fmt.allocPrint(alloc, "{d}", .{max_tokens});
        defer alloc.free(mt);
        if (std.mem.eql(u8, provider_name, "novelai")) {
            return std.fmt.allocPrint(alloc, "{{\"input\":\"{s}\",\"model\":\"{s}\",\"parameters\":{{\"max_length\":{s}}}}}", .{ eq, model, mt });
        } else if (std.mem.eql(u8, provider_name, "horde")) {
            return std.fmt.allocPrint(alloc, "{{\"prompt\":\"{s}\",\"params\":{{\"model\":\"{s}\",\"max_length\":{s}}}}}", .{ eq, model, mt });
        }
        return std.fmt.allocPrint(alloc, "{{\"prompt\":\"{s}\",\"max_length\":{s}}}", .{ eq, mt });
    }
    if (std.mem.eql(u8, provider_name, "anthropic")) {
        // Anthropic per upstream convertClaudeMessages (prompt-converters.js):
        // leading system -> system:[{type:text,text}]; rest system->user;
        // string content -> [{type:text,text}] with name prefix.
        const mq = try std.json.parseFromSlice(std.json.Value, alloc, messages_json, .{});
        const msgs = if (mq.value == .array) mq.value.array.items else &[_]std.json.Value{};
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        try out.appendSlice(alloc, "{\"model\":");
        const model_q = try std.fmt.allocPrint(alloc, "\"{s}\"", .{model});
        defer alloc.free(model_q);
        try out.appendSlice(alloc, model_q);
        try out.appendSlice(alloc, ",\"max_tokens\":");
        const mt = try std.fmt.allocPrint(alloc, "{d}", .{max_tokens});
        defer alloc.free(mt);
        try out.appendSlice(alloc, mt);
        // Collect leading system texts (string content only).
        var sys_end: usize = 0;
        while (sys_end < msgs.len) {
            const m = msgs[sys_end];
            var is_sys = false;
            var content: []const u8 = "";
            if (m == .object) {
                if (m.object.get("role")) |r| {
                    if (r == .string and std.mem.eql(u8, r.string, "system")) is_sys = true;
                }
                if (m.object.get("content")) |c| {
                    if (c == .string) content = c.string;
                }
            }
            if (!is_sys) break;
            sys_end += 1;
        }
        if (sys_end > 0) {
            try out.appendSlice(alloc, ",\"system\":[");
            for (msgs[0..sys_end], 0..) |m, idx| {
                if (idx > 0) try out.append(alloc, ',');
                var content: []const u8 = "";
                if (m == .object) {
                    if (m.object.get("content")) |c| {
                        if (c == .string) content = c.string;
                    }
                }
                const eq = try jsonEscaped(alloc, content);
                defer alloc.free(eq);
                const one = try std.fmt.allocPrint(alloc, "{{\"type\":\"text\",\"text\":\"{s}\"}}", .{eq});
                defer alloc.free(one);
                try out.appendSlice(alloc, one);
            }
            try out.appendSlice(alloc, "]");
        }
        try out.appendSlice(alloc, ",\"messages\":[");
        var first = true;
        for (msgs[sys_end..]) |m| {
            var role: []const u8 = "user";
            var content: []const u8 = "";
            var name: []const u8 = "";
            if (m == .object) {
                if (m.object.get("role")) |r| {
                    if (r == .string) role = r.string;
                }
                if (m.object.get("content")) |c| {
                    if (c == .string) content = c.string;
                }
                if (m.object.get("name")) |n| {
                    if (n == .string) name = n.string;
                }
            }
            const crole = if (std.mem.eql(u8, role, "system")) "user" else role;
            var text = content;
            var prefixed: ?[]u8 = null;
            defer if (prefixed) |p| alloc.free(p);
            if (name.len > 0 and !std.mem.startsWith(u8, content, name)) {
                prefixed = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ name, content });
                text = prefixed.?;
            }
            const eq = try jsonEscaped(alloc, text);
            defer alloc.free(eq);
            if (!first) try out.append(alloc, ',');
            first = false;
            const one = try std.fmt.allocPrint(alloc, "{{\"role\":\"{s}\",\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}", .{ crole, eq });
            defer alloc.free(one);
            try out.appendSlice(alloc, one);
        }
        try out.appendSlice(alloc, "]}");
        return out.toOwnedSlice(alloc);
    } else if (std.mem.eql(u8, provider_name, "google")) {
        // Google per upstream convertGooglePrompt (prompt-converters.js):
        // leading system (while len>1) -> systemInstruction:{parts:[{text}]};
        // remaining system/tool->user, assistant->model.
        const mq = try std.json.parseFromSlice(std.json.Value, alloc, messages_json, .{});
        const msgs = if (mq.value == .array) mq.value.array.items else &[_]std.json.Value{};
        var sys_end: usize = 0;
        while (sys_end + 1 < msgs.len) {
            const m = msgs[sys_end];
            var is_sys = false;
            if (m == .object) {
                if (m.object.get("role")) |r| {
                    if (r == .string and std.mem.eql(u8, r.string, "system")) is_sys = true;
                }
            }
            if (!is_sys) break;
            sys_end += 1;
        }
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        if (sys_end > 0) {
            try out.appendSlice(alloc, "{\"systemInstruction\":{\"parts\":[");
            for (msgs[0..sys_end], 0..) |m, idx| {
                if (idx > 0) try out.append(alloc, ',');
                var content: []const u8 = "";
                if (m == .object) {
                    if (m.object.get("content")) |c| {
                        if (c == .string) content = c.string;
                    }
                }
                const eq = try jsonEscaped(alloc, content);
                defer alloc.free(eq);
                const one = try std.fmt.allocPrint(alloc, "{{\"text\":\"{s}\"}}", .{eq});
                defer alloc.free(one);
                try out.appendSlice(alloc, one);
            }
            try out.appendSlice(alloc, "]},\"contents\":[");
        } else {
            try out.appendSlice(alloc, "{\"contents\":[");
        }
        var first = true;
        for (msgs[sys_end..]) |m| {
            var role: []const u8 = "user";
            var content: []const u8 = "";
            var name: []const u8 = "";
            if (m == .object) {
                if (m.object.get("role")) |r| {
                    if (r == .string) role = r.string;
                }
                if (m.object.get("content")) |c| {
                    if (c == .string) content = c.string;
                }
                if (m.object.get("name")) |n| {
                    if (n == .string) name = n.string;
                }
            }
            const crole: []const u8 = if (std.mem.eql(u8, role, "assistant")) "model" else "user";
            var text = content;
            var prefixed: ?[]u8 = null;
            defer if (prefixed) |p| alloc.free(p);
            if (name.len > 0 and !std.mem.startsWith(u8, content, name)) {
                prefixed = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ name, content });
                text = prefixed.?;
            }
            const eq = try jsonEscaped(alloc, text);
            defer alloc.free(eq);
            if (!first) try out.append(alloc, ',');
            first = false;
            const part = try std.fmt.allocPrint(alloc, "{{\"role\":\"{s}\",\"parts\":[{{\"text\":\"{s}\"}}]}}", .{ crole, eq });
            defer alloc.free(part);
            try out.appendSlice(alloc, part);
        }
        try out.appendSlice(alloc, "]}");
        return out.toOwnedSlice(alloc);
    }
    // Default OpenAI-compatible
    const mq2 = try std.json.parseFromSlice(std.json.Value, alloc, messages_json, .{});
    var tmp2: std.Io.Writer.Allocating = .init(alloc);
    defer tmp2.deinit();
    var s2: std.json.Stringify = .{ .writer = &tmp2.writer };
    try s2.write(mq2.value);
    const mt2 = try std.fmt.allocPrint(alloc, "{d}", .{max_tokens});
    defer alloc.free(mt2);
    return std.fmt.allocPrint(alloc, "{{\"model\":\"{s}\",\"messages\":{s},\"max_tokens\":{s}}}", .{ model, tmp2.written(), mt2 });
}

/// Extract text from provider-specific response body.
pub fn parseNativeResponse(alloc: std.mem.Allocator, provider_name: []const u8, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    if (parsed.value != .object) return alloc.dupe(u8, "");
    if (std.mem.eql(u8, provider_name, "novelai")) {
        if (parsed.value.object.get("output")) |o| {
            if (o == .string) return alloc.dupe(u8, o.string);
        }
        return alloc.dupe(u8, "");
    } else if (std.mem.eql(u8, provider_name, "horde")) {
        if (parsed.value.object.get("generations")) |g| {
            if (g == .array and g.array.items.len > 0) {
                const f = g.array.items[0];
                if (f == .object) {
                    if (f.object.get("text")) |t| {
                        if (t == .string) return alloc.dupe(u8, t.string);
                    }
                }
            }
        }
        return alloc.dupe(u8, "");
    } else if (std.mem.eql(u8, provider_name, "kobold")) {
        if (parsed.value.object.get("results")) |r| {
            if (r == .array and r.array.items.len > 0) {
                const f = r.array.items[0];
                if (f == .object) {
                    if (f.object.get("text")) |t| {
                        if (t == .string) return alloc.dupe(u8, t.string);
                    }
                }
            }
        }
        return alloc.dupe(u8, "");
    } else if (std.mem.eql(u8, provider_name, "anthropic")) {
        if (parsed.value.object.get("content")) |c| {
            if (c == .array and c.array.items.len > 0) {
                const first = c.array.items[0];
                if (first == .object) {
                    if (first.object.get("text")) |t| {
                        if (t == .string) return alloc.dupe(u8, t.string);
                    }
                }
            }
        }
        return alloc.dupe(u8, "");
    } else if (std.mem.eql(u8, provider_name, "google")) {
        if (parsed.value.object.get("candidates")) |cands| {
            if (cands == .array and cands.array.items.len > 0) {
                const first = cands.array.items[0];
                if (first == .object) {
                    if (first.object.get("content")) |cont| {
                        if (cont == .object) {
                            if (cont.object.get("parts")) |parts| {
                                if (parts == .array and parts.array.items.len > 0) {
                                    const p0 = parts.array.items[0];
                                    if (p0 == .object) {
                                        if (p0.object.get("text")) |t| {
                                            if (t == .string) return alloc.dupe(u8, t.string);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return alloc.dupe(u8, "");
    }
    // OpenAI-compatible
    if (parsed.value.object.get("choices")) |ch| {
        if (ch == .array and ch.array.items.len > 0) {
            const first = ch.array.items[0];
            if (first == .object) {
                if (first.object.get("message")) |msg| {
                    if (msg == .object) {
                        if (msg.object.get("content")) |c| {
                            if (c == .string) return alloc.dupe(u8, c.string);
                        }
                    }
                }
                if (first.object.get("text")) |t| {
                    if (t == .string) return alloc.dupe(u8, t.string);
                }
            }
        }
    }
    return alloc.dupe(u8, "");
}

/// Extract OpenAI-compatible SSE deltas from a complete-lines buffer and
/// append the delta content to `out`. Non-JSON lines, empty lines and
/// `[DONE]` are skipped. Callers buffer incomplete trailing lines.
pub fn appendSseDeltas(alloc: std.mem.Allocator, sse: []const u8, out: *std.ArrayListUnmanaged(u8)) !void {
    var pos: usize = 0;
    while (pos < sse.len) {
        const data_idx = std.mem.indexOf(u8, sse[pos..], "data:") orelse break;
        const line_start = pos + data_idx + 5;
        const line_end = std.mem.indexOfScalar(u8, sse[line_start..], '\n') orelse sse.len;
        const payload = std.mem.trim(u8, sse[line_start .. line_start + line_end], " \r");
        pos = line_start + line_end;
        if (payload.len == 0) continue;
        if (std.mem.eql(u8, payload, "[DONE]")) break;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const ch = parsed.value.object.get("choices") orelse continue;
        if (ch != .array or ch.array.items.len == 0) continue;
        const f = ch.array.items[0];
        if (f != .object) continue;
        const d = f.object.get("delta") orelse continue;
        if (d != .object) continue;
        const c = d.object.get("content") orelse continue;
        if (c != .string) continue;
        try out.appendSlice(alloc, c.string);
    }
}

test "native build/parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const msgs = "[{\"role\":\"user\",\"content\":\"hi\"}]";
    const abody = try buildNativeBody(alloc, "anthropic", "claude-3", msgs, 100);
    defer alloc.free(abody);
    try std.testing.expect(std.mem.indexOf(u8, abody, "\"max_tokens\":100") != null);
    const gbody = try buildNativeBody(alloc, "google", "gemini-pro", msgs, 100);
    defer alloc.free(gbody);
    try std.testing.expect(std.mem.indexOf(u8, gbody, "\"contents\"") != null);
    const obody = try buildNativeBody(alloc, "openai", "gpt-4", msgs, 100);
    defer alloc.free(obody);
    try std.testing.expect(std.mem.indexOf(u8, obody, "\"messages\"") != null);

    const atext = try parseNativeResponse(alloc, "anthropic", "{\"content\":[{\"text\":\"hello\"}]}");
    defer alloc.free(atext);
    try std.testing.expectEqualStrings("hello", atext);
    const gtext = try parseNativeResponse(alloc, "google", "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hi\"}]}}]}");
    defer alloc.free(gtext);
    try std.testing.expectEqualStrings("hi", gtext);
    for ([_][]const u8{ "azure", "openrouter", "minimax", "volcengine", "nanogpt" }) |pn| {
        const b = try buildNativeBody(alloc, pn, "m", msgs, 100);
        defer alloc.free(b);
        try std.testing.expect(std.mem.indexOf(u8, b, "\"messages\"") != null);
        const t = try parseNativeResponse(alloc, pn, "{\"choices\":[{\"message\":{\"content\":\"x\"}}]}");
        defer alloc.free(t);
        try std.testing.expectEqualStrings("x", t);
    }
    const nb = try buildNativeBody(alloc, "novelai", "nai", msgs, 42);
    defer alloc.free(nb);
    try std.testing.expect(std.mem.indexOf(u8, nb, "\"input\":\"hi\"") != null);
    const hb = try buildNativeBody(alloc, "horde", "hm", msgs, 42);
    defer alloc.free(hb);
    const kb = try buildNativeBody(alloc, "kobold", "km", msgs, 42);
    defer alloc.free(kb);
    const ntext = try parseNativeResponse(alloc, "novelai", "{\"output\":\"novel out\"}");
    defer alloc.free(ntext);
    try std.testing.expectEqualStrings("novel out", ntext);
    const htext = try parseNativeResponse(alloc, "horde", "{\"generations\":[{\"text\":\"horde out\"}]}");
    defer alloc.free(htext);
    try std.testing.expectEqualStrings("horde out", htext);
    const ktext = try parseNativeResponse(alloc, "kobold", "{\"results\":[{\"text\":\"kobold out\"}]}");
    defer alloc.free(ktext);
    try std.testing.expectEqualStrings("kobold out", ktext);

    const otext = try parseNativeResponse(alloc, "openai", "{\"choices\":[{\"message\":{\"content\":\"yo\"}}]}");
    defer alloc.free(otext);
    try std.testing.expectEqualStrings("yo", otext);
}

test "provider table" {
    const o = getProvider("openai").?;
    try std.testing.expectEqualStrings("https://api.openai.com", o.base_url);
    try std.testing.expectEqualStrings("Authorization", o.auth_header);
    const a = getProvider("anthropic").?;
    try std.testing.expectEqualStrings("x-api-key", a.auth_header);
    const k = getProvider("kobold").?;
    try std.testing.expectEqualStrings("", k.auth_header);
    try std.testing.expect(getProvider("nonexistent") == null);
}

test "anthropic system extraction" {
    // RED: upstream convertClaudeMessages extracts leading system messages
    // into system:[{type:text,text}] and normalizes string content to blocks.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const msgs = "[{\"role\":\"system\",\"content\":\"Be kind\"},{\"role\":\"user\",\"content\":\"hi\"},{\"role\":\"system\",\"content\":\"mid note\"},{\"role\":\"assistant\",\"content\":\"hello\"}]";
    const body = try buildNativeBody(alloc, "anthropic", "claude-3", msgs, 100);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.get("system") != null);
    const sys = parsed.value.object.get("system").?;
    try std.testing.expect(sys == .array);
    try std.testing.expectEqual(@as(usize, 1), sys.array.items.len);
    try std.testing.expectEqualStrings("Be kind", sys.array.items[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("text", sys.array.items[0].object.get("type").?.string);
    const out_msgs = parsed.value.object.get("messages").?;
    try std.testing.expect(out_msgs == .array);
    // leading system removed; mid system converted to user; string content normalized
    try std.testing.expectEqual(@as(usize, 3), out_msgs.array.items.len);
    try std.testing.expectEqualStrings("user", out_msgs.array.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("user", out_msgs.array.items[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("assistant", out_msgs.array.items[2].object.get("role").?.string);
    const c0 = out_msgs.array.items[0].object.get("content").?;
    try std.testing.expect(c0 == .array);
    try std.testing.expectEqualStrings("hi", c0.array.items[0].object.get("text").?.string);
}

test "google systemInstruction extraction" {
    // RED: upstream convertGooglePrompt extracts leading system into
    // systemInstruction:{parts:[{text}]} and maps roles.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const msgs = "[{\"role\":\"system\",\"content\":\"Be kind\"},{\"role\":\"user\",\"content\":\"hi\"},{\"role\":\"assistant\",\"content\":\"hello\"}]";
    const body = try buildNativeBody(alloc, "google", "gemini-pro", msgs, 100);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.get("systemInstruction") != null);
    const si = parsed.value.object.get("systemInstruction").?;
    try std.testing.expect(si == .object);
    const parts = si.object.get("parts").?;
    try std.testing.expect(parts == .array);
    try std.testing.expectEqual(@as(usize, 1), parts.array.items.len);
    try std.testing.expectEqualStrings("Be kind", parts.array.items[0].object.get("text").?.string);
    const contents = parsed.value.object.get("contents").?;
    try std.testing.expect(contents == .array);
    try std.testing.expectEqual(@as(usize, 2), contents.array.items.len);
    try std.testing.expectEqualStrings("user", contents.array.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("model", contents.array.items[1].object.get("role").?.string);
}

test "buildUrl" {
    const alloc = std.testing.allocator;
    const p = getProvider("openai").?;
    const u = try buildUrl(alloc, p, null, null);
    defer alloc.free(u);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", u);
    const url2 = try buildUrl(alloc, p, "https://custom.example/", null);
    defer alloc.free(url2);
    try std.testing.expectEqualStrings("https://custom.example/v1/chat/completions", url2);
}

test "per-provider byte shape comparison" {
    // Parse each provider's native body and verify the exact top-level
    // keys upstream expects (byte-level shape, not just substring presence).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const msgs = "[{\"role\":\"user\",\"content\":\"hi\"}]";
    const cases = [_]struct { name: []const u8, keys: []const []const u8 }{
        .{ .name = "openai", .keys = &.{ "model", "messages", "max_tokens" } },
        .{ .name = "azure", .keys = &.{ "model", "messages", "max_tokens" } },
        .{ .name = "openrouter", .keys = &.{ "model", "messages", "max_tokens" } },
        .{ .name = "minimax", .keys = &.{ "model", "messages", "max_tokens" } },
        .{ .name = "volcengine", .keys = &.{ "model", "messages", "max_tokens" } },
        .{ .name = "nanogpt", .keys = &.{ "model", "messages", "max_tokens" } },
        .{ .name = "anthropic", .keys = &.{ "model", "max_tokens", "messages" } },
        .{ .name = "google", .keys = &.{ "contents" } },
        .{ .name = "novelai", .keys = &.{ "input", "model", "parameters" } },
        .{ .name = "horde", .keys = &.{ "prompt", "params" } },
        .{ .name = "kobold", .keys = &.{ "prompt", "max_length" } },
    };
    for (cases) |c| {
        const body = try buildNativeBody(alloc, c.name, "m", msgs, 7);
        defer alloc.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        try std.testing.expect(parsed.value == .object);
        for (c.keys) |k| {
            try std.testing.expect(parsed.value.object.get(k) != null);
        }
    }
}

test "novelai/horde/kobold exact body shapes" {
    // Upstream byte-shape check (src/endpoints/novelai.js:212 data={input,model,
    // parameters:{max_length}}). NovelAI must use "input", not "prompt".
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const msgs = "[{\"role\":\"user\",\"content\":\"hi\"}]";
    const nb = try buildNativeBody(alloc, "novelai", "nai", msgs, 42);
    defer alloc.free(nb);
    const np = try std.json.parseFromSlice(std.json.Value, alloc, nb, .{});
    defer np.deinit();
    try std.testing.expect(np.value.object.get("input") != null);
    try std.testing.expectEqualStrings("hi", np.value.object.get("input").?.string);
    try std.testing.expectEqualStrings("nai", np.value.object.get("model").?.string);
    const nparams = np.value.object.get("parameters").?;
    try std.testing.expect(nparams == .object);
    try std.testing.expectEqual(@as(i64, 42), nparams.object.get("max_length").?.integer);

    const hb = try buildNativeBody(alloc, "horde", "hm", msgs, 42);
    defer alloc.free(hb);
    const hp = try std.json.parseFromSlice(std.json.Value, alloc, hb, .{});
    defer hp.deinit();
    try std.testing.expectEqualStrings("hi", hp.value.object.get("prompt").?.string);
    const hparams = hp.value.object.get("params").?;
    try std.testing.expect(hparams == .object);
    try std.testing.expectEqualStrings("hm", hparams.object.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 42), hparams.object.get("max_length").?.integer);

    const kb = try buildNativeBody(alloc, "kobold", "km", msgs, 42);
    defer alloc.free(kb);
    const kp = try std.json.parseFromSlice(std.json.Value, alloc, kb, .{});
    defer kp.deinit();
    try std.testing.expectEqualStrings("hi", kp.value.object.get("prompt").?.string);
    try std.testing.expectEqual(@as(i64, 42), kp.value.object.get("max_length").?.integer);
}

test "appendSseDeltas extracts incremental deltas" {
    // RED: streaming pickup — parser must extract OpenAI-compatible SSE
    // deltas from a complete-lines buffer into the accumulator.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var full: std.ArrayListUnmanaged(u8) = .empty;
    defer full.deinit(alloc);
    const sse =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello \"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"there!\"}}]}\n\n" ++
        "data: [DONE]\n\n";
    try appendSseDeltas(alloc, sse, &full);
    try std.testing.expectEqualStrings("Hello there!", full.items);
}
