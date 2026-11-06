# SillyTavern Console (Zig) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a console port of SillyTavern in Zig with client-server architecture and feature parity tracked against the original.

**Architecture:** A Zig `st-server` (TCP, line-delimited JSON) owns all data under `data/<user>/`; a Zig `st-client` console REPL connects per-request. Std-only, `-mcpu=baseline` (no AVX), builds for glibc and musl (`x86_64-linux-gnu` / `x86_64-linux-musl`).

**Tech Stack:** Zig 0.15.2, std library only (no external deps, for musl/static portability), `zig build test`.

**Spec:** User objective — console port of `@SillyTavern/` into `@SillyTavern_console_zig/`, complete parity goal, Zig, Arch+Alpine, x86_64 no AVX, client-server, glibc+musl, one feature at a time with tests, git commits per feature, remote `https://github.com/l0ophole/sillytavern_console_zig.git` kept in sync.

## Global Constraints
- Language: Zig 0.15.2, std-only.
- CPU: `-mcpu=baseline` default (no AVX required); document `x86_64` baseline.
- OS/libc: Arch (glibc) and Alpine (musl); verify `zig build -Dtarget=x86_64-linux-musl` and `-Dtarget=x86_64-linux-gnu`.
- One feature per commit; each commit runs `zig build test` + integration smoke test and is pushed.
- Remote must be `origin` = `https://github.com/l0ophole/sillytavern_console_zig.git`, pushed after each commit.

## Review Focus
- Malformed JSON / oversized line from client → server returns `{"ok":false,"error":"bad_request"}` and stays alive, never crashes.
- Path traversal in names (`../`) → rejected, no file written outside data dir.
- Secrets file permissions → `0600` on write; values masked in list responses.
- Server port already in use / client cannot connect → clear error, non-zero exit.
- Concurrent writes to same chat file → last-write-wins with atomic rename (write tmp + rename).

---
### Task 1: Scaffold + ping/version
**Files:** Create: `build.zig`, `build.zig.zon`, `src/common/protocol.zig`, `src/server/main.zig`, `src/client/main.zig`, `src/main.zig`, `README.md`, `.gitignore`
**Interfaces:** Consumes: Zig std. Produces: `protocol.Request{method,params}`, `protocol.Response{ok,result,error}`, executables `st-server`/`st-client`.
- [ ] Step 1: Write failing test in `protocol.zig` (`parse ping`, `encode response`).
- [ ] Step 2: Run `zig build test` → FAIL.
- [ ] Step 3: Implement minimal protocol + server/client.
- [ ] Step 4: Run `zig build test` + smoke (`st-server & st-client ping`) → PASS.
- [ ] Step 5: Commit + push.

### Task 2: Settings store
**Files:** Create: `src/common/store.zig`; Modify: server dispatch.
**Interfaces:** Produces: `store.getSettings`, `store.saveSettings` (atomic rename).
- [ ] Test round-trip save/load; run; implement; run; commit+push.

### Task 3: Characters
**Files:** Create: `src/common/characters.zig`.
**Interfaces:** Produces: list/create/get/delete character cards (JSON v2 compatible fields: name, description, personality, scenario, first_mes, mes_example, creator_notes, system_prompt, post_history_instructions, tags, creator, character_version, alternate_greetings, extensions).
- [ ] Test create/list/get/delete + traversal rejection; run; implement; run; commit+push.

### Task 4: Chats
**Files:** Create: `src/common/chats.zig`.
**Interfaces:** Produces: save/load/list/delete chat JSONL (`{name,is_user,mes,send_date,...}` per SillyTavern `src/endpoints/chats.js`).
- [ ] Test save/load/list; run; implement; run; commit+push.

### Task 5: Presets + WorldInfo
**Files:** Create: `src/common/presets.zig`, `src/common/worldinfo.zig`.
- [ ] Test round-trips; run; implement; run; commit+push.

### Task 6: Secrets + Groups + Themes (generic collections)
**Files:** Create: `src/common/secrets.zig`, `src/common/collections.zig`.
- [ ] Test masking + 0600 + generic CRUD; run; implement; run; commit+push.

### Task 7: Backends (OpenAI-compatible proxy) + tokenizer estimate
**Files:** Create: `src/common/backend.zig`, `src/common/tokenizer.zig`.
**Interfaces:** `backend.forwardChatCompletion` via `std.http.Client`; `tokenizer.estimateTokens` (chars/4 heuristic, documented as estimate vs SillyTavern tiktoken).
- [ ] Test tokenizer + backend request building (offline); run; implement; run; commit+push.

### Task 8: Console client REPL + Stats/Backups
**Files:** Modify: `src/client/main.zig`; Create: `src/common/stats.zig`.
- [ ] Test non-interactive client commands (`ping`, `characters list`, `settings get`); run; implement; run; commit+push.

### Task 9: musl/glibc + Alpine/Arch verification
**Files:** Create: `tests/run.sh`, `docs/parity.md` updates, CI-ish `Makefile` targets.
- [ ] Cross-compile both targets with baseline CPU; run musl binary smoke if possible; document; commit+push.

## Self-Review
1. Spec coverage: client-server ✓ (T1), Zig ✓, Arch/Alpine (T9), no-AVX baseline ✓ (build.zig + T9), glibc+musl ✓ (T9), feature-at-a-time+test+commit+push ✓ (each task), parity — tracked in `docs/parity.md`, remaining endpoints listed as TODO with honest status (not claimed complete until implemented).
2. Step scan: each task has test→fail→implement→pass→commit.
3. Type consistency: `protocol` types reused across tasks.
4. Review Focus: each bullet mapped to a test in its owning task.
5. Proportion: plan is decision record, not code transcript.
