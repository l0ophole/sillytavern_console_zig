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
    return buildNativeBodyWithEffort(alloc, provider_name, model, messages_json, max_tokens, "");
}

pub fn buildNativeBodyWithEffort(alloc: std.mem.Allocator, provider_name: []const u8, model: []const u8, messages_json: []const u8, max_tokens: u32, reasoning_effort: []const u8) ![]u8 {
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
        // string content -> [{type:text,text}] with name prefix; array
        // content: text parts (name prefix, empty -> zero-width space) +
        // image_url data-URLs -> {type:image,source:{type:base64,...}}.
        // Thinking per upstream sendClaudeRequest + calculateClaudeBudgetTokens
        // (prompt-converters.js): thinking-capable models only; budget =
        // min 1024, low 10%, medium 25%, high 50%, max 95%, floor 1024,
        // cap 21333; auto/unknown -> no block; max_tokens bumped +1024 when
        // <=1024 (mutates max_tokens output like upstream).
        const mq = try std.json.parseFromSlice(std.json.Value, alloc, messages_json, .{});
        const msgs = if (mq.value == .array) mq.value.array.items else &[_]std.json.Value{};
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        var eff_max_tokens = max_tokens;
        var budget: ?u32 = null;
        const use_thinking = std.mem.startsWith(u8, model, "claude-3-7") or std.mem.indexOf(u8, model, "opus-4") != null or std.mem.indexOf(u8, model, "sonnet-4") != null or std.mem.indexOf(u8, model, "haiku-4-5") != null;
        if (use_thinking and reasoning_effort.len > 0 and !std.mem.eql(u8, reasoning_effort, "auto")) {
            var b: u32 = 0;
            if (std.mem.eql(u8, reasoning_effort, "min")) {
                b = 1024;
            } else if (std.mem.eql(u8, reasoning_effort, "low")) {
                b = @intCast((@as(u64, max_tokens) * 10) / 100);
            } else if (std.mem.eql(u8, reasoning_effort, "medium")) {
                b = @intCast((@as(u64, max_tokens) * 25) / 100);
            } else if (std.mem.eql(u8, reasoning_effort, "high")) {
                b = @intCast((@as(u64, max_tokens) * 50) / 100);
            } else if (std.mem.eql(u8, reasoning_effort, "max")) {
                b = @intCast((@as(u64, max_tokens) * 95) / 100);
            }
            if (b > 0) {
                if (b < 1024) b = 1024;
                if (b > 21333) b = 21333;
                if (eff_max_tokens <= 1024) eff_max_tokens += 1024;
                budget = b;
            }
        }
        try out.appendSlice(alloc, "{\"model\":");
        const model_q = try std.fmt.allocPrint(alloc, "\"{s}\"", .{model});
        defer alloc.free(model_q);
        try out.appendSlice(alloc, model_q);
        try out.appendSlice(alloc, ",\"max_tokens\":");
        const mt = try std.fmt.allocPrint(alloc, "{d}", .{eff_max_tokens});
        defer alloc.free(mt);
        try out.appendSlice(alloc, mt);
        if (budget) |b| {
            const tb = try std.fmt.allocPrint(alloc, ",\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{b});
            defer alloc.free(tb);
            try out.appendSlice(alloc, tb);
        }
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
        // Build converted messages first (with array-content + assistant-image move).
        // For each message, produce content blocks as JSON strings.
        var conv: std.ArrayListUnmanaged(struct { role: []const u8, blocks: std.ArrayListUnmanaged([]u8) }) = .empty;
        defer {
            for (conv.items) |*c| {
                for (c.blocks.items) |b| alloc.free(b);
                c.blocks.deinit(alloc);
            }
            conv.deinit(alloc);
        }
        for (msgs[sys_end..]) |m| {
            var role: []const u8 = "user";
            var name: []const u8 = "";
            var content_val: ?std.json.Value = null;
            if (m == .object) {
                if (m.object.get("role")) |r| {
                    if (r == .string) role = r.string;
                }
                if (m.object.get("content")) |c| content_val = c;
                if (m.object.get("name")) |n| {
                    if (n == .string) name = n.string;
                }
            }
            const crole_raw = role;
            const crole = if (std.mem.eql(u8, role, "system") or std.mem.eql(u8, role, "tool")) "user" else role;
            var blocks: std.ArrayListUnmanaged([]u8) = .empty;
            // Tool conversions per upstream prompt-converters.js.
            if (std.mem.eql(u8, crole_raw, "tool")) {
                var tc_id: []const u8 = "";
                var t_content: []const u8 = "";
                if (m == .object) {
                    if (m.object.get("tool_call_id")) |v| {
                        if (v == .string) tc_id = v.string;
                    }
                    if (m.object.get("content")) |v| {
                        if (v == .string) t_content = v.string;
                    }
                }
                const eq_id = try jsonEscaped(alloc, tc_id);
                defer alloc.free(eq_id);
                const eq_c = try jsonEscaped(alloc, t_content);
                defer alloc.free(eq_c);
                const one = try std.fmt.allocPrint(alloc, "{{\"type\":\"tool_result\",\"tool_use_id\":\"{s}\",\"content\":\"{s}\"}}", .{ eq_id, eq_c });
                try blocks.append(alloc, one);
            } else if (std.mem.eql(u8, crole_raw, "assistant") and m == .object and m.object.get("tool_calls") != null) {
                const tcs = m.object.get("tool_calls").?;
                if (tcs == .array) {
                    for (tcs.array.items) |tc| {
                        if (tc != .object) continue;
                        var tc_id: []const u8 = "";
                        var fn_name: []const u8 = "";
                        var fn_args: []const u8 = "{}";
                        if (tc.object.get("id")) |v| {
                            if (v == .string) tc_id = v.string;
                        }
                        if (tc.object.get("function")) |fnv| {
                            if (fnv == .object) {
                                if (fnv.object.get("name")) |v| {
                                    if (v == .string) fn_name = v.string;
                                }
                                if (fnv.object.get("arguments")) |v| {
                                    if (v == .string) fn_args = v.string;
                                }
                            }
                        }
                        const eq_id = try jsonEscaped(alloc, tc_id);
                        defer alloc.free(eq_id);
                        const eq_name = try jsonEscaped(alloc, fn_name);
                        defer alloc.free(eq_name);
                        // Parse arguments JSON (upstream parse); fallback {}.
                        var input_json: []u8 = undefined;
                        if (std.json.parseFromSlice(std.json.Value, alloc, fn_args, .{})) |parsed_args| {
                            var tmp: std.Io.Writer.Allocating = .init(alloc);
                            defer tmp.deinit();
                            var s: std.json.Stringify = .{ .writer = &tmp.writer };
                            try s.write(parsed_args.value);
                            input_json = try alloc.dupe(u8, tmp.written());
                            parsed_args.deinit();
                        } else |_| {
                            input_json = try alloc.dupe(u8, "{}");
                        }
                        defer alloc.free(input_json);
                        const one = try std.fmt.allocPrint(alloc, "{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{s}}}", .{ eq_id, eq_name, input_json });
                        try blocks.append(alloc, one);
                    }
                }
                if (blocks.items.len == 0) {
                    const one = try alloc.dupe(u8, "{\"type\":\"text\",\"text\":\"\"}");
                    try blocks.append(alloc, one);
                }
            } else if (content_val) |cv| {
                if (cv == .string) {
                    var text = cv.string;
                    var prefixed: ?[]u8 = null;
                    defer if (prefixed) |p| alloc.free(p);
                    if (name.len > 0 and !std.mem.startsWith(u8, cv.string, name)) {
                        prefixed = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ name, cv.string });
                        text = prefixed.?;
                    }
                    const eq = try jsonEscaped(alloc, text);
                    defer alloc.free(eq);
                    const one = try std.fmt.allocPrint(alloc, "{{\"type\":\"text\",\"text\":\"{s}\"}}", .{eq});
                    try blocks.append(alloc, one);
                } else if (cv == .array) {
                    for (cv.array.items) |part| {
                        if (part != .object) continue;
                        const ptype = if (part.object.get("type")) |t| if (t == .string) t.string else "" else "";
                        if (std.mem.eql(u8, ptype, "image_url")) {
                            var url: []const u8 = "";
                            if (part.object.get("image_url")) |iu| {
                                if (iu == .object) {
                                    if (iu.object.get("url")) |u| {
                                        if (u == .string) url = u.string;
                                    }
                                }
                            }
                            // Only data-URLs can be inlined (no base64 fetch).
                            if (std.mem.startsWith(u8, url, "data:")) {
                                if (std.mem.indexOfScalar(u8, url, ',')) |ci| {
                                    const header = url[0..ci];
                                    const data_b64 = url[ci + 1 ..];
                                    var media_type: []const u8 = "application/octet-stream";
                                    if (std.mem.indexOfScalar(u8, header, ';')) |si| {
                                        const mtype = header[5..si];
                                        if (mtype.len > 0) media_type = mtype;
                                    } else if (header.len > 5) {
                                        media_type = header[5..];
                                    }
                                    const eq_data = try jsonEscaped(alloc, data_b64);
                                    defer alloc.free(eq_data);
                                    const eq_mt = try jsonEscaped(alloc, media_type);
                                    defer alloc.free(eq_mt);
                                    const one = try std.fmt.allocPrint(alloc, "{{\"type\":\"image\",\"source\":{{\"type\":\"base64\",\"media_type\":\"{s}\",\"data\":\"{s}\"}}}}", .{ eq_mt, eq_data });
                                    try blocks.append(alloc, one);
                                }
                            }
                        } else if (std.mem.eql(u8, ptype, "text")) {
                            var t: []const u8 = "";
                            if (part.object.get("text")) |tv| {
                                if (tv == .string) t = tv.string;
                            }
                            var text = t;
                            var prefixed: ?[]u8 = null;
                            defer if (prefixed) |p| alloc.free(p);
                            if (name.len > 0 and t.len > 0 and !std.mem.startsWith(u8, t, name)) {
                                prefixed = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ name, t });
                                text = prefixed.?;
                            }
                            if (text.len == 0) text = "\u{200b}";
                            const eq = try jsonEscaped(alloc, text);
                            defer alloc.free(eq);
                            const one = try std.fmt.allocPrint(alloc, "{{\"type\":\"text\",\"text\":\"{s}\"}}", .{eq});
                            try blocks.append(alloc, one);
                        } else {
                            // Preserve other part types verbatim.
                            var tmp: std.Io.Writer.Allocating = .init(alloc);
                            defer tmp.deinit();
                            var s: std.json.Stringify = .{ .writer = &tmp.writer };
                            try s.write(part);
                            const one = try alloc.dupe(u8, tmp.written());
                            try blocks.append(alloc, one);
                        }
                    }
                }
            }
            try conv.append(alloc, .{ .role = crole, .blocks = blocks });
        }
        // Move assistant images to next user message (upstream loop).
        var i: usize = 0;
        while (i < conv.items.len) {
            if (std.mem.eql(u8, conv.items[i].role, "assistant")) {
                var has_image = false;
                for (conv.items[i].blocks.items) |b| {
                    if (std.mem.indexOf(u8, b, "\"type\":\"image\"") != null) has_image = true;
                }
                if (!has_image) {
                    i += 1;
                    continue;
                }
                var j = i + 1;
                while (j < conv.items.len and !std.mem.eql(u8, conv.items[j].role, "user")) j += 1;
                if (j >= conv.items.len) {
                    try conv.append(alloc, .{ .role = "user", .blocks = .empty });
                    j = conv.items.len - 1;
                }
                var w: usize = 0;
                while (w < conv.items[i].blocks.items.len) {
                    const blk = conv.items[i].blocks.items[w];
                    if (std.mem.indexOf(u8, blk, "\"type\":\"image\"") != null) {
                        try conv.items[j].blocks.append(alloc, blk);
                        // Remove from assistant (swap-with-last).
                        const last = conv.items[i].blocks.items.len - 1;
                        conv.items[i].blocks.items[w] = conv.items[i].blocks.items[last];
                        conv.items[i].blocks.items[last] = blk;
                        _ = conv.items[i].blocks.pop();
                    } else {
                        w += 1;
                    }
                }
            }
            i += 1;
        }
        for (conv.items) |c| {
            if (!first) try out.append(alloc, ',');
            first = false;
            var arr: std.ArrayListUnmanaged(u8) = .empty;
            defer arr.deinit(alloc);
            try arr.append(alloc, '[');
            for (c.blocks.items, 0..) |b, idx| {
                if (idx > 0) try arr.append(alloc, ',');
                try arr.appendSlice(alloc, b);
            }
            try arr.append(alloc, ']');
            const one = try std.fmt.allocPrint(alloc, "{{\"role\":\"{s}\",\"content\":{s}}}", .{ c.role, arr.items });
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
        var conv: std.ArrayListUnmanaged(struct { role: []const u8, parts: std.ArrayListUnmanaged([]u8) }) = .empty;
        defer {
            for (conv.items) |*c| {
                for (c.parts.items) |b| alloc.free(b);
                c.parts.deinit(alloc);
            }
            conv.deinit(alloc);
        }
        var tool_name_map: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer tool_name_map.deinit(alloc);
        for (msgs[sys_end..]) |m| {
            var role: []const u8 = "user";
            var name: []const u8 = "";
            var content_val: ?std.json.Value = null;
            if (m == .object) {
                if (m.object.get("role")) |r| {
                    if (r == .string) role = r.string;
                }
                if (m.object.get("content")) |c| content_val = c;
                if (m.object.get("name")) |n| {
                    if (n == .string) name = n.string;
                }
            }
            const crole: []const u8 = if (std.mem.eql(u8, role, "assistant")) "model" else "user";
            var parts: std.ArrayListUnmanaged([]u8) = .empty;
            // Tools per upstream convertGooglePrompt (string-content tools only).
            var has_tool_calls = false;
            var has_tool_call_id = false;
            if (m == .object) {
                if (m.object.get("tool_calls")) |tc| {
                    if (tc == .array and tc.array.items.len > 0) has_tool_calls = true;
                }
                if (m.object.get("tool_call_id")) |v| {
                    if (v == .string and v.string.len > 0) has_tool_call_id = true;
                }
            }
            if (has_tool_calls) {
                const tcs = m.object.get("tool_calls").?;
                for (tcs.array.items) |tc| {
                    if (tc != .object) continue;
                    var tc_id: []const u8 = "";
                    var fn_name: []const u8 = "";
                    var fn_args: []const u8 = "{}";
                    if (tc.object.get("id")) |v| {
                        if (v == .string) tc_id = v.string;
                    }
                    if (tc.object.get("function")) |fnv| {
                        if (fnv == .object) {
                            if (fnv.object.get("name")) |v| {
                                if (v == .string) fn_name = v.string;
                            }
                            if (fnv.object.get("arguments")) |v| {
                                if (v == .string) fn_args = v.string;
                            }
                        }
                    }
                    if (tc_id.len > 0) try tool_name_map.put(alloc, tc_id, fn_name);
                    const eq_name = try jsonEscaped(alloc, fn_name);
                    defer alloc.free(eq_name);
                    var args_json: []u8 = undefined;
                    if (std.json.parseFromSlice(std.json.Value, alloc, fn_args, .{})) |pa| {
                        var tmp: std.Io.Writer.Allocating = .init(alloc);
                        defer tmp.deinit();
                        var s: std.json.Stringify = .{ .writer = &tmp.writer };
                        try s.write(pa.value);
                        args_json = try alloc.dupe(u8, tmp.written());
                        pa.deinit();
                    } else |_| {
                        const eq_args = try jsonEscaped(alloc, fn_args);
                        defer alloc.free(eq_args);
                        args_json = try std.fmt.allocPrint(alloc, "\"{s}\"", .{eq_args});
                    }
                    defer alloc.free(args_json);
                    // Gemini 3 bypass magic (upstream convertGooglePrompt).
                    const is_gemini3 = std.mem.indexOf(u8, model, "gemini-3") != null;
                    const one = if (is_gemini3)
                        try std.fmt.allocPrint(alloc, "{{\"functionCall\":{{\"name\":\"{s}\",\"args\":{s}}},\"thoughtSignature\":\"skip_thought_signature_validator\"}}", .{ eq_name, args_json })
                    else
                        try std.fmt.allocPrint(alloc, "{{\"functionCall\":{{\"name\":\"{s}\",\"args\":{s}}}}}", .{ eq_name, args_json });
                    try parts.append(alloc, one);
                }
            } else if (has_tool_call_id) {
                var tc_id: []const u8 = "";
                var t_content: []const u8 = "";
                if (m.object.get("tool_call_id")) |v| {
                    if (v == .string) tc_id = v.string;
                }
                if (content_val) |cv| {
                    if (cv == .string) t_content = cv.string;
                }
                const fn_name = tool_name_map.get(tc_id) orelse "unknown";
                const eq_name = try jsonEscaped(alloc, fn_name);
                defer alloc.free(eq_name);
                const eq_c = try jsonEscaped(alloc, t_content);
                defer alloc.free(eq_c);
                const one = try std.fmt.allocPrint(alloc, "{{\"functionResponse\":{{\"name\":\"{s}\",\"response\":{{\"name\":\"{s}\",\"content\":\"{s}\"}}}}}}", .{ eq_name, eq_name, eq_c });
                try parts.append(alloc, one);
            } else if (content_val) |cv| {
                if (cv == .string) {
                    var text = cv.string;
                    var prefixed: ?[]u8 = null;
                    defer if (prefixed) |p| alloc.free(p);
                    if (name.len > 0 and !std.mem.startsWith(u8, cv.string, name)) {
                        prefixed = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ name, cv.string });
                        text = prefixed.?;
                    }
                    const eq = try jsonEscaped(alloc, text);
                    defer alloc.free(eq);
                    const one = try std.fmt.allocPrint(alloc, "{{\"text\":\"{s}\"}}", .{eq});
                    try parts.append(alloc, one);
                } else if (cv == .array) {
                    for (cv.array.items) |part| {
                        if (part != .object) continue;
                        const ptype = if (part.object.get("type")) |t| if (t == .string) t.string else "" else "";
                        if (std.mem.eql(u8, ptype, "text")) {
                            var t: []const u8 = "";
                            if (part.object.get("text")) |tv| {
                                if (tv == .string) t = tv.string;
                            }
                            var text = t;
                            var prefixed: ?[]u8 = null;
                            defer if (prefixed) |p| alloc.free(p);
                            if (name.len > 0 and t.len > 0 and !std.mem.startsWith(u8, t, name)) {
                                prefixed = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ name, t });
                                text = prefixed.?;
                            }
                            const eq = try jsonEscaped(alloc, text);
                            defer alloc.free(eq);
                            const one = try std.fmt.allocPrint(alloc, "{{\"text\":\"{s}\"}}", .{eq});
                            try parts.append(alloc, one);
                        } else if (std.mem.eql(u8, ptype, "image_url")) {
                            var url: []const u8 = "";
                            if (part.object.get("image_url")) |iu| {
                                if (iu == .object) {
                                    if (iu.object.get("url")) |u| {
                                        if (u == .string) url = u.string;
                                    }
                                }
                            }
                            if (std.mem.startsWith(u8, url, "data:")) {
                                if (std.mem.indexOfScalar(u8, url, ',')) |ci| {
                                    const header = url[0..ci];
                                    const data_b64 = url[ci + 1 ..];
                                    var mimetype: []const u8 = "image/png";
                                    if (std.mem.indexOfScalar(u8, header, ';')) |si| {
                                        const mtype = header[5..si];
                                        if (mtype.len > 0) mimetype = mtype;
                                    } else if (header.len > 5) {
                                        mimetype = header[5..];
                                    }
                                    var detail: []const u8 = "";
                                    if (part.object.get("image_url")) |iu| {
                                        if (iu == .object) {
                                            if (iu.object.get("detail")) |d| {
                                                if (d == .string) detail = d.string;
                                            }
                                        }
                                    }
                                    const eq_data = try jsonEscaped(alloc, data_b64);
                                    defer alloc.free(eq_data);
                                    const eq_mt = try jsonEscaped(alloc, mimetype);
                                    defer alloc.free(eq_mt);
                                    const is_gemini3 = std.mem.indexOf(u8, model, "gemini-3") != null;
                                    var level: ?[]const u8 = null;
                                    if (is_gemini3 and std.mem.eql(u8, detail, "low")) level = "media_resolution_low";
                                    if (is_gemini3 and std.mem.eql(u8, detail, "high")) level = "media_resolution_high";
                                    const one = if (level) |lv|
                                        try std.fmt.allocPrint(alloc, "{{\"inlineData\":{{\"mimeType\":\"{s}\",\"data\":\"{s}\"}},\"mediaResolution\":{{\"level\":\"{s}\"}}}}", .{ eq_mt, eq_data, lv })
                                    else
                                        try std.fmt.allocPrint(alloc, "{{\"inlineData\":{{\"mimeType\":\"{s}\",\"data\":\"{s}\"}}}}", .{ eq_mt, eq_data });
                                    try parts.append(alloc, one);
                                }
                            }
                        }
                    }
                }
            }
            // Merge consecutive same-role (upstream loop).
            if (conv.items.len > 0 and std.mem.eql(u8, conv.items[conv.items.len - 1].role, crole)) {
                for (parts.items) |b| try conv.items[conv.items.len - 1].parts.append(alloc, b);
                parts.deinit(alloc);
            } else {
                try conv.append(alloc, .{ .role = crole, .parts = parts });
            }
        }
        var first = true;
        for (conv.items) |c| {
            if (!first) try out.append(alloc, ',');
            first = false;
            var arr: std.ArrayListUnmanaged(u8) = .empty;
            defer arr.deinit(alloc);
            try arr.append(alloc, '[');
            const is_gemini3 = std.mem.indexOf(u8, model, "gemini-3") != null;
            const is_image_model = std.mem.indexOf(u8, model, "-image") != null;
            for (c.parts.items, 0..) |b, idx| {
                if (idx > 0) try arr.append(alloc, ',');
                // Gemini 3 -image: model-role text/inlineData parts get bypass magic.
                if (is_gemini3 and is_image_model and std.mem.eql(u8, c.role, "model") and (std.mem.indexOf(u8, b, "\"text\":") != null or std.mem.indexOf(u8, b, "\"inlineData\":") != null) and std.mem.indexOf(u8, b, "\"thoughtSignature\":") == null) {
                    const stemmed = b[0 .. b.len - 1]; // strip closing '}'
                    try arr.appendSlice(alloc, stemmed);
                    if (std.mem.indexOf(u8, b, "\"inlineData\":") != null) try arr.append(alloc, '}');
                    try arr.appendSlice(alloc, ",\"thoughtSignature\":\"skip_thought_signature_validator\"}");
                } else {
                    try arr.appendSlice(alloc, b);
                }
            }
            try arr.append(alloc, ']');
            const one = try std.fmt.allocPrint(alloc, "{{\"role\":\"{s}\",\"parts\":{s}}}", .{ c.role, arr.items });
            defer alloc.free(one);
            try out.appendSlice(alloc, one);
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

test "anthropic image_url conversion" {
    // RED: upstream prompt-converters.js converts image_url data-URLs to
    // {type:image,source:{type:base64,media_type,data}} blocks.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const msgs = "[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"what is this\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,iVBORw0=\"}}]}]";
    const body = try buildNativeBody(alloc, "anthropic", "claude-3", msgs, 100);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const out_msgs = parsed.value.object.get("messages").?;
    try std.testing.expect(out_msgs == .array);
    try std.testing.expectEqual(@as(usize, 1), out_msgs.array.items.len);
    const content = out_msgs.array.items[0].object.get("content").?;
    try std.testing.expect(content == .array);
    try std.testing.expectEqual(@as(usize, 2), content.array.items.len);
    try std.testing.expectEqualStrings("text", content.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("what is this", content.array.items[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("image", content.array.items[1].object.get("type").?.string);
    const source = content.array.items[1].object.get("source").?;
    try std.testing.expect(source == .object);
    try std.testing.expectEqualStrings("base64", source.object.get("type").?.string);
    try std.testing.expectEqualStrings("image/png", source.object.get("media_type").?.string);
    try std.testing.expectEqualStrings("iVBORw0=", source.object.get("data").?.string);
}

test "google image_url conversion" {
    // RED: upstream convertGooglePrompt addDataUrlPart maps image_url data-URLs
    // to {inlineData:{mimeType,data}} parts.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const msgs = "[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"what is this\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,iVBORw0=\"}}]}]";
    const body = try buildNativeBody(alloc, "google", "gemini-pro", msgs, 100);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const contents = parsed.value.object.get("contents").?;
    try std.testing.expect(contents == .array);
    try std.testing.expectEqual(@as(usize, 1), contents.array.items.len);
    const parts = contents.array.items[0].object.get("parts").?;
    try std.testing.expect(parts == .array);
    try std.testing.expectEqual(@as(usize, 2), parts.array.items.len);
    try std.testing.expectEqualStrings("what is this", parts.array.items[0].object.get("text").?.string);
    const inline_data = parts.array.items[1].object.get("inlineData").?;
    try std.testing.expect(inline_data == .object);
    try std.testing.expectEqualStrings("image/png", inline_data.object.get("mimeType").?.string);
    try std.testing.expectEqualStrings("iVBORw0=", inline_data.object.get("data").?.string);
}

test "anthropic tool_use/tool_result conversion" {
    // RED: upstream convertClaudeMessages maps assistant tool_calls ->
    // {type:tool_use,id,name,input} (args JSON-parsed) and tool role ->
    // user {type:tool_result,tool_use_id,content}.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const msgs = "[{\"role\":\"user\",\"content\":\"hi\"},{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"call_1\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Paris\\\"}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"sunny\"}]";
    const body = try buildNativeBody(alloc, "anthropic", "claude-3", msgs, 100);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const out_msgs = parsed.value.object.get("messages").?;
    try std.testing.expect(out_msgs == .array);
    try std.testing.expectEqual(@as(usize, 3), out_msgs.array.items.len);
    // assistant tool_use
    try std.testing.expectEqualStrings("assistant", out_msgs.array.items[1].object.get("role").?.string);
    const a_content = out_msgs.array.items[1].object.get("content").?;
    try std.testing.expect(a_content == .array);
    try std.testing.expectEqual(@as(usize, 1), a_content.array.items.len);
    try std.testing.expectEqualStrings("tool_use", a_content.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", a_content.array.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("get_weather", a_content.array.items[0].object.get("name").?.string);
    const tool_input = a_content.array.items[0].object.get("input").?;
    try std.testing.expect(tool_input == .object);
    try std.testing.expectEqualStrings("Paris", tool_input.object.get("city").?.string);
    // tool -> user tool_result
    try std.testing.expectEqualStrings("user", out_msgs.array.items[2].object.get("role").?.string);
    const t_content = out_msgs.array.items[2].object.get("content").?;
    try std.testing.expect(t_content == .array);
    try std.testing.expectEqualStrings("tool_result", t_content.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", t_content.array.items[0].object.get("tool_use_id").?.string);
    try std.testing.expectEqualStrings("sunny", t_content.array.items[0].object.get("content").?.string);
}

test "google tool functionCall/functionResponse conversion" {
    // RED: upstream convertGooglePrompt maps string tool_calls ->
    // {functionCall:{name,args}} and tool_call_id ->
    // {functionResponse:{name,response:{name,content}}} with toolNameMap.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const msgs = "[{\"role\":\"user\",\"content\":\"hi\"},{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"call_1\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Paris\\\"}\"}}]},{\"role\":\"user\",\"tool_call_id\":\"call_1\",\"content\":\"sunny\"}]";
    const body = try buildNativeBody(alloc, "google", "gemini-pro", msgs, 100);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const contents = parsed.value.object.get("contents").?;
    try std.testing.expect(contents == .array);
    try std.testing.expectEqual(@as(usize, 3), contents.array.items.len);
    // assistant functionCall
    try std.testing.expectEqualStrings("model", contents.array.items[1].object.get("role").?.string);
    const a_parts = contents.array.items[1].object.get("parts").?;
    try std.testing.expectEqual(@as(usize, 1), a_parts.array.items.len);
    const fc = a_parts.array.items[0].object.get("functionCall").?;
    try std.testing.expectEqualStrings("get_weather", fc.object.get("name").?.string);
    const fc_args = fc.object.get("args").?;
    try std.testing.expect(fc_args == .object);
    try std.testing.expectEqualStrings("Paris", fc_args.object.get("city").?.string);
    // functionResponse
    const t_parts = contents.array.items[2].object.get("parts").?;
    const fr = t_parts.array.items[0].object.get("functionResponse").?;
    try std.testing.expectEqualStrings("get_weather", fr.object.get("name").?.string);
    const fr_resp = fr.object.get("response").?;
    try std.testing.expectEqualStrings("sunny", fr_resp.object.get("content").?.string);
}

test "anthropic thinking budget" {
    // RED: upstream sendClaudeRequest adds thinking:{type:enabled,
    // budget_tokens} for thinking-capable models when reasoning_effort set,
    // with max_tokens bump when <=1024.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const msgs = "[{\"role\":\"user\",\"content\":\"hi\"}]";
    const body = try buildNativeBodyWithEffort(alloc, "anthropic", "claude-3-7-sonnet", msgs, 4096, "medium");
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.get("thinking") != null);
    const thinking = parsed.value.object.get("thinking").?;
    try std.testing.expect(thinking == .object);
    try std.testing.expectEqualStrings("enabled", thinking.object.get("type").?.string);
    // medium = 25% of 4096 = 1024
    try std.testing.expectEqual(@as(i64, 1024), thinking.object.get("budget_tokens").?.integer);
    try std.testing.expectEqual(@as(i64, 4096), parsed.value.object.get("max_tokens").?.integer);

    // small max_tokens bumps to max_tokens+1024 like upstream
    const body2 = try buildNativeBodyWithEffort(alloc, "anthropic", "claude-3-7-sonnet", msgs, 500, "low");
    defer alloc.free(body2);
    const parsed2 = try std.json.parseFromSlice(std.json.Value, alloc, body2, .{});
    defer parsed2.deinit();
    const thinking2 = parsed2.value.object.get("thinking").?;
    try std.testing.expectEqualStrings("enabled", thinking2.object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 1524), parsed2.value.object.get("max_tokens").?.integer);

    // auto effort -> no thinking block
    const body3 = try buildNativeBodyWithEffort(alloc, "anthropic", "claude-3-7-sonnet", msgs, 4096, "auto");
    defer alloc.free(body3);
    const parsed3 = try std.json.parseFromSlice(std.json.Value, alloc, body3, .{});
    defer parsed3.deinit();
    try std.testing.expect(parsed3.value.object.get("thinking") == null);
}

test "gemini-3 thoughtSignature bypass" {
    // RED: upstream convertGooglePrompt adds thoughtSignature bypass magic
    // to functionCall parts on gemini-3 models.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const msgs = "[{\"role\":\"user\",\"content\":\"hi\"},{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"call_1\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Paris\\\"}\"}}]}]";
    const body = try buildNativeBody(alloc, "google", "gemini-3-pro", msgs, 100);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const contents = parsed.value.object.get("contents").?;
    try std.testing.expectEqual(@as(usize, 2), contents.array.items.len);
    const parts = contents.array.items[1].object.get("parts").?;
    const part0 = parts.array.items[0];
    try std.testing.expectEqualStrings("skip_thought_signature_validator", part0.object.get("thoughtSignature").?.string);

    // non-gemini-3 has no bypass
    const body2 = try buildNativeBody(alloc, "google", "gemini-pro", msgs, 100);
    defer alloc.free(body2);
    const parsed2 = try std.json.parseFromSlice(std.json.Value, alloc, body2, .{});
    defer parsed2.deinit();
    const contents2 = parsed2.value.object.get("contents").?;
    const parts2 = contents2.array.items[1].object.get("parts").?;
    try std.testing.expect(parts2.array.items[0].object.get("thoughtSignature") == null);
}

test "gemini-3 mediaResolution detail" {
    // RED: upstream addDataUrlPart maps image_url detail low/high ->
    // mediaResolution:{level} on gemini-3 models.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const msgs = "[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,iVBORw0=\",\"detail\":\"low\"}}]}]";
    const body = try buildNativeBody(alloc, "google", "gemini-3-pro", msgs, 100);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const contents = parsed.value.object.get("contents").?;
    const part = contents.array.items[0].object.get("parts").?.array.items[0];
    const mr = part.object.get("mediaResolution").?;
    try std.testing.expect(mr == .object);
    try std.testing.expectEqualStrings("media_resolution_low", mr.object.get("level").?.string);

    // non-gemini-3 has no mediaResolution even with detail
    const body2 = try buildNativeBody(alloc, "google", "gemini-pro", msgs, 100);
    defer alloc.free(body2);
    const parsed2 = try std.json.parseFromSlice(std.json.Value, alloc, body2, .{});
    defer parsed2.deinit();
    const contents2 = parsed2.value.object.get("contents").?;
    const part2 = contents2.array.items[0].object.get("parts").?.array.items[0];
    try std.testing.expect(part2.object.get("mediaResolution") == null);
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
