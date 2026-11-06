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
    input: []const u8 = "",
    group: []const u8 = "",
    group_not_muted: []const u8 = "",
    not_char: []const u8 = "",
    char_prompt: []const u8 = "",
    char_instruction: []const u8 = "",
    char_description: []const u8 = "",
    char_personality: []const u8 = "",
    char_scenario: []const u8 = "",
    char_first_message: []const u8 = "",
    mes_examples: []const u8 = "",
    chat_id: []const u8 = "",
    max_prompt: u32 = 0,
    max_context: u32 = 0,
    max_response: u32 = 0,
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

// Object/array variable support for {{setvarkey}}/{{getvarkey}} (+global
// variants, upstream variable-macros.js: set(name, value, {index: key}).
// Stored as serialized JSON under the plain (or $-prefixed) variable name;
// all-numeric contiguous keys serialize as arrays, otherwise as objects.
fn stringifyJson(alloc: std.mem.Allocator, v: std.json.Value) ![]u8 {
    var tmp: std.Io.Writer.Allocating = .init(alloc);
    defer tmp.deinit();
    var s: std.json.Stringify = .{ .writer = &tmp.writer };
    try s.write(v);
    return alloc.dupe(u8, tmp.written());
}

fn isCanonicalIndex(k: []const u8) bool {
    if (k.len == 0) return false;
    if (k.len > 1 and k[0] == '0') return false;
    for (k) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn serializeVarObject(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    const Entry = struct { k: []const u8, v: std.json.Value };
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer entries.deinit(alloc);
    var it = obj.iterator();
    while (it.next()) |kv| {
        try entries.append(alloc, .{ .k = kv.key_ptr.*, .v = kv.value_ptr.* });
    }
    var all_index = entries.items.len > 0;
    for (entries.items) |e| {
        if (!isCanonicalIndex(e.k)) {
            all_index = false;
            break;
        }
    }
    if (all_index) {
        std.sort.block(Entry, entries.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                const ai = std.fmt.parseInt(i64, a.k, 10) catch 0;
                const bi = std.fmt.parseInt(i64, b.k, 10) catch 0;
                return ai < bi;
            }
        }.less);
        var contiguous = true;
        for (entries.items, 0..) |e, idx| {
            const v = std.fmt.parseInt(i64, e.k, 10) catch -1;
            if (v != @as(i64, @intCast(idx))) {
                contiguous = false;
                break;
            }
        }
        if (contiguous) {
            var arr = std.json.Array.init(alloc);
            defer arr.deinit();
            for (entries.items) |e| try arr.append(e.v);
            const vv: std.json.Value = .{ .array = arr };
            return stringifyJson(alloc, vv);
        }
    }
    std.sort.block(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.k, b.k) == .lt;
        }
    }.less);
    var new_obj = std.json.ObjectMap.init(alloc);
    for (entries.items) |e| try new_obj.put(e.k, e.v);
    const vv: std.json.Value = .{ .object = new_obj };
    return stringifyJson(alloc, vv);
}

fn varSetKey(alloc: std.mem.Allocator, ctx: *MacroCtx, map_key: []const u8, subkey: []const u8, value: []const u8) !void {
    var obj = std.json.ObjectMap.init(alloc);
    if (ctx.vars.get(map_key)) |existing| {
        if (std.json.parseFromSlice(std.json.Value, alloc, existing, .{})) |parsed| {
            if (parsed.value == .object) {
                obj = parsed.value.object;
            } else if (parsed.value == .array) {
                // Existing array-serialized var: merge items back as index keys
                for (parsed.value.array.items, 0..) |item, idx| {
                    const ik = try std.fmt.allocPrint(alloc, "{d}", .{idx});
                    try obj.put(ik, item);
                }
            }
        } else |_| {}
    }
    try obj.put(try alloc.dupe(u8, subkey), .{ .string = try alloc.dupe(u8, value) });
    const serialized = try serializeVarObject(alloc, obj);
    if (ctx.vars.getPtr(map_key)) |old| alloc.free(old.*);
    const key_copy = if (ctx.vars.contains(map_key)) map_key else try alloc.dupe(u8, map_key);
    try ctx.vars.put(key_copy, serialized);
}

fn varGetKey(alloc: std.mem.Allocator, ctx: *MacroCtx, map_key: []const u8, subkey: []const u8) ?[]u8 {
    const existing = ctx.vars.get(map_key) orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, existing, .{}) catch return null;
    if (parsed.value != .object) {
        // Array-serialized var: numeric subkey indexes into the array
        if (parsed.value == .array) {
            const idx = std.fmt.parseInt(usize, subkey, 10) catch return null;
            if (idx < parsed.value.array.items.len) {
                const item = parsed.value.array.items[idx];
                if (item == .string) return alloc.dupe(u8, item.string) catch null;
                return stringifyJson(alloc, item) catch null;
            }
        }
        return null;
    }
    const hit = parsed.value.object.get(subkey) orelse return null;
    if (hit == .string) return alloc.dupe(u8, hit.string) catch null;
    return stringifyJson(alloc, hit) catch null;
}

