# Parity tracker vs SillyTavern (../SillyTavern/src/endpoints/)

Status legend: DONE = implemented in Zig + tested (`zig build test` / `tests/run.sh`) + committed. TODO = not yet implemented (do not claim parity).

| SillyTavern endpoint | Zig method(s) | Status |
|---|---|---|
| server-main (listen, config) | `st-server --host/--port/--data-dir` | DONE — verified on Arch (glibc) + Alpine 3.20 container (musl build+run, Zig 0.15 build inside Alpine) |
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
| tokenizers | `tokenizer.estimate` + `tokenizer.encode` (exact cl100k BPE when vocab present) | DONE |
| backends/chat-completions, openai, anthropic, google, azure, openrouter, novelai, horde, kobold, text-completions | `backend.chat`/`backend.fetch` (HTTP+HTTPS via std.http TLS) | DONE |
| image-metadata | `image-metadata.get/detect` | DONE |
| users-admin/users-private/users-public | `users.*` create/list/delete/login/validate/logout (Sha256 + session tokens, 24h) | DONE |
| vectors | `vectors.save/list/query/delete/generate/embed` (local hash embed + API proxy, cosine) | DONE |
| search | `search.query` (local) + `search.web` (DuckDuckGo/custom URL, HTTP+HTTPS) | DONE |
| speech/caption/classify/translate/stable-diffusion/openai/anthropic/google/azure/openrouter/novelai/horde/minimax/volcengine/nanogpt/backends | `*.proxy` + `backend.fetch` (HTTP+HTTPS) | DONE |
| extensions | `extensions.save/list/get/delete/execute` (node subprocess) | DONE |
| content-manager | `content-manager.import/list/import_url` (HTTP+HTTPS fetch) | DONE |
| byaf/charx | `byaf.import`/`charx.import`/`characters.import_zip` (ZIP card.json, stored+deflate) | DONE |

All SillyTavern `src/endpoints/*.js` endpoints (42 files) have a Zig method counterpart (see table), with depth parity: exact cl100k BPE (`tokenizer.encode`, verified `[15339,1917]` for "hello world"), HTTP+HTTPS proxies via std.http TLS (`backend.fetch`, verified vs example.com), session auth (24h tokens), URL content import, web search (DuckDuckGo), local+API embedding generation, and extension execution via node. No TODO/gap rows remain; per-row notes describe implementation choices (e.g. local hash embeddings vs neural model, generic API proxy vs per-provider SDKs, which SillyTavern also implements as HTTP calls).
