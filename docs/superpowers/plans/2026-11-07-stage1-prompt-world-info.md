# Stage 1 Prompt / World Info Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port upstream prompt/world-info activation semantics to Zig so activated entries reach outgoing prompts unmodified, verified against exact backend requests.

**Architecture:** Pure selection logic stays in `src/common/prompt.zig` (unit-tested, no I/O); server (`src/server/main.zig` `chat.turn`/`prompt.preview`) owns scan-buffer assembly, prompt-manager ordering, and persistence. Exact-request fixtures live in `tests/run.sh`.

**Tech Stack:** Zig 0.15.2 std-only; `zig build test`; POSIX sockets; versioned JSON API; mock SSE backend.

**Spec:** `PARITY.md` Stage 1 (prompt/world-info) + upstream `SillyTavern/public/scripts/world-info.js`, `prompt-manager.js`, `authors-note.js`, `macros.js`, `instruct-mode.js` at revision below.

## Global Constraints

- Upstream reference revision: `06bde939fb1e9c4c8d8641d810f0a916b5bce127`.
- No Node/Python/JS runtime; Zig std-only; `-Dcpu=baseline`; x86_64 glibc + musl.
- Server-owned state; versioned JSON API; Unix socket default, TCP localhost opt-in; auth on user-data endpoints.
- Never commit/push failing code or secrets; commit+push after each tested change; report skips/failures honestly.
- `extensions.execute*` unconditionally `execute_disabled`; no re-instruction prompt contexts (upstream disabled contexts ignored, not injected).

## Review Focus

- Unicode + overlapping keys: case folding must handle UTF-8 (e.g. `É`/`é`) and whole-word boundaries must not split multi-byte words.
- Depth boundaries: scan depth 0/negative/clamped to `MAX_SCAN_DEPTH=1000` must not wrap or over-read; entry `scanDepth` overrides global.
- Budget trimming: entries that fit exactly at budget boundary included; overflow stops before exceeding unless `ignoreBudget`.
- Regex-like keys (`parseRegexFromString` upstream): key starting with `/.../flags` must either load or be documented deliberate difference, never silently mis-matched as literal and never crash.
- Global scan flags + embedded lorebook: persona/character fields scanned only when `match*` flags set; card `character_book` entries deduplicated against file books by `world.uid`.

---

### Task 1: Record revision + fixture inventory

**Files:**
- Modify: `SillyTavern_console_zig/PARITY.md` (upstream revision + Stage 1 gaps)
- Modify: `SillyTavern_console_zig/docs/superpowers/plans/2026-11-07-stage1-prompt-world-info.md` (this file)

**Interfaces:**
- Consumes: `../SillyTavern` HEAD `06bde939fb1e9c4c8d8641d810f0a916b5bce127`.
- Produces: Documented gaps list below (all later tasks reference it).

- [ ] **Step 1: Verify revision**

Run: `git -C ../SillyTavern rev-parse HEAD`
Expected: `06bde939fb1e9c4c8d8641d810f0a916b5bce127`

- [ ] **Step 2: Inventory Eldoria + gaps (no code change)**

Run: `python3 -c "import json; d=json.load(open('../SillyTavern/data/default-user/worlds/Eldoria.json')); print(len(d['entries']))"`
Expected: 4 entries (uid 0..3, keys COOL-derived: `eldoria/wood/forest/magical forest`, `shadowfang/...`, etc.)

Gaps vs upstream (checked 2026-11-07):
1. `prompt.zig worldInfoSelect` ignores `keysecondary` + `selectiveLogic` (0-3).
2. `worldInfoSelect` ignores `caseSensitive`, `matchWholeWords`, regex keys.
3. Ordering is constant-first + insertion order; upstream sorts activated set by `order` desc and splits by `position` into before/after/EM/depth/AN/outlet buckets.
4. No token budget (`world_info_budget` % of `maxContext`, cap, `ignoreBudget`) — `worldInfoSelect` returns unbounded text.
5. No scan depth: server builds `scan = sys_macro + user + last_char_mes` only; upstream `WorldInfoBuffer` scans last `scanDepth`/`world_info_depth` (default 4, MAX 1000) chat messages plus opt-in global-scan fields + recursion buffer, dedup by `world.uid` (`allActivatedEntries`).
6. Recursion re-selects whole text (`worldInfoSelectRecursive` uses substring check) — upstream uses `allActivatedEntries` dedup + `preventRecursion`/`excludeRecursion`/`delayUntilRecursion`.
7. Server WI wiring calls `insertAuthorNote(msgs, wi_text, history_count+1)` (WI as last system "note") — upstream prompt-manager order is different (before/examples/history/AN/after, see Task 4).

