const std = @import("std");

// Stage 2 prompt engine: macros, World Info selection, Author's Note insertion,
// instruct/context template application. Pure functions + unit tests; the
// server (chat.turn / prompt.preview) wires them to cards, chats and presets.
// Upstream reference: SillyTavern/public/scripts/macros/definitions/*.js,
// world-info.js (getSortedEntries: constant first, then key match),
// authors-note.js (note inserted at depth from end), instruct-mode.js
// (input/output/system sequences with {{name}}).

pub const MacroCtx = struct {
    char: []const u8 = "",
    user: []const u8 = "User",
    last_message: []const u8 = "",
    last_user_message: []const u8 = "",
    last_char_message: []const u8 = "",
    time_str: []const u8 = "", // HH:MM, empty = use current time
    date_str: []const u8 = "", // YYYY-MM-DD, empty = today
    weekday_str: []const u8 = "",
    vars: std.StringHashMap([]const u8),
};

fn civilFromDays(alloc: std.mem.Allocator, secs: i64) ![]u8 {
    const days: i64 = @divFloor(secs, 86400);
    // Howard Hinnant civil_from_days
    const z: i64 = days + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    var y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u64 = doy - (153 * mp + 2) / 5 + 1;
    const m: u64 = if (mp < 10) mp + 3 else mp - 9;
    if (m <= 2) y += 1;
    const rem: i64 = @mod(secs, 86400);
    const hh: i64 = @divFloor(rem, 3600);
    const mm: i64 = @divFloor(@mod(rem, 3600), 60);
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ y, m, d, hh, mm });
}
fn nowTime(alloc: std.mem.Allocator) []u8 {
    const ts = std.time.milliTimestamp();
    const full = civilFromDays(alloc, @divFloor(ts, 1000)) catch return &.{};
    defer alloc.free(full);
    return alloc.dupe(u8, full[11..]) catch return &.{};
}
fn nowDate(alloc: std.mem.Allocator) []u8 {
    const ts = std.time.milliTimestamp();
    const full = civilFromDays(alloc, @divFloor(ts, 1000)) catch return &.{};
    defer alloc.free(full);
    return alloc.dupe(u8, full[0..10]) catch return &.{};
}
fn nowWeekday(alloc: std.mem.Allocator) []u8 {
    const ts = std.time.milliTimestamp();
    const days: i64 = @divFloor(@divFloor(ts, 1000), 86400);
    // 1970-01-01 was Thursday; index 0=Sunday
    const names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    const idx: usize = @intCast(@mod(days + 4, 7));
    return alloc.dupe(u8, names[idx]) catch return &.{};
}

fn randBelow(n: usize) usize {
    if (n == 0) return 0;
    var b: [8]u8 = undefined;
    std.crypto.random.bytes(&b);
    const v = std.mem.readInt(u64, &b, .little);
    return @intCast(v % @as(u64, @intCast(n)));
}