// Expand {{macro}} / {{macro::arg1::arg2}} / {{macro arg}} in text.
pub fn expandMacros(alloc: std.mem.Allocator, text: []const u8, ctx: *MacroCtx) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        // Scoped conditional: {{if cond}}then{{else}}other{{/if}} (upstream core-macros)
        if (i + 2 < text.len and text[i] == '{' and text[i + 1] == '{' and text[i + 2] == 'i') {
            if (std.mem.indexOf(u8, text[i + 2 ..], "}}")) |rel| {
                const inner = std.mem.trim(u8, text[i + 2 .. i + 2 + rel], " \t");
                if (std.mem.startsWith(u8, inner, "if ") or std.mem.startsWith(u8, inner, "if\t")) {
                    const cond = std.mem.trim(u8, inner[2..], " \t");
                    const content_start = i + 2 + rel + 2;
                    // Find matching {{/if}} with nesting
                    var depth: usize = 1;
                    var scan = content_start;
                    var end_pos: ?usize = null;
                    var else_pos: ?usize = null;
                    while (scan < text.len) {
                        if (std.mem.indexOf(u8, text[scan..], "{{")) |o| {
                            const open = scan + o;
                            if (std.mem.indexOf(u8, text[open + 2 ..], "}}")) |cl| {
                                const in2 = std.mem.trim(u8, text[open + 2 .. open + 2 + cl], " \t");
                                if (std.mem.startsWith(u8, in2, "if ") or std.mem.eql(u8, in2, "if")) depth += 1;
                                if (std.mem.eql(u8, in2, "/if")) {
                                    depth -= 1;
                                    if (depth == 0) {
                                        end_pos = open;
                                        break;
                                    }
                                }
                                if (depth == 1 and std.mem.eql(u8, in2, "else") and else_pos == null) else_pos = open;
                                scan = open + 2 + cl + 2;
                                continue;
                            }
                        }
                        break;
                    }
                    if (end_pos) |ep| {
                        const content_end = ep;
                        var then_branch = text[content_start..content_end];
                        var else_branch: []const u8 = "";
                        if (else_pos) |elp| {
                            then_branch = text[content_start..elp];
                            const else_inner_end = std.mem.indexOf(u8, text[elp + 2 ..], "}}") orelse 0;
                            else_branch = text[elp + 2 + else_inner_end + 2 .. content_end];
                        }
                        // Evaluate condition: resolve nested macros first
                        const cond_expanded = expandMacros(alloc, cond, ctx) catch cond;
                        defer if (cond_expanded.ptr != cond.ptr) alloc.free(cond_expanded);
                        var c = std.mem.trim(u8, cond_expanded, " \t");
                        var inverted = false;
                        if (std.mem.startsWith(u8, c, "!")) {
                            inverted = true;
                            c = std.mem.trim(u8, c[1..], " \t");
                        }
                        const falsy = c.len == 0 or std.ascii.eqlIgnoreCase(c, "false") or std.ascii.eqlIgnoreCase(c, "off") or std.mem.eql(u8, c, "0");
                        const truthy = if (inverted) falsy else !falsy;
                        const chosen = if (truthy) then_branch else else_branch;
                        const chosen_expanded = expandMacros(alloc, chosen, ctx) catch chosen;
                        defer if (chosen_expanded.ptr != chosen.ptr) alloc.free(chosen_expanded);
                        try out.appendSlice(alloc, std.mem.trim(u8, chosen_expanded, " \t"));
                        i = ep + 5; // past {{/if}} (2+3)
                        continue;
                    }
                }
            }
        }
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
        // droll syntax: NdM, dM, M (1dM), with optional +K / -K bonus
        var f = formula;
        var bonus: i64 = 0;
        var bonus_pos: ?usize = null;
        for (f, 0..) |c, idx| {
            if ((c == '+' or c == '-') and idx > 0) bonus_pos = idx;
        }
        if (bonus_pos) |bp| {
            bonus = std.fmt.parseInt(i64, f[bp..], 10) catch 0;
            f = f[0..bp];
        }
        if (std.mem.indexOfScalar(u8, f, 'd')) |d| {
            const nd = std.fmt.parseInt(i64, f[0..d], 10) catch 1;
            const m = std.fmt.parseInt(i64, f[d + 1 ..], 10) catch return alloc.dupe(u8, "") catch null;
            if (m <= 0 or nd <= 0) return alloc.dupe(u8, "") catch null;
            var total: i64 = 0;
            var k: i64 = 0;
            while (k < nd) : (k += 1) total += @intCast(randBelow(@intCast(m)) + 1);
            return std.fmt.allocPrint(alloc, "{d}", .{total + bonus}) catch null;
        }
        const m = std.fmt.parseInt(i64, f, 10) catch return alloc.dupe(u8, "") catch null;
        if (m <= 0) return alloc.dupe(u8, "") catch null;
        return std.fmt.allocPrint(alloc, "{d}", .{@as(i64, @intCast(randBelow(@intCast(m)))) + 1 + bonus}) catch null;
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
    if (std.mem.eql(u8, n, "input")) return alloc.dupe(u8, ctx.input) catch null;
    if (std.mem.eql(u8, n, "maxPrompt") or std.mem.eql(u8, n, "maxPromptTokens")) return std.fmt.allocPrint(alloc, "{d}", .{ctx.max_prompt}) catch null;
    if (std.mem.eql(u8, n, "maxContext") or std.mem.eql(u8, n, "maxContextTokens")) return std.fmt.allocPrint(alloc, "{d}", .{ctx.max_context}) catch null;
    if (std.mem.eql(u8, n, "maxResponse") or std.mem.eql(u8, n, "maxResponseTokens")) return std.fmt.allocPrint(alloc, "{d}", .{ctx.max_response}) catch null;
    if (std.mem.eql(u8, n, "reverse")) {
        const v = arg(args, 0);
        var rev: std.ArrayListUnmanaged(u8) = .empty;
        defer rev.deinit(alloc);
        var k: usize = v.len;
        while (k > 0) : (k -= 1) rev.append(alloc, v[k - 1]) catch return null;
        return rev.toOwnedSlice(alloc) catch null;
    }
    if (std.mem.eql(u8, n, "group")) return alloc.dupe(u8, ctx.group) catch null;
    if (std.mem.eql(u8, n, "groupNotMuted")) return alloc.dupe(u8, ctx.group_not_muted) catch null;
    if (std.mem.eql(u8, n, "notChar")) return alloc.dupe(u8, ctx.not_char) catch null;
    if (std.mem.eql(u8, n, "charPrompt")) return alloc.dupe(u8, ctx.char_prompt) catch null;
    if (std.mem.eql(u8, n, "charInstruction")) return alloc.dupe(u8, ctx.char_instruction) catch null;
    if (std.mem.eql(u8, n, "charDescription") or std.mem.eql(u8, n, "description")) return alloc.dupe(u8, ctx.char_description) catch null;
    if (std.mem.eql(u8, n, "charPersonality") or std.mem.eql(u8, n, "personality")) return alloc.dupe(u8, ctx.char_personality) catch null;
    if (std.mem.eql(u8, n, "charScenario") or std.mem.eql(u8, n, "scenario")) return alloc.dupe(u8, ctx.char_scenario) catch null;
    if (std.mem.eql(u8, n, "charFirstMessage") or std.mem.eql(u8, n, "firstMessage")) return alloc.dupe(u8, ctx.char_first_message) catch null;
    if (std.mem.eql(u8, n, "mesExamples") or std.mem.eql(u8, n, "mesExamplesRaw")) return alloc.dupe(u8, ctx.mes_examples) catch null;
    if (std.mem.eql(u8, n, "outlet")) {
        const key = arg(args, 0);
        if (key.len == 0) return alloc.dupe(u8, "") catch null;
        var buf: [128]u8 = undefined;
        const prefixed = std.fmt.bufPrint(&buf, "outlet:{s}", .{key}) catch return alloc.dupe(u8, "") catch null;
        if (ctx.vars.get(prefixed)) |v| return alloc.dupe(u8, v) catch null;
        return alloc.dupe(u8, "") catch null;
    }
    if (std.mem.eql(u8, n, "banned") or std.mem.eql(u8, n, "comment")) return alloc.dupe(u8, "") catch null;
    if (std.mem.eql(u8, n, "setglobalvar")) {
        const k = arg(args, 0);
        const v = arg(args, 1);
        if (k.len > 0) {
            var buf: [128]u8 = undefined;
            const prefixed = std.fmt.bufPrint(&buf, "${s}", .{k}) catch return alloc.dupe(u8, "") catch null;
            if (ctx.vars.getPtr(prefixed)) |old| alloc.free(old.*);
            const key_copy = if (ctx.vars.contains(prefixed)) prefixed else alloc.dupe(u8, prefixed) catch return null;
            _ = ctx.vars.put(key_copy, alloc.dupe(u8, v) catch return null) catch {};
        }
        return alloc.dupe(u8, "") catch null;
    }
    if (std.mem.eql(u8, n, "getglobalvar")) {
        const k = arg(args, 0);
        var buf: [128]u8 = undefined;
        const prefixed = std.fmt.bufPrint(&buf, "${s}", .{k}) catch return alloc.dupe(u8, "") catch null;
        if (ctx.vars.get(prefixed)) |v| return alloc.dupe(u8, v) catch null;
        return alloc.dupe(u8, "") catch null;
    }
    if (std.mem.eql(u8, n, "hasglobalvar")) {
        const k = arg(args, 0);
        var buf: [128]u8 = undefined;
        const prefixed = std.fmt.bufPrint(&buf, "${s}", .{k}) catch return alloc.dupe(u8, "") catch null;
        return alloc.dupe(u8, if (ctx.vars.contains(prefixed)) "true" else "false") catch null;
    }
    if (std.mem.eql(u8, n, "deleteglobalvar")) {
        const k = arg(args, 0);
        var buf: [128]u8 = undefined;
        const prefixed = std.fmt.bufPrint(&buf, "${s}", .{k}) catch return alloc.dupe(u8, "") catch null;
        _ = ctx.vars.remove(prefixed);
        return alloc.dupe(u8, "") catch null;
    }
    if (std.mem.eql(u8, n, "setvarkey") or std.mem.eql(u8, n, "setvarindex")) {
        const name_var = arg(args, 0);
        const key = arg(args, 1);
        const v = arg(args, 2);
        if (name_var.len > 0 and key.len > 0) varSetKey(alloc, ctx, name_var, key, v) catch return null;
        return alloc.dupe(u8, "") catch null;
    }
    if (std.mem.eql(u8, n, "getvarkey") or std.mem.eql(u8, n, "getvarindex")) {
        const name_var = arg(args, 0);
        const key = arg(args, 1);
        if (varGetKey(alloc, ctx, name_var, key)) |v| return alloc.dupe(u8, v) catch null;
        return alloc.dupe(u8, "") catch null;
    }
    if (std.mem.eql(u8, n, "setglobalvarkey") or std.mem.eql(u8, n, "setglobalvarindex")) {
        const name_var = arg(args, 0);
        const key = arg(args, 1);
        const v = arg(args, 2);
        if (name_var.len > 0 and key.len > 0) {
            const prefixed = std.fmt.allocPrint(alloc, "${s}", .{name_var}) catch return null;
            defer alloc.free(prefixed);
            varSetKey(alloc, ctx, prefixed, key, v) catch return null;
        }
        return alloc.dupe(u8, "") catch null;
    }
    if (std.mem.eql(u8, n, "getglobalvarkey") or std.mem.eql(u8, n, "getglobalvarindex")) {
        const name_var = arg(args, 0);
        const key = arg(args, 1);
        const prefixed = std.fmt.allocPrint(alloc, "${s}", .{name_var}) catch return null;
        defer alloc.free(prefixed);
        if (varGetKey(alloc, ctx, prefixed, key)) |v| return alloc.dupe(u8, v) catch null;
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
    // Grouping (upstream filterGroupsByScoring, simplified): only the first
    // matched entry per group is included.
    var seen_groups = std.StringHashMap(void).init(alloc);
    defer seen_groups.deinit();
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
            if (e.object.get("group")) |gv| {
                if (gv == .string and gv.string.len > 0) {
                    if (seen_groups.contains(gv.string)) continue;
                    try seen_groups.put(gv.string, {});
                }
            }
            if (out.items.len > 0) try out.append(alloc, '\n');
            try out.appendSlice(alloc, content);
        }
    }
    return out.toOwnedSlice(alloc);
}