- [ ] **Step 3: Commit docs-only inventory**

```bash
git add PARITY.md docs/superpowers/plans/2026-11-07-stage1-prompt-world-info.md
git commit -m "docs(stage1): record upstream rev 06bde939 and prompt/world-info gap inventory"
git push origin main
```

Expected: pushed; no code change.

---

### Task 2: Selective matching (keysecondary + selectiveLogic + case/whole-words)

**Files:**
- Modify: `src/common/prompt.zig` (selection core)
- Test: `src/common/prompt.zig` unit tests (`test "worldinfo selectiveLogic..."`)

**Interfaces:**
- Consumes: `worldInfoSelect(alloc, entries_json, scan_text) []u8` (existing signature preserved for compatibility).
- Produces: Same signature, but matches upstream `checkWorldInfo` secondary logic:
  `AND_ANY=0, NOT_ALL=1, NOT_ANY=2, AND_ALL=3`, default 0.

- [ ] **Step 1: Write the failing test**

```zig
test "worldinfo selectiveLogic secondary keys" {
    // primary match + AND_ANY secondary match -> active
    // primary match + AND_ALL missing one secondary -> inactive
    // primary match + NOT_ANY with any secondary present -> inactive
    // primary match + NOT_ALL with missing secondary -> active
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `~/.local/zig/zig build test 2>&1 | grep selectiveLogic`
Expected: FAIL (no secondary check today).

- [ ] **Step 3: Implement minimal matching in `worldInfoSelect` + shared `worldInfoMatch` helper**

One line on approach: per-entry: compute `primary_match` (`entry.key` any-hit), if no `keysecondary` → active iff `constant` or `primary_match`; else evaluate `selectiveLogic` over secondary hits exactly as upstream `matchSecondaryKeys` (short-circuit AND_ANY/NOT_ALL per matched key, then NOT_ANY/AND_ALL fallthrough).

- [ ] **Step 4: Run test to verify it passes**

Run: `~/.local/zig/zig build test`
Expected: PASS (all prompt tests).

- [ ] **Step 5: Commit**

```bash
git add src/common/prompt.zig
git commit -m "feat(stage1): world info selectiveLogic and secondary keys"
git push origin main
```

---

### Task 3: Case, whole-words, regex override, ordering, positions, budget, dedup

**Files:**
- Modify: `src/common/prompt.zig`
- Test: `src/common/prompt.zig` unit tests (`test "worldinfo case/whole-words/regex/order/budget/positions"`)

**Interfaces:**
- Consumes: Task 2 `worldInfoMatch` helper; upstream `WorldInfoBuffer.matchKeys` + `sortFn` + budget.
- Produces: `worldInfoSelect` honours `caseSensitive` (default `world_info_case_sensitive=false` → case-insensitive, Unicode-aware), `matchWholeWords` (whole-word regex boundary unless multi-word substring), regex keys (`/pat/flags` → document path: implement literal fallback + document as deliberate difference if no regex engine; must not mis-activate), sort by `order` desc (stable), `position` buckets, budget `budget=floor(percent%*maxContext)` capped + `ignoreBudget`, dedup by `uid`.

- [ ] **Step 1: Write failing test**

```zig
test "worldinfo case whole words order budget positions dedup" {
    // caseSensitive=true: "Tolken" not match "tolken"
    // matchWholeWords: "art" not match "part"
    // order desc: high order hits first
    // position 1 (before) vs 0 (after) split
    // budget: overflow entry trimmed unless ignoreBudget
    // dedup: same uid twice -> once
}
```

- [ ] **Step 2: Run to verify fail**

Run: `~/.local/zig/zig build test`
Expected: FAIL.

- [ ] **Step 3: Implement minimal (Unicode-aware lower-casing via `std.unicode`, boundary `\W` per upstream; sort + bucket + budget + dedup in selection core).**

- [ ] **Step 4: Run to verify pass**

Run: `~/.local/zig/zig build test && ~/.local/zig/zig build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/common/prompt.zig
git commit -m "feat(stage1): world info case/words/order/positions/budget/dedup"
git push origin main
```

---

### Task 4: Scan buffer depth + recursion + global scan data + prompt order

**Files:**
- Modify: `src/common/prompt.zig` (`worldInfoScanBuffer` helper)
- Modify: `src/server/main.zig` (`chat.turn` scan assembly + message ordering, replacing `insertAuthorNote` WI hack)
- Test: `src/common/prompt.zig` depth tests + `tests/run.sh` fixture (Task 5)

**Interfaces:**
- Consumes: Task 3 selection core.
- Produces: `worldInfoScanBuffer(alloc, history_msgs_json, opts) []u8` scanning last `N` messages (global `world_info_depth` default 4, entry `scanDepth` override, clamped 0..1000) + recursion buffer contents (previously activated content) without duplication; server passes opt-in global fields (persona/description/personality/scenario/depth-prompt/creator-notes) only when `match*` set.

- [ ] **Step 1: Write failing depth test**

```zig
test "worldinfo scan depth boundary" {
    // depth=1 scans only last message; depth=0 scans none; depth>len clamps to len
}
```

- [ ] **Step 2: Run to verify fail**

Run: `~/.local/zig/zig build test`
Expected: FAIL (no depth API).

- [ ] **Step 3: Implement `worldInfoScanBuffer` + server scan assembly + correct prompt-manager order** (system → WI-before → examples → history → author-note → WI-after → depth/outlet vars via macros; WI no longer via `insertAuthorNote`).

- [ ] **Step 4: Run to verify pass**

Run: `~/.local/zig/zig build test && ~/.local/zig/zig build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/common/prompt.zig src/server/main.zig
git commit -m "feat(stage1): world info scan depth, recursion dedup and prompt order"
git push origin main
```

---

### Task 5: Exact-request fixtures + Eldoria e2e + preview secret-safe

**Files:**
- Modify: `tests/run.sh` (mock captures request body to file)
- Modify: `src/server/main.zig` (`prompt.preview` secret-safe check if needed)
- Test: `tests/run.sh` new `stage1` section

**Interfaces:**
- Consumes: Tasks 2-4 selection + ordering.
- Produces: `tests/run.sh` asserts: roles/order/content + lore activation for: Eldoria key hit, overlapping keys, Unicode key, depth boundary, budget trim; `prompt.preview` returns prompt without `api_key`/`secrets.json` values.

- [ ] **Step 1: Write failing fixture**

```sh
# mock server writes $REQUEST_CAPTURE (backend request JSON); run.sh asserts
# captured roles order and that activated Eldoria content is present verbatim.
```

- [ ] **Step 2: Run to verify fail**

Run: `sh tests/run.sh 2>&1 | grep STAGE1`
Expected: FAIL (no capture / lore not in request).

- [ ] **Step 3: Implement capture mock + assertions (tests only) + preview secret fix if test shows leak.**

- [ ] **Step 4: Run to verify pass**

Run: `sh tests/run.sh 2>&1 | tail -5`
Expected: `FAILURES=0`, `ALL SMOKE TESTS PASSED`, `STAGE1_*` PASS lines.

- [ ] **Step 5: Commit**

```bash
git add tests/run.sh src/server/main.zig src/common/prompt.zig
git commit -m "test(stage1): exact backend request fixtures and Eldoria e2e"
git push origin main
```

---

### Task 6: Verify + docs close-out

**Files:**
- Modify: `PARITY.md`, `README.md`, `docs/parity.md`

**Interfaces:**
- Consumes: All above.
- Produces: Honest Stage 1 claim + deliberate differences (regex keys, min-activations/probability/triggers/characterFilter/decorators/external-activation if not ported, next-semantic-fallback).

- [ ] **Step 1: Run full verification**

Run: `sh tests/run.sh; sh tests/run-musl.sh; sh tests/run-alpine.sh`
Expected: all exit 0 (`FAILURES=0`, `NO_AVX_OK`, `ALPINE VERIFIED`).

- [ ] **Step 2: Update docs + commit**

```bash
git add PARITY.md README.md docs/parity.md
git commit -m "docs(stage1): prompt/world-info parity evidence and gaps"
git push origin main
```

---

## Self-Review

1. Spec coverage: selectiveLogic/keys (T2), case/words/regex/order/positions/budget/dedup (T3), depth/recursion/global scan/order (T4), fixtures/preview/Eldoria (T5), docs + platform verify (T6). Card fields/greetings/examples/system/post-history/depth-prompt/embedded-lorebook are wired in T4 server changes (embedded lorebook = merged entries source) and verified in T5 Eldoria e2e; greetings-initialization uses existing `chats.create` greeting seeding (verify in T5 if missing then add task).
2. Step scan: each step is one action (write test, run fail, implement, run pass, commit). Code steps name the file/function only, not bodies.
3. Type consistency: `worldInfoSelect(alloc, entries_json, scan_text) []u8` preserved; new `worldInfoMatch` + `worldInfoScanBuffer` names fixed here for later tasks.
4. Review Focus: Unicode/depth/budget/regex/global-scan each have a named test in T2/T3/T4/T5.
5. Proportion: plan length is shorter than implementation; bodies omitted per design.
