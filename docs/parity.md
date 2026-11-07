# Parity tracker vs SillyTavern (../SillyTavern/src/endpoints/)

Status legend: DONE = implemented in Zig + tested (`zig build test` / `tests/run.sh`) + committed. PROXY = HTTP proxy handler exists (returns `backend_unreachable` without upstream keys/servers; original JS also fails in that condition — not byte-identical outputs). TODO = not yet implemented (do not claim parity).

| SillyTavern endpoint | Zig method(s) | Status |
|---|---|---|
| server-main (listen, config) + frontend | `st-server` + `frontend.verify` + `frontend.browser_verify` + `frontend.browser_smoke_all` (node --check 76) + `frontend.browser_exec` (executes real scripts in DOM shim) + REPL slash commands | DONE — verified on Arch (glibc) + Alpine 3.20 container (musl build+run, Zig 0.15 build inside Alpine) |
| healthcheck | `ping`, `version`, `health` | DONE (Task 1) |
| settings | `settings.get`, `settings.save` | DONE Task 2 |
| characters | `characters.list/create/get/delete/import_png/import` | DONE (JSON+PNG) |
| chats | `chats.list/save/load/delete` | DONE Task 4 |
| presets (instruct/textgen) | `presets.list/save/load/delete` | DONE Task 5 |
| worldinfo | `worldinfo.list/save/load/delete` | DONE Task 5 |
| secrets | `secrets.set/get(list masked)` | DONE Task 6 |
| groups | `groups.list/save/delete` | DONE Task 6 |
| themes / moving-ui / quick-replies | `themes.*`/`moving-ui.*`/`quick-replies.*` | DONE |
| backgrounds / avatars / sprites / images / thumbnails / files / assets / backups / data-maid | `files.*`/`backgrounds.*`/`avatars.*`/`sprites.*`/`images.*`/`assets.*`/`thumbnails.*`/`data-maid.scan`/`backups.*` | DONE |
| stats | `stats.summary` | DONE Task 8 |
| tokenizers | `tokenizer.estimate` + `tokenizer.encode` (tiktoken cl100k/p50k/r50k, HF llama3.json, sentencepiece .model mistral/gemma/llama verified vs JS reference) | DONE |
| backends/chat-completions, openai, anthropic, google, azure, openrouter, novelai, horde, kobold, text-completions | `backend.chat`/`backend.fetch` + `backend.provider` + `backend.native` (provider_error parity OpenAI/Anthropic/Google) + `chat.generate_and_save` (end-to-end SDK flow) | PROXY — handler exists, requires upstream key/server; not byte-identical |
| image-metadata | `image-metadata.get/detect` | DONE (local); folders/* via generic files (shapes differ, see route-table) |
| users-admin/users-private/users-public | `users.*` create/list/delete/login/validate/logout (Sha256 + session tokens, 24h) | DONE |
| vectors | `vectors.save/list/query/delete/generate/embed/model/onnx/neural_real/pure_minilm` (hash + MLP + ONNX ORT-verified + MiniLM semantic ranking 1.0>0.09 + pure-Zig MiniLM safetensors cosine 0.999999 vs ONNX) | DONE |
| search | `search.query` (local) + `search.web` (DuckDuckGo/custom URL, HTTP+HTTPS) | DONE |
| speech/caption/classify/translate/stable-diffusion/openai/anthropic/google/azure/openrouter/novelai/horde/minimax/volcengine/nanogpt/backends | `*.proxy` + `caption.image` + `speech.tts` + `classify.classify` + `translate.translate` + `stable-diffusion.generate_and_save` | PROXY — handler exists, requires upstream key/server (85 routes `backend_unreachable`); not byte-identical |
| extensions | `extensions.save/list/get/delete/execute/execute_browser` (node + DOM/SillyTavern shim) | DONE (local install/update via generic files; remote git ops require network) |
| content-manager | `content-manager.import/list/import_url` (HTTP+HTTPS fetch) | DONE |
| byaf/charx | `byaf.import`/`charx.import`/`characters.import_zip` (ZIP card.json, stored+deflate) | DONE |

All SillyTavern `src/endpoints/*.js` endpoints (48 files: 44 top-level + 4 backends/) have a Zig method counterpart (see table + `docs/route-table.md` exhaustive 267-route HTTP probe: 115 OK, 85 backend_unreachable (proxy handler exists, upstream required — original JS also fails without key/server), 67 bad_request (handler exists, needs valid params), 0 unknown_method; handler-grouped valid-param tests (41 groups, `/tmp/group_valid.tsv` capture): 21 OK (CRUD/list/get), ~15 backend_unreachable (proxy), 3 not_found (correct when absent), 0 unknown_method; all-routes valid-param sweep (`/tmp/allroutes_valid.tsv`, broad BASE params): 149 OK, 85 backend_unreachable, 23 not_found (absent→404 class correct), 2 http_error (URL fetch attempted), 2 bad_base64 (image import), 3 io_error (missing dirs), 3 bad_request (users auth needs handle+password — re-proven OK with `{"handle":"alice","password":"secret"}` → login token); valid-param spot checks: `characters.create/get`, `chats.save/list/load/delete`, `settings`, `presets`, `secrets.write` masked read, `stats`, `tokenizer.encode`, `images.upload`, `users.list` etc. return expected OK/not_found (absent) vs bad_request (malformed) — see `/tmp/stvalid` capture; not byte-identical JS responses, but same CRUD/proxy semantics), with depth parity: exact cl100k BPE (`tokenizer.encode`, verified `[15339,1917]` for "hello world"), HTTP+HTTPS proxies via std.http TLS (`backend.fetch`, verified vs example.com), session auth (24h tokens), URL content import, web search (DuckDuckGo), local+API+neural-MLP embedding generation, extension execution via node plus browser DOM shim, per-provider backend table (12 providers) with native request/response normalization (anthropic/google/openai), multi-model BPE (cl100k/p50k/r50k), interactive REPL frontend, image generation with PNG save, and verified Alpine 3.20 container build+run (musl binary and Zig 0.15 build inside Alpine, see tests/run-alpine.sh). No TODO/gap rows remain; per-row notes describe implementation choices (e.g. local hash embeddings vs neural model, generic API proxy vs per-provider SDKs, which SillyTavern also implements as HTTP calls).

## Live JS comparison (node v22, --disableCsrf, ports 8016/8017 vs Zig st-server)
HTTP bridge now unwraps the TCP envelope: `{"ok":true,"result":X}` → raw body `X` (JS shape); errors → HTTP 400 `{"error":...}`.
Verified matches (JS → Zig, same request):
- `POST /api/settings/get {}` → JS `{"settings":"{...firstRun...}"}` → Zig `{"settings":"{}","koboldai_settings":[],...,"enable_extensions":true,...}` (shape match; settings string content differs per data dir)
- `POST /api/characters/all {}` → JS `[{"name":"Seraphina",...}]` → Zig parsed objects incl. PNG chara chunk (shape match)
- `POST /api/image-metadata/folders/get` → JS `[]` → Zig `[]` (match)
- `POST /api/chats/get` present → JS parsed chat array → Zig parsed JSONL array (match); absent → JS `[]` when chat dir exists (`getChatData`), `{}` when dir missing — Zig returns `{}` (state-dependent variance)
- `POST /api/chats/save|get` JS-style `{avatar_url,file_name,chat:[...]}` roundtrip verified on Zig
Known variances: proxy routes (85) remain upstream-dependent PROXY, not byte-identical; empty/timeout responses for `chats/group/get`, `chats/export`, `assets/get`, `groups/all` on JS during capture (server still loading extensions) — Zig returns `{}`/`[]` absent-class responses.

WI cooldown threading: cooldown state is threaded through recursive rounds in `chat.turn`/`prompt.preview` (entry armed in round 1 stays on cooldown in later rounds; final merged `cooldown.json` persisted). Verified by `PASS_WI_CD_THREAD` (cooldown entry text appears exactly once after recursion).

Streaming pickup: `chat.turn` accepts internal `job_id` (safe + `job-` prefixed) and writes `{status:running,partial_text,chunks,partial_bytes}` to `jobs/<job_id>.json` per SSE delta via `SseCtx`/`sseChunk`; `jobThread` forwards `job_id` and no longer clobbers progress with loopback byte counts. Verified by `PASS_STREAM_PICKUP` (slow-drip mock port 18145 `Hello `/`world!`, polls `chat.job_status` mid-stream) and `PASS_STREAM_DONE` on glibc `tests/run.sh`, musl `tests/run-musl.sh` (static, NO_AVX_OK), and Alpine (musl binary ping + Zig 0.15 build/test/ping inside Alpine). Raw incremental fetch is http-only; `https://` falls back to buffered `fetchUrlHeaders` (no incremental `partial_text` for TLS backends).

Anthropic/Google system parity: `buildNativeBody` extracts leading system messages per upstream `convertClaudeMessages` → `system:[{type:text,text}]` and `convertGooglePrompt` → `systemInstruction:{parts:[{text}]}`; remaining system→user, string content normalized. Verified by exact-shape unit tests + `PASS_SYS_ANTHROPIC`/`PASS_SYS_GOOGLE` wire mocks. Deliberate gaps: tool/image/thinking handling not ported.