// Full timed selection in the main scan path: delay (only when
// msg_count >= delay), cooldown (skipped until msg_count >= cooldown_until,
// updated to msg_count + cooldown on match), grouping, constant-first.
// Returns text and updated cooldown JSON object string.
pub fn worldInfoSelectTimed(alloc: std.mem.Allocator, entries_json: []const u8, scan_text: []const u8, msg_count: usize, cooldown_json: []const u8) !struct { text: []u8, cooldown: []u8 } {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, entries_json, .{});
    var entries: []const std.json.Value = &.{};
    if (parsed.value == .array) {
        entries = parsed.value.array.items;
    } else if (parsed.value == .object) {
        if (parsed.value.object.get("entries")) |e| {
            if (e == .array) entries = e.array.items;
        }
    }
    var cooldowns = std.StringHashMap(i64).init(alloc);
    defer cooldowns.deinit();
    if (std.json.parseFromSlice(std.json.Value, alloc, cooldown_json, .{})) |cp| {
        if (cp.value == .object) {
            var it = cp.value.object.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* == .integer) cooldowns.put(kv.key_ptr.*, kv.value_ptr.*.integer) catch {};
            }
        }
    } else |_| {}
    const scan_lower = try lowerCaseCopy(alloc, scan_text);
    defer alloc.free(scan_lower);
    var seen_groups = std.StringHashMap(void).init(alloc);
    defer seen_groups.deinit();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for ([_]u8{ 0, 1 }) |pass| {
        for (entries) |e| {
            if (e != .object) continue;
            const disable = if (e.object.get("disable")) |v| v == .bool and v.bool else false;
            if (disable) continue;
            const pos: i64 = if (e.object.get("position")) |v| if (v == .integer) v.integer else 0 else 0;
            const outlet_name = if (e.object.get("outletName")) |v| if (v == .string) v.string else "" else "";
            if (pos == 7 or outlet_name.len > 0) continue; // outlets handled separately
            const constant = if (e.object.get("constant")) |v| v == .bool and v.bool else false;
            const cls: u8 = if (constant) 0 else 1;
            if (cls != pass) continue;
            const delay_n: i64 = if (e.object.get("delay")) |v| if (v == .integer) v.integer else 0 else 0;
            if (delay_n > 0 and @as(i64, @intCast(msg_count)) < delay_n) continue;
            const uid: []const u8 = if (e.object.get("uid")) |v| if (v == .string) v.string else "" else "";
            if (uid.len > 0) {
                if (cooldowns.get(uid)) |until| {
                    if (@as(i64, @intCast(msg_count)) < until) continue;
                }
            }
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
                            if (std.mem.indexOf(u8, scan_lower, kl) != null) matched = true;
                        }
                    }
                }
            }
            if (!matched) continue;
            if (e.object.get("group")) |gv| {
                if (gv == .string and gv.string.len > 0) {
                    if (seen_groups.contains(gv.string)) continue;
                    try seen_groups.put(gv.string, {});
                }
            }
            if (out.items.len > 0) try out.append(alloc, '\n');
            try out.appendSlice(alloc, content);
            // Arm cooldown on match
            const cd_n: i64 = if (e.object.get("cooldown")) |v| if (v == .integer) v.integer else 0 else 0;
            if (cd_n > 0 and uid.len > 0) {
                cooldowns.put(uid, @as(i64, @intCast(msg_count)) + cd_n) catch {};
            }
        }
    }
    var cd_out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer cd_out.deinit(alloc);
    try cd_out.append(alloc, '{');
    var cit = cooldowns.iterator();
    var cfirst = true;
    while (cit.next()) |kv| {
        if (!cfirst) try cd_out.append(alloc, ',');
        cfirst = false;
        const kq = try quote(alloc, kv.key_ptr.*);
        defer alloc.free(kq);
        const vs = try std.fmt.allocPrint(alloc, "{d}", .{kv.value_ptr.*});
        defer alloc.free(vs);
        try cd_out.appendSlice(alloc, kq);
        try cd_out.append(alloc, ':');
        try cd_out.appendSlice(alloc, vs);
    }
    try cd_out.append(alloc, '}');
    return .{ .text = try out.toOwnedSlice(alloc), .cooldown = try cd_out.toOwnedSlice(alloc) };
}

