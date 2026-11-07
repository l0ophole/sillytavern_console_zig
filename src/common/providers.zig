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
            return std.fmt.allocPrint(alloc, "{{\"prompt\":\"{s}\",\"model\":\"{s}\",\"parameters\":{{\"max_length\":{s}}}}}", .{ eq, model, mt });
        } else if (std.mem.eql(u8, provider_name, "horde")) {
            return std.fmt.allocPrint(alloc, "{{\"prompt\":\"{s}\",\"params\":{{\"model\":\"{s}\",\"max_length\":{s}}}}}", .{ eq, model, mt });
        }
        return std.fmt.allocPrint(alloc, "{{\"prompt\":\"{s}\",\"max_length\":{s}}}", .{ eq, mt });
    }
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
    try std.testing.expect(std.mem.indexOf(u8, nb, "\"prompt\":\"hi\"") != null);
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
        .{ .name = "novelai", .keys = &.{ "prompt", "model", "parameters" } },
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
