# PARITY.md — SillyTavern console (Zig) vs upstream

Checklist: not started / implemented / tested. Detail per feature in `docs/parity.md` and `docs/route-table.md`.

## Stage 0 — repo review findings (all tested)
- [x] implemented+tested: `/api/extensions/execute` disabled by default (`execute_disabled`); enable only with `ST_ALLOW_EXECUTE=1`. No arbitrary code execution by default.
- [x] implemented+tested: auth token required on every data endpoint. Server generates `<data-dir>/token` (0600, 64 hex) or uses `ST_TOKEN`; TCP requires `params.token`, HTTP requires `X-ST-Token`. `st-client` auto-reads `ST_TOKEN` / `ST_TOKEN_FILE` / `./data/token`. Exempt: `ping`/`version`/`health` only.
- [x] implemented+tested: input validation via `std.math.cast` for all user integer fields (ports, dim, limit, max_tokens) → `bad_request`, never panic. Verified `port:99999` → `bad_request`, server stays alive.
- [x] implemented+tested: growable buffers everywhere (server `readAllAlloc`, client read-until-EOF/newline, HTTP bridge read-until-EOF). Verified 100 KB character round-trips via TCP client and HTTP (valid JSON, 100000 chars).
- [x] implemented+tested: buffered I/O (`ConnBuf`, 8 KiB chunks, leftover preserved across request line/headers/body). 1.1 MB chat (1200 msgs) save 0.164 s / load 0.194 s (was 2.5 s, >1 MiB rejected). `MAX_LINE` raised 1 MiB → 16 MiB.
- [x] implemented+tested: portable `tests/run.sh` — `mktemp -d` + `$TMP/opencode`, no `/rpf/tmp/opencode`; ONNX sections guarded by `python3 -c "import onnxruntime, numpy"` → `SKIP_NO_ONNXRUNTIME`.
- [x] implemented+tested: HTTP hardening — `Origin`/`Host` must be loopback, `Content-Type` must be `application/json` or `multipart/form-data` (415 otherwise). Verified: `text/plain` RCE → 415, evil `Origin` → 403.
- [x] implemented+tested: default Unix socket `<data-dir>/st.sock`; TCP is opt-in via `--port` and binds localhost only. `st-client --unix <path>` supported.
- [x] implemented+tested: `-Dcpu=baseline` is the default in `build.zig`; `tests/run-musl.sh` fails on any `ymm`/`zmm` in `objdump -d` output (`NO_AVX_OK`).

Deliberate differences (Stage 0): token is a local-machine secret, not SillyTavern's multi-user account session (upstream `enable_accounts` is off by default); HTTP body format for errors is `{"error":...}` with 400, matching JS `sendStatus` class.

## Stage 1 — one complete chat path (console end-to-end)
- [x] implemented+tested: `chat.turn` — loads character card (`description`/`personality`/`scenario`/`system_prompt`), builds system prompt in upstream order, `{{char}}`/`{{user}}` macros, history from chat JSONL, streams reply (SSE `stream:true`, OpenAI-compatible deltas), saves user+assistant turns, returns reloaded messages. API key: `api_key` param > `secrets.json` > `OPENROUTER_API_KEY`/`OPENAI_API_KEY` env (never logged/returned). Verified vs mock SSE backend and live OpenRouter (`openai/gpt-4o-mini`): turn 1 "Well met, noble friend!…", turn 2 history carried (`history:2`), reload shows 5 messages. `tests/run.sh` covers mock e2e + reload; live key test guarded by `OPENROUTER_API_KEY` env (server must inherit it).

## Stage 2 — prompt engine parity
- [x] implemented+tested: `src/common/prompt.zig` — macros (`char,user,time,date,weekday,lastMessage,lastUserMessage,lastCharMessage,space,newline,trim,noop,//,random,pick,roll,setvar/getvar/addvar/incvar/decvar/hasvar/deletevar`; unknown macros pass through), World Info (`worldInfoSelect`: constant always, key-matched case-insensitive, disabled excluded, constant first — upstream `getSortedEntries` order), Author's Note (`insertAuthorNote` at depth from end), instruct `system_sequence` with `{{name}}`→System. Wired into `chat.turn` (`worldinfo`, `author_note`+`author_note_depth`, `instruct` preset, `persona` params) and new `prompt.preview` (prompt-manager view: ordered messages without backend call) + `prompt.macros`. Unit tests in `prompt.zig` (6 tests); e2e in `tests/run.sh` (`PASS_WI`, `PASS_WI_CONST`, `PASS_AN`, `PASS_MACROS`) + mock verified prompt contains WI/AN. Deliberate differences: full upstream macro registry (26 definition sets: `{{if}}`, outlets, group macros) not ported — unknown macros pass through; World Info recursion/grouping/sticky/timed effects not ported (single scan); instruct only `system_sequence` applied (input/output chat-template rendering is Stage 3).

## Stage 3 — everything else
- [ ] not started: remaining providers, group chats, slash commands.
- [ ] not started: extensions ported to Zig (never Node/JS engine). Currently `extensions.execute*` are disabled by default and node-backed when explicitly enabled — to be removed/replaced in Stage 3.