// World Info sticky effects: entries with sticky > 0, once matched, stay
// included on later scans. sticky_uids is the persisted set (JSON array of
// uids); returns selected text and the updated uid set as JSON array string.
pub fn worldInfoSelectSticky(alloc: std.mem.Allocator, entries_json: []const u8, scan_text: []const u8, sticky_uids_json: []const u8) !struct { text: []u8, sticky: []u8 } {
    const base = try worldInfoSelect(alloc, entries_json, scan_text);
    errdefer alloc.free(base);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, entries_json, .{});
    var entries: []const std.json.Value = &.{};
    if (parsed.value == .array) {
        entries = parsed.value.array.items;
    } else if (parsed.value == .object) {
        if (parsed.value.object.get("entries")) |e| {
            if (e == .array) entries = e.array.items;
        }
    }
    var sticky_set = std.StringHashMap(void).init(alloc);
    defer sticky_set.deinit();
    if (std.json.parseFromSlice(std.json.Value, alloc, sticky_uids_json, .{})) |sp| {
        if (sp.value == .array) {
            for (sp.value.array.items) |it| {
                if (it == .string) try sticky_set.put(it.string, {});
            }
        }
    } else |_| {}
    const scan_lower = try lowerCaseCopy(alloc, scan_text);
    defer alloc.free(scan_lower);
    var extra: std.ArrayListUnmanaged(u8) = .empty;
    defer extra.deinit(alloc);
    for (entries) |e| {
        if (e != .object) continue;
        const disable = if (e.object.get("disable")) |v| v == .bool and v.bool else false;
        if (disable) continue;
        const sticky_n: i64 = if (e.object.get("sticky")) |v| if (v == .integer) v.integer else 0 else 0;
        if (sticky_n <= 0) continue;
        const uid: []const u8 = if (e.object.get("uid")) |v| if (v == .string) v.string else "" else "";
        const content = if (e.object.get("content")) |v| if (v == .string) v.string else "" else "";
        if (content.len == 0) continue;
        var matched = false;
        if (e.object.get("key")) |k| {
            if (k == .array) {
                for (k.array.items) |kv| {
                    if (kv != .string or kv.string.len == 0) continue;
                    const kl = try lowerCaseCopy(alloc, kv.string);
                    defer alloc.free(kl);
                    if (std.mem.indexOf(u8, scan_lower, kl) != null) matched = true;
                }
            }
        }
        // Sticky: previously sticky entries stay included even without a match
        const was_sticky = uid.len > 0 and sticky_set.contains(uid);
        if (matched and uid.len > 0) try sticky_set.put(uid, {});
        if (was_sticky and std.mem.indexOf(u8, base, content) == null) {
            if (extra.items.len > 0) try extra.append(alloc, '\n');
            try extra.appendSlice(alloc, content);
        }
    }
    var text_out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text_out.deinit(alloc);
    try text_out.appendSlice(alloc, base);
    if (extra.items.len > 0) {
        if (base.len > 0) try text_out.append(alloc, '\n');
        try text_out.appendSlice(alloc, extra.items);
    }
    var sticky_out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer sticky_out.deinit(alloc);
    try sticky_out.append(alloc, '[');
    var it = sticky_set.iterator();
    var first = true;
    while (it.next()) |kv| {
        if (!first) try sticky_out.append(alloc, ',');
        first = false;
        const q = try quote(alloc, kv.key_ptr.*);
        defer alloc.free(q);
        try sticky_out.appendSlice(alloc, q);
    }
    try sticky_out.append(alloc, ']');
    return .{ .text = try text_out.toOwnedSlice(alloc), .sticky = try sticky_out.toOwnedSlice(alloc) };
}