// Expand {{macro}} / {{macro::arg1::arg2}} / {{macro arg}} in text.
pub fn expandMacros(alloc: std.mem.Allocator, text: []const u8, ctx: *MacroCtx) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '{' and text[i + 1] == '{') {
            if (std.mem.indexOf(u8, text[i + 2 ..], "}}")) |rel| {
                const inner = std.mem.trim(u8, text[i + 2 .. i + 2 + rel], " \t");
                const expanded = expandOne(alloc, inner, ctx);
                if (expanded) |e| {
                    defer alloc.free(e);
                    try out.appendSlice(alloc, e);
                    i += 2 + rel + 2;
                    continue;
                }
            }
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn expandOne(alloc: std.mem.Allocator, inner: []const u8, ctx: *MacroCtx) ?[]u8 {
    // Split name from args: {{name::a::b}} or {{name a b}}
    var name = inner;
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(alloc);
    if (std.mem.indexOf(u8, inner, "::")) |sep| {
        name = inner[0..sep];
        var it = std.mem.splitSequence(u8, inner[sep + 2 ..], "::");
        while (it.next()) |a| args.append(alloc, a) catch return null;
    } else if (std.mem.indexOfScalar(u8, inner, ' ')) |sp| {
        name = inner[0..sp];
        var it = std.mem.splitScalar(u8, inner[sp + 1 ..], ' ');
        while (it.next()) |a| {
            if (a.len > 0) args.append(alloc, a) catch return null;
        }
    }
    const n = std.mem.trim(u8, name, " \t");
    const arg = struct {
        fn get(args_list: std.ArrayListUnmanaged([]const u8), idx: usize) []const u8 {
            return if (idx < args_list.items.len) args_list.items[idx] else "";
        }
    }.get;
    if (std.mem.eql(u8, n, "char")) return alloc.dupe(u8, ctx.char) catch null;
    if (std.mem.eql(u8, n, "user")) return alloc.dupe(u8, ctx.user) catch null;
    if (std.mem.eql(u8, n, "lastMessage")) return alloc.dupe(u8, ctx.last_message) catch null;
    if (std.mem.eql(u8, n, "lastUserMessage")) return alloc.dupe(u8, ctx.last_user_message) catch null;
    if (std.mem.eql(u8, n, "lastCharMessage")) return alloc.dupe(u8, ctx.last_char_message) catch null;
    if (std.mem.eql(u8, n, "time")) {
        if (ctx.time_str.len > 0) return alloc.dupe(u8, ctx.time_str) catch null;
        return nowTime(alloc);
    }
    if (std.mem.eql(u8, n, "date")) {
        if (ctx.date_str.len > 0) return alloc.dupe(u8, ctx.date_str) catch null;
        return nowDate(alloc);
    }
    if (std.mem.eql(u8, n, "weekday")) {
        if (ctx.weekday_str.len > 0) return alloc.dupe(u8, ctx.weekday_str) catch null;
        return nowWeekday(alloc);
    }
    if (std.mem.eql(u8, n, "space")) return alloc.dupe(u8, " ") catch null;
    if (std.mem.eql(u8, n, "newline")) return alloc.dupe(u8, "\n") catch null;
    if (std.mem.eql(u8, n, "trim") or std.mem.eql(u8, n, "noop") or std.mem.eql(u8, n, "//")) return alloc.dupe(u8, "") catch null;
    if (std.mem.eql(u8, n, "random") or std.mem.eql(u8, n, "pick")) {
        if (args.items.len == 0) return alloc.dupe(u8, "") catch null;
        const idx = randBelow(args.items.len);
        if (std.mem.eql(u8, n, "pick")) return alloc.dupe(u8, args.items[0]) catch null;
        return alloc.dupe(u8, args.items[idx]) catch null;
    }
    if (std.mem.eql(u8, n, "roll")) {
        const formula = arg(args, 0);
        if (formula.len == 0) return alloc.dupe(u8, "") catch null;
        // Support NdM, dM, M (1dM); ignore +K suffix for simplicity (documented)
        var f = formula;
        if (std.mem.indexOfScalar(u8, f, '+')) |plus| f = f[0..plus];
        if (std.mem.indexOfScalar(u8, f, 'd')) |d| {
            const nd = std.fmt.parseInt(i64, f[0..d], 10) catch 1;
            const m = std.fmt.parseInt(i64, f[d + 1 ..], 10) catch return alloc.dupe(u8, "") catch null;
            if (m <= 0 or nd <= 0) return alloc.dupe(u8, "") catch null;
            var total: i64 = 0;
            var k: i64 = 0;
            while (k < nd) : (k += 1) total += @intCast(randBelow(@intCast(m)) + 1);
            return std.fmt.allocPrint(alloc, "{d}", .{total}) catch null;
        }
        const m = std.fmt.parseInt(i64, f, 10) catch return alloc.dupe(u8, "") catch null;
        if (m <= 0) return alloc.dupe(u8, "") catch null;
        return std.fmt.allocPrint(alloc, "{d}", .{randBelow(@intCast(m)) + 1}) catch null;
    }
    if (std.mem.eql(u8, n, "setvar")) {
        const k = arg(args, 0);
        const v = arg(args, 1);
        if (k.len > 0) {
            if (ctx.vars.getPtr(k)) |old| alloc.free(old.*);
            const key_copy = if (ctx.vars.contains(k)) k else alloc.dupe(u8, k) catch return null;
            ctx.vars.put(key_copy, alloc.dupe(u8, v) catch return null) catch return null;
        }
        return alloc.dupe(u8, "") catch null;
    }
    if (std.mem.eql(u8, n, "getvar")) {
        const k = arg(args, 0);
        if (ctx.vars.get(k)) |v| return alloc.dupe(u8, v) catch null;
        return alloc.dupe(u8, "") catch null;
    }
    if (std.mem.eql(u8, n, "addvar") or std.mem.eql(u8, n, "incvar") or std.mem.eql(u8, n, "decvar")) {
        const k = arg(args, 0);
        const delta: i64 = if (std.mem.eql(u8, n, "addvar")) std.fmt.parseInt(i64, arg(args, 1), 10) catch 0 else if (std.mem.eql(u8, n, "incvar")) 1 else -1;
        const cur: i64 = if (ctx.vars.get(k)) |v| std.fmt.parseInt(i64, v, 10) catch 0 else 0;
        const nv = cur + delta;
        if (k.len > 0) {
            if (ctx.vars.getPtr(k)) |old| alloc.free(old.*);
            const key_copy = if (ctx.vars.contains(k)) k else alloc.dupe(u8, k) catch return null;
            ctx.vars.put(key_copy, std.fmt.allocPrint(alloc, "{d}", .{nv}) catch return null) catch return null;
        }
        return alloc.dupe(u8, "") catch null;
    }
    if (std.mem.eql(u8, n, "hasvar")) {
        const k = arg(args, 0);
        return alloc.dupe(u8, if (ctx.vars.contains(k)) "true" else "false") catch null;
    }
    if (std.mem.eql(u8, n, "deletevar")) {
        const k = arg(args, 0);
        _ = ctx.vars.remove(k);
        return alloc.dupe(u8, "") catch null;
    }
    return null; // unknown macro: leave original text untouched
}

fn lowerCaseCopy(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

// World Info: select entries whose keys match scan_text (case-insensitive),
// constant entries always included, disabled excluded. Constant first.
pub fn worldInfoSelect(alloc: std.mem.Allocator, entries_json: []const u8, scan_text: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, entries_json, .{});
    var entries: []const std.json.Value = &.{};
    if (parsed.value == .array) {
        entries = parsed.value.array.items;
    } else if (parsed.value == .object) {
        if (parsed.value.object.get("entries")) |e| {
            if (e == .array) entries = e.array.items;
        }
    }
    const scan_lower = try lowerCaseCopy(alloc, scan_text);
    defer alloc.free(scan_lower);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    // Two passes: constant (0) then normal (1); disabled (2) skipped.
    for ([_]u8{ 0, 1 }) |pass| {
        for (entries) |e| {
            if (e != .object) continue;
            const disable = if (e.object.get("disable")) |v| v == .bool and v.bool else false;
            if (disable) continue;
            const constant = if (e.object.get("constant")) |v| v == .bool and v.bool else false;
            const cls: u8 = if (constant) 0 else 1;
            if (cls != pass) continue;
            const content = if (e.object.get("content")) |v| if (v == .string) v.string else "" else "";
            if (content.len == 0) continue;
            var matched = constant;
            if (!matched) {
                if (e.object.get("key")) |k| {
                    if (k == .array) {
                        for (k.array.items) |kv| {
                            if (kv != .string or kv.string.len == 0) continue;
                            const kl = try lowerCaseCopy(alloc, kv.string);
                            defer alloc.free(kl);
                            if (std.mem.indexOf(u8, scan_lower, kl) != null) {
                                matched = true;
                                break;
                            }
                        }
                    }
                }
            }
            if (!matched) continue;
            if (out.items.len > 0) try out.append(alloc, '\n');
            try out.appendSlice(alloc, content);
        }
    }
    return out.toOwnedSlice(alloc);
}

// Author's Note: insert note as a system message `depth` messages from the
// end of a messages JSON array (depth 1 = before the last message).
pub fn insertAuthorNote(alloc: std.mem.Allocator, messages_json: []const u8, note: []const u8, depth: usize) ![]u8 {
    if (note.len == 0) return alloc.dupe(u8, messages_json);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, messages_json, .{});
    if (parsed.value != .array) return alloc.dupe(u8, messages_json);
    const items = parsed.value.array.items;
    const insert_at = if (depth >= items.len) items.len else items.len - depth;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '[');
    const note_msg = try std.fmt.allocPrint(alloc, "{{\"role\":\"system\",\"content\":{s}}}", .{try quote(alloc, note)});
    defer alloc.free(note_msg);
    for (items, 0..) |m, idx| {
        if (idx == insert_at) {
            if (idx > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, note_msg);
        }
        if (idx > 0 or idx == insert_at) try out.append(alloc, ',');
        var tmp: std.Io.Writer.Allocating = .init(alloc);
        defer tmp.deinit();
        var s: std.json.Stringify = .{ .writer = &tmp.writer };
        try s.write(m);
        try out.appendSlice(alloc, tmp.written());
    }
    if (insert_at == items.len) {
        if (items.len > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, note_msg);
    }
    try out.append(alloc, ']');
    return out.toOwnedSlice(alloc);
}

