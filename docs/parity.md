# Parity tracker vs SillyTavern (../SillyTavern/src/endpoints/)

Status legend: DONE = implemented in Zig + tested (`zig build test` / `tests/run.sh`) + committed. TODO = not yet implemented (do not claim parity).

| SillyTavern endpoint | Zig method(s) | Status |
|---|---|---|
| server-main (listen, config) | `st-server --host/--port/--data-dir` | DONE (Task 1) |
| healthcheck | `ping`, `version`, `health` | DONE (Task 1) |
| settings | `settings.get`, `settings.save` | DONE Task 2 |
| characters | `characters.list/create/get/delete` | DONE Task 3 (JSON; PNG card TODO) |
| chats | `chats.list/save/load/delete` | DONE Task 4 |
| presets (instruct/textgen) | `presets.list/save/load/delete` | DONE Task 5 |
| worldinfo | `worldinfo.list/save/load/delete` | DONE Task 5 |
| secrets | `secrets.set/get(list masked)` | TODO Task 6 |
| groups | `groups.list/save/delete` | DONE Task 6 |
| themes / moving-ui / quick-replies | `themes.*` generic | DONE Task 6 (themes) |
| backgrounds / avatars / sprites / images / thumbnails / files / assets / backups / data-maid | `files.*`, `backups.create/list` (generic binary store) | TODO Task 6/8 |
| stats | `stats.summary` | TODO Task 8 |
| tokenizers | `tokenizer.estimate` (chars/4 heuristic; tiktoken TODO) | TODO Task 7 |
| backends/chat-completions, openai, anthropic, google, azure, openrouter, novelai, horde, kobold, text-completions | `backend.chat` (OpenAI-compatible HTTP proxy; native SDKs TODO) | TODO Task 7 |
| speech, caption, classify, translate, search, vectors, extensions, content-manager, users-*, stable-diffusion, image-metadata, byaf/charx | — | TODO (listed, not claimed) |

Honest gap: full parity with upstream SillyTavern (image gen, embeddings, extensions JS plugins, multi-user auth) is a multi-month effort; this repo tracks progress feature-by-feature rather than claiming completion.