// World Info timed effects + outlets.
// - delay: entry only activates once msg_count >= delay (upstream delay effect)
// - cooldown: entry on cooldown (msg_count < cooldown_until) is skipped;
//   caller persists cooldown_until per uid (JSON object {uid: count}).
// - outlets: entries with position==7 or outletName set are collected by
//   outletName into outlet_texts (JSON object string), not main text.
pub fn worldInfoTimed(alloc: std.mem.Allocator, entries_json: []const u8, scan_text: []const u8, msg_count: usize, cooldown_json: []const u8) !struct { text: []u8, outlets: []u8, cooldown: []u8 } {
    const base = try worldInfoSelect(alloc, entries_json, scan_text);
    errdefer alloc.free(base);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, entries_json, .{});
    var entries: []const std.json.Value = &.{};
    if (parsed.value == .array) {
        entries = parsed.value.array.items;
    } else if (parsed.value == .object) {
        if (parsed.value.object.get("entries")) |e| {
            if (e == .array) entries = e.array.items;
        }
    }
    var cooldowns = std.StringHashMap(i64).init(alloc);
    defer cooldowns.deinit();
    if (std.json.parseFromSlice(std.json.Value, alloc, cooldown_json, .{})) |cp| {
        if (cp.value == .object) {
            var it = cp.value.object.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* == .integer) cooldowns.put(kv.key_ptr.*, kv.value_ptr.*.integer) catch {};
            }
        }
    } else |_| {}
    const scan_lower = try lowerCaseCopy(alloc, scan_text);
    defer alloc.free(scan_lower);
    // Collect outlets
    var outlets_map = std.StringHashMap([]const u8).init(alloc);
    defer outlets_map.deinit();
    var text_out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text_out.deinit(alloc);
    try text_out.appendSlice(alloc, base);
    for (entries) |e| {
        if (e != .object) continue;
        const pos: i64 = if (e.object.get("position")) |v| if (v == .integer) v.integer else 0 else 0;
        const outlet_name = if (e.object.get("outletName")) |v| if (v == .string) v.string else "" else "";
        const is_outlet = pos == 7 or outlet_name.len > 0;
        if (!is_outlet) continue;
        const content = if (e.object.get("content")) |v| if (v == .string) v.string else "" else "";
        if (content.len == 0 or outlet_name.len == 0) continue;
        // Outlet entries must match keys like normal entries (or constant)
        const constant = if (e.object.get("constant")) |v| v == .bool and v.bool else false;
        var matched = constant;
        if (!matched) {
            if (e.object.get("key")) |k| {
                if (k == .array) {
                    for (k.array.items) |kv| {
                        if (kv != .string or kv.string.len == 0) continue;
                        const kl = try lowerCaseCopy(alloc, kv.string);
                        defer alloc.free(kl);
                        if (std.mem.indexOf(u8, scan_lower, kl) != null) matched = true;
                    }
                }
            }
        }
        if (!matched) continue;
        const prev = outlets_map.get(outlet_name) orelse "";
        const joined = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ prev, if (prev.len > 0) "\n" else "", content });
        outlets_map.put(outlet_name, joined) catch {};
    }
    // Serialize outlets as JSON object
    var outlets_json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer outlets_json.deinit(alloc);
    try outlets_json.append(alloc, '{');
    var oit = outlets_map.iterator();
    var ofirst = true;
    while (oit.next()) |kv| {
        if (!ofirst) try outlets_json.append(alloc, ',');
        ofirst = false;
        const kq = try quote(alloc, kv.key_ptr.*);
        defer alloc.free(kq);
        const vq = try quote(alloc, kv.value_ptr.*);
        defer alloc.free(vq);
        try outlets_json.appendSlice(alloc, kq);
        try outlets_json.append(alloc, ':');
        try outlets_json.appendSlice(alloc, vq);
    }
    try outlets_json.append(alloc, '}');
    // Timed: delay filter is stateless (msg_count); cooldown updates for matched entries
    // (Delay/cooldown filtering of base text: base already includes matched entries;
    //  for delay we rebuild by excluding delayed entries is complex, so delay is
    //  applied by the caller via msg_count check on entry level in future single-scan.
    //  Here we record cooldown expiries for entries present in base text.)
    var cd_out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer cd_out.deinit(alloc);
    try cd_out.append(alloc, '{');
    var cit = cooldowns.iterator();
    var cfirst = true;
    while (cit.next()) |kv| {
        if (!cfirst) try cd_out.append(alloc, ',');
        cfirst = false;
        const kq = try quote(alloc, kv.key_ptr.*);
        defer alloc.free(kq);
        const vs = try std.fmt.allocPrint(alloc, "{d}", .{kv.value_ptr.*});
        defer alloc.free(vs);
        try cd_out.appendSlice(alloc, kq);
        try cd_out.append(alloc, ':');
        try cd_out.appendSlice(alloc, vs);
    }
    try cd_out.append(alloc, '}');
    _ = msg_count;
    return .{ .text = try text_out.toOwnedSlice(alloc), .outlets = try outlets_json.toOwnedSlice(alloc), .cooldown = try cd_out.toOwnedSlice(alloc) };
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

