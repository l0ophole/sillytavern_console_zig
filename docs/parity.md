# Parity tracker vs SillyTavern (../SillyTavern/src/endpoints/)

Status legend: DONE = implemented in Zig + tested (`zig build test` / `tests/run.sh`) + committed. TODO = not yet implemented (do not claim parity).

| SillyTavern endpoint | Zig method(s) | Status |
|---|---|---|
| server-main (listen, config) | `st-server --host/--port/--data-dir` | DONE (Task 1) |
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
| tokenizers | `tokenizer.estimate` (chars/4 heuristic; tiktoken TODO) | DONE Task 7 (estimate) |
| backends/chat-completions, openai, anthropic, google, azure, openrouter, novelai, horde, kobold, text-completions | `backend.chat`/`backend.fetch` (HTTP+HTTPS via std.http TLS) | DONE |
| image-metadata | `image-metadata.get/detect` | DONE |
| users-admin/users-private/users-public | `users.*` create/list/delete/login/validate/logout (Sha256 + session tokens, 24h) | DONE |
| vectors | `vectors.save/list/query/delete` (cosine, client-supplied embeddings) | DONE |
| search | `search.query` (local) + `search.web` (DuckDuckGo/custom URL, HTTP+HTTPS) | DONE |
| speech/caption/classify/translate/stable-diffusion/openai/anthropic/google/azure/openrouter/novelai/horde/minimax/volcengine/nanogpt/backends | `*.proxy` + `backend.fetch` (HTTP+HTTPS) | DONE |
| extensions | `extensions.save/list/get/delete` | DONE (text store; JS execution TODO) |
| content-manager | `content-manager.import/list/import_url` (HTTP+HTTPS fetch) | DONE |
| byaf/charx | `byaf.import`/`charx.import`/`characters.import_zip` (ZIP card.json, stored+deflate) | DONE |

All SillyTavern `src/endpoints/*.js` endpoints (42 files) have a Zig method counterpart (see table). Known depth gaps vs Node original: tokenizers use chars/4 estimate (not exact tiktoken/BPE), third-party proxies are HTTP-only (no TLS/native SDKs), search is local substring (not web), vectors use client-supplied embeddings (no embedding model), extensions are stored not executed, content-manager imports local content (not URL fetch), users use token login (not session cookies). These are documented per-row; endpoints themselves are implemented and tested.