fn quote(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try out.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            0x08 => try out.appendSlice(alloc, "\\b"),
            0x0c => try out.appendSlice(alloc, "\\f"),
            else => {
                if (c < 0x20) {
                    const e = try std.fmt.allocPrint(alloc, "\\u{x:0>4}", .{c});
                    defer alloc.free(e);
                    try out.appendSlice(alloc, e);
                } else try out.append(alloc, c);
            },
        }
    }
    try out.append(alloc, '"');
    return out.toOwnedSlice(alloc);
}

// Instruct template: wrap system text with system_sequence and replace
// {{name}} (upstream instruct-mode.js: system_sequence, {{name}} -> System).
pub fn applyInstructSystem(alloc: std.mem.Allocator, system_text: []const u8, preset_json: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, preset_json, .{}) catch return alloc.dupe(u8, system_text);
    if (parsed.value != .object) return alloc.dupe(u8, system_text);
    const seq = if (parsed.value.object.get("system_sequence")) |v| if (v == .string) v.string else "" else "";
    if (seq.len == 0) return alloc.dupe(u8, system_text);
    const with_name = try std.mem.replaceOwned(u8, alloc, seq, "{{name}}", "System");
    defer alloc.free(with_name);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, with_name);
    if (system_text.len > 0) {
        try out.append(alloc, '\n');
        try out.appendSlice(alloc, system_text);
    }
    return out.toOwnedSlice(alloc);
}