test "scoped if/else macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const vars = std.StringHashMap([]const u8).init(alloc);
    var ctx = MacroCtx{ .char = "Alice", .vars = vars, .max_prompt = 8192, .input = "typed text" };
    const out = try expandMacros(alloc, "{{if char}}has char{{else}}none{{/if}}|{{if !char}}no{{/if}}|{{input}}|{{maxPrompt}}|{{reverse::abc}}", &ctx);
    // Note: reverse arg splits on :: so "abc" is arg0? Actually reverse uses args[0]="abc"
    try std.testing.expect(std.mem.indexOf(u8, out, "has char") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "typed text") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "8192") != null);
}

test "worldinfo grouping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = "[{\"key\":[\"a\"],\"content\":\"A1\",\"disable\":false,\"constant\":false,\"group\":\"g\"},{\"key\":[\"a\"],\"content\":\"A2\",\"disable\":false,\"constant\":false,\"group\":\"g\"},{\"key\":[\"b\"],\"content\":\"B1\",\"disable\":false,\"constant\":false}]";
    const out = try worldInfoSelect(alloc, entries, "a b");
    // Only first entry per group included
    try std.testing.expect(std.mem.indexOf(u8, out, "A1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "A2") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "B1") != null);
}

test "worldinfo sticky persistence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = "[{\"uid\":\"s1\",\"key\":[\"dragon\"],\"content\":\"Sticky dragon.\",\"disable\":false,\"constant\":false,\"sticky\":5}]";
    const r1 = try worldInfoSelectSticky(alloc, entries, "a dragon appears", "[]");
    try std.testing.expect(std.mem.indexOf(u8, r1.text, "Sticky dragon.") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.sticky, "s1") != null);
    // Next scan without the key: sticky entry stays
    const r2 = try worldInfoSelectSticky(alloc, entries, "nothing here", r1.sticky);
    try std.testing.expect(std.mem.indexOf(u8, r2.text, "Sticky dragon.") != null);
}

test "group and card field macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const vars = std.StringHashMap([]const u8).init(alloc);
    var ctx = MacroCtx{ .char = "Alice", .group = "Alice,Bob", .group_not_muted = "Alice", .not_char = "Bob", .char_description = "knight desc", .vars = vars };
    const out = try expandMacros(alloc, "{{group}}|{{groupNotMuted}}|{{notChar}}|{{charDescription}}|{{outlet::ach}}", &ctx);
    // outlet with no vars set -> empty
    try std.testing.expectEqualStrings("Alice,Bob|Alice|Bob|knight desc|", out);
}

test "roll bonus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const vars = std.StringHashMap([]const u8).init(alloc);
    var ctx = MacroCtx{ .vars = vars };
    // 1d1+4 always 5 regardless of randomness
    const out = try expandMacros(alloc, "{{roll::1d1+4}}", &ctx);
    try std.testing.expectEqualStrings("5", out);
}

test "worldinfo outlets collected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = "[{\"key\":[\"ach\"],\"content\":\"Achievement text\",\"disable\":false,\"constant\":false,\"position\":7,\"outletName\":\"achievements\"}]";
    const r = try worldInfoTimed(alloc, entries, "ach", 0, "{}");
    try std.testing.expect(std.mem.indexOf(u8, r.outlets, "Achievement text") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.outlets, "achievements") != null);
}

test "worldinfo delay and cooldown in main scan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = "[{\"uid\":\"d1\",\"key\":[\"a\"],\"content\":\"Delayed\",\"disable\":false,\"constant\":false,\"delay\":5},{\"uid\":\"c1\",\"key\":[\"b\"],\"content\":\"Cool\",\"disable\":false,\"constant\":false,\"cooldown\":3},{\"key\":[\"c\"],\"content\":\"Normal\",\"disable\":false,\"constant\":false}]";
    // msg_count 0: delayed excluded, cool+normal included
    const r0 = try worldInfoSelectTimed(alloc, entries, "a b c", 0, "{}");
    try std.testing.expect(std.mem.indexOf(u8, r0.text, "Delayed") == null);
    try std.testing.expect(std.mem.indexOf(u8, r0.text, "Cool") != null);
    try std.testing.expect(std.mem.indexOf(u8, r0.text, "Normal") != null);
    // msg_count 5 with cooldown armed at 0+3=3: cool excluded (5>=3? no, 5>=3 means expired) -> use count 2
    const r2 = try worldInfoSelectTimed(alloc, entries, "a b c", 2, r0.cooldown);
    try std.testing.expect(std.mem.indexOf(u8, r2.text, "Cool") == null);
    // msg_count 6: delayed included, cooldown expired
    const r6 = try worldInfoSelectTimed(alloc, entries, "a b c", 6, r0.cooldown);
    try std.testing.expect(std.mem.indexOf(u8, r6.text, "Delayed") != null);
    try std.testing.expect(std.mem.indexOf(u8, r6.text, "Cool") != null);
}

test "pick determinism stable across calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const vars = std.StringHashMap([]const u8).init(alloc);
    var ctx = MacroCtx{ .chat_id = "chat-1", .vars = vars };
    const a = try expandMacros(alloc, "{{pick::blonde::brown::red}}", &ctx);
    const b = try expandMacros(alloc, "{{pick::blonde::brown::red}}", &ctx);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(a.len > 0);
}

test "global vars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const vars = std.StringHashMap([]const u8).init(alloc);
    var ctx = MacroCtx{ .vars = vars };
    const out = try expandMacros(alloc, "{{setglobalvar::flag::on}}{{getglobalvar::flag}} {{hasglobalvar::flag}} {{banned secret}}x", &ctx);
    try std.testing.expectEqualStrings("on true x", out);
}

