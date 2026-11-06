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

/// Normalize provider-specific chat request body.
pub fn buildNativeBody(alloc: std.mem.Allocator, provider_name: []const u8, model: []const u8, messages_json: []const u8, max_tokens: u32) ![]u8 {
    if (std.mem.eql(u8, provider_name, "anthropic")) {
        // Anthropic: {model, max_tokens, messages}
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
        try out.appendSlice(alloc, ",\"messages\":[");
        for (msgs, 0..) |m, idx| {
            if (idx > 0) try out.append(alloc, ',');
            // Serialize each message via Stringify
            var tmp: std.Io.Writer.Allocating = .init(alloc);
            defer tmp.deinit();
            var s: std.json.Stringify = .{ .writer = &tmp.writer };
            try s.write(m);
            try out.appendSlice(alloc, tmp.written());
        }
        try out.appendSlice(alloc, "]}");
        return out.toOwnedSlice(alloc);
    } else if (std.mem.eql(u8, provider_name, "google")) {
        // Google: {contents:[{role, parts:[{text}]}]}
        const mq = try std.json.parseFromSlice(std.json.Value, alloc, messages_json, .{});
        const msgs = if (mq.value == .array) mq.value.array.items else &[_]std.json.Value{};
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        try out.appendSlice(alloc, "{\"contents\":[");
        for (msgs, 0..) |m, idx| {
            if (idx > 0) try out.append(alloc, ',');
            var role: []const u8 = "user";
            var content: []const u8 = "";
            if (m == .object) {
                if (m.object.get("role")) |r| {
                    if (r == .string) role = if (std.mem.eql(u8, r.string, "assistant")) "model" else "user";
                }
                if (m.object.get("content")) |c| {
                    if (c == .string) content = c.string;
                }
            }
            // escape quotes in content for JSON (simple: replace " with \")
            var esc: std.ArrayListUnmanaged(u8) = .empty;
            defer esc.deinit(alloc);
            for (content) |ch| {
                if (ch == '"' or ch == '\\') try esc.append(alloc, '\\');
                if (ch == '\n') {
                    try esc.appendSlice(alloc, "\\n");
                } else {
                    try esc.append(alloc, ch);
                }
            }
            const eq = try esc.toOwnedSlice(alloc);
            defer alloc.free(eq);
            const part = try std.fmt.allocPrint(alloc, "{{\"role\":\"{s}\",\"parts\":[{{\"text\":\"{s}\"}}]}}", .{ role, eq });
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
    return std.fmt.allocPrint(alloc, "{{\"model\":\"{s}\",\"messages\":{s}}}", .{ model, tmp2.written() });
}

/// Extract text from provider-specific response body.
pub fn parseNativeResponse(alloc: std.mem.Allocator, provider_name: []const u8, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    if (parsed.value != .object) return alloc.dupe(u8, "");
    if (std.mem.eql(u8, provider_name, "anthropic")) {
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