// World Info recursion: repeatedly scan selected content for new keys,
// up to max_steps additional rounds (upstream world_info_max_recursion_steps).
pub fn worldInfoSelectRecursive(alloc: std.mem.Allocator, entries_json: []const u8, scan_text: []const u8, max_steps: usize) ![]u8 {
    var combined = try worldInfoSelect(alloc, entries_json, scan_text);
    errdefer alloc.free(combined);
    var step: usize = 0;
    while (step < max_steps and combined.len > 0) : (step += 1) {
        const more = try worldInfoSelect(alloc, entries_json, combined);
        if (more.len == 0) {
            alloc.free(more);
            break;
        }
        // Only append entries not already present (avoid infinite loops)
        if (std.mem.indexOf(u8, combined, more) != null) {
            alloc.free(more);
            break;
        }
        const next = try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ combined, more });
        alloc.free(combined);
        alloc.free(more);
        combined = next;
    }
    return combined;
}

// Instruct chat-template rendering: render messages into a single prompt
// string using input_sequence/output_sequence/system_sequence (upstream
// instruct-mode.js). {{name}} is replaced per role (System/User/<char>).
pub fn renderInstructTemplate(alloc: std.mem.Allocator, preset_json: []const u8, messages_json: []const u8, char_name: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, preset_json, .{}) catch return alloc.dupe(u8, messages_json);
    if (parsed.value != .object) return alloc.dupe(u8, messages_json);
    const get = struct {
        fn f(obj: std.json.ObjectMap, key: []const u8) []const u8 {
            if (obj.get(key)) |v| if (v == .string) return v.string;
            return "";
        }
    }.f;
    const in_seq = get(parsed.value.object, "input_sequence");
    const out_seq = get(parsed.value.object, "output_sequence");
    const sys_seq = get(parsed.value.object, "system_sequence");
    if (in_seq.len == 0 and sys_seq.len == 0) return alloc.dupe(u8, messages_json);
    const msgs_parsed = std.json.parseFromSlice(std.json.Value, alloc, messages_json, .{}) catch return alloc.dupe(u8, messages_json);
    if (msgs_parsed.value != .array) return alloc.dupe(u8, messages_json);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (msgs_parsed.value.array.items) |m| {
        if (m != .object) continue;
        const role = get(m.object, "role");
        const content = get(m.object, "content");
        const name: []const u8 = if (std.mem.eql(u8, role, "system")) "System" else if (std.mem.eql(u8, role, "user")) "User" else char_name;
        const seq: []const u8 = if (std.mem.eql(u8, role, "system")) sys_seq else if (std.mem.eql(u8, role, "user")) in_seq else out_seq;
        const with_name = try std.mem.replaceOwned(u8, alloc, seq, "{{name}}", name);
        defer alloc.free(with_name);
        try out.appendSlice(alloc, with_name);
        try out.appendSlice(alloc, content);
        // Upstream appends the role's trailing sequence after content for
        // the last message only via last_*_sequence; simplified: newline.
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

test "macros char/user/time" {
    const alloc = std.testing.allocator;
    var vars = std.StringHashMap([]const u8).init(alloc);
    defer vars.deinit();
    var ctx = MacroCtx{ .char = "Alice", .user = "Bob", .time_str = "12:34", .date_str = "2026-11-06", .weekday_str = "Friday", .vars = vars };
    const out = try expandMacros(alloc, "{{char}} meets {{user}} at {{time}} on {{weekday}} {{date}}", &ctx);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Alice meets Bob at 12:34 on Friday 2026-11-06", out);
}

test "macros vars and unknown passthrough" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var vars = std.StringHashMap([]const u8).init(alloc);
    defer vars.deinit();
    var ctx = MacroCtx{ .vars = vars };
    const out = try expandMacros(alloc, "{{setvar::mood::brave}}{{getvar::mood}} {{incvar::n}}{{incvar::n}}{{getvar::n}} {{unknownmacro}}", &ctx);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("brave 2 {{unknownmacro}}", out);
}