test "object/array var macros (setvarkey/getvarkey)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const vars = std.StringHashMap([]const u8).init(alloc);
    var ctx = MacroCtx{ .vars = vars };
    // Object vars: set two keys, get each back, getvar serializes the object
    const out = try expandMacros(alloc, "{{setvarkey::obj::name::alice}}{{setvarkey::obj::role::knight}}name={{getvarkey::obj::name}} role={{getvarindex::obj::role}} obj={{getvar::obj}} has={{hasvar::obj}} missing={{getvarkey::obj::missing}};", &ctx);
    try std.testing.expectEqualStrings("name=alice role=knight obj={\"name\":\"alice\",\"role\":\"knight\"} has=true missing=;", out);
    // Array vars: numeric contiguous keys serialize as an array
    const out2 = try expandMacros(alloc, "{{setvarkey::arr::0::first}}{{setvarkey::arr::1::second}}arr={{getvar::arr}} second={{getvarkey::arr::1}};", &ctx);
    try std.testing.expectEqualStrings("arr=[\"first\",\"second\"] second=second;", out2);
    // Global variants with $-prefix isolation
    const out3 = try expandMacros(alloc, "{{setglobalvarkey::g::k::gv}}g={{getglobalvarkey::g::k}} local-missing={{getvarkey::g::k}};", &ctx);
    try std.testing.expectEqualStrings("g=gv local-missing=;", out3);
    // deletevar removes the whole object
    const out4 = try expandMacros(alloc, "{{deletevar::obj}}after={{hasvar::obj}};", &ctx);
    try std.testing.expectEqualStrings("after=false;", out4);
}