test "macros random/pick/roll" {
    const alloc = std.testing.allocator;
    var vars = std.StringHashMap([]const u8).init(alloc);
    defer vars.deinit();
    var ctx = MacroCtx{ .vars = vars };
    const p = try expandMacros(alloc, "{{pick::a::b::c}}", &ctx);
    defer alloc.free(p);
    try std.testing.expectEqualStrings("a", p);
    const r = try expandMacros(alloc, "{{roll::1}}", &ctx);
    defer alloc.free(r);
    try std.testing.expectEqualStrings("1", r);
    const s = try expandMacros(alloc, "x{{space}}y{{newline}}z{{noop}}w", &ctx);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("x y\nzw", s);
}

test "worldinfo constant and key match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = "[{\"key\":[\"tavern\"],\"content\":\"A cozy tavern.\",\"disable\":false,\"constant\":false},{\"key\":[],\"content\":\"Always here.\",\"disable\":false,\"constant\":true},{\"key\":[\"dragon\"],\"content\":\"A dragon.\",\"disable\":false,\"constant\":false},{\"key\":[\"tavern\"],\"content\":\"Disabled.\",\"disable\":true,\"constant\":false}]";
    const out = try worldInfoSelect(alloc, entries, "We enter the TAVERN");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Always here.\nA cozy tavern.", out);
}

test "author note depth insertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const msgs = "[{\"role\":\"system\",\"content\":\"s\"},{\"role\":\"user\",\"content\":\"u\"}]";
    const out = try insertAuthorNote(alloc, msgs, "NOTE", 1);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("[{\"role\":\"system\",\"content\":\"s\"},{\"role\":\"system\",\"content\":\"NOTE\"},{\"role\":\"user\",\"content\":\"u\"}]", out);
    const out0 = try insertAuthorNote(alloc, msgs, "", 1);
    defer alloc.free(out0);
    try std.testing.expectEqualStrings(msgs, out0);
}

test "instruct system sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const preset = "{\"system_sequence\":\"You are {{name}}.\",\"input_sequence\":\">>>\",\"output_sequence\":\"<<<\"}";
    const out = try applyInstructSystem(alloc, "Card prompt.", preset);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("You are System.\nCard prompt.", out);
}

test "worldinfo recursion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = "[{\"key\":[\"tavern\"],\"content\":\"Mentions the dragon.\",\"disable\":false,\"constant\":false},{\"key\":[\"dragon\"],\"content\":\"Dragon lore.\",\"disable\":false,\"constant\":false}]";
    const out = try worldInfoSelectRecursive(alloc, entries, "tavern", 2);
    try std.testing.expect(std.mem.indexOf(u8, out, "Dragon lore.") != null);
    const no_rec = try worldInfoSelectRecursive(alloc, entries, "tavern", 0);
    try std.testing.expect(std.mem.indexOf(u8, no_rec, "Dragon lore.") == null);
}

test "instruct template rendering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const preset = "{\"system_sequence\":\"SYS {{name}}: \",\"input_sequence\":\"USER {{name}}: \",\"output_sequence\":\"CHAR {{name}}: \"}";
    const msgs = "[{\"role\":\"system\",\"content\":\"card\"},{\"role\":\"user\",\"content\":\"hi\"},{\"role\":\"assistant\",\"content\":\"hello\"}]";
    const out = try renderInstructTemplate(alloc, preset, msgs, "Alice");
    try std.testing.expectEqualStrings("SYS System: card\nUSER User: hi\nCHAR Alice: hello\n", out);
}
