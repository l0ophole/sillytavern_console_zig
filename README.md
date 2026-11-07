# SillyTavern Console (Zig)

Console port of [SillyTavern](https://github.com/SillyTavern/SillyTavern) (original in `../SillyTavern/`) written in **Zig**, std-library only.

## Architecture (client-server)

```
st-client (console REPL / CLI)  --TCP line-JSON-->  st-server (core)
                                                    data/<user>/
                                                      settings.json
                                                      characters/*.json
                                                      chats/<char>/*.jsonl
                                                      presets/*.json
                                                      worldinfo/*.json
                                                      secrets.json (0600)
                                                      groups/*.json  themes/*.json
```

- Protocol: one JSON object per line: `{"method":"...","params":{...}}` → `{"ok":true,"result":...}` / `{"ok":false,"error":"..."}`.
- No AVX required: built with `-mcpu=baseline` (x86_64 baseline). No SIMD intrinsics used.
- glibc + musl: std-only, no libc-specific deps. Cross-compile verified (see below).
- OS: Arch Linux (glibc) and Alpine Linux (musl).

## Build & run (Arch / Alpine)

```sh
# Arch: sudo pacman -S zig   # or download 0.15.x tarball
# Alpine: apk add zig   # or download tarball; musl is native there

zig build test
zig build
./zig-out/bin/st-server --port 8000 --data-dir ./data &
./zig-out/bin/st-client ping
./zig-out/bin/st-client version
./zig-out/bin/st-client health
./zig-out/bin/st-client settings.get
./zig-out/bin/st-client characters.list
```

Cross-compile (baseline CPU, no AVX):

```sh
zig build -Dtarget=x86_64-linux-gnu -Dcpu=baseline
zig build -Dtarget=x86_64-linux-musl -Dcpu=baseline
file zig-out/bin/st-server  # musl build is statically linked
```

`-Dcpu=baseline` is the `zig build` option (via `standardTargetOptions`) that guarantees no AVX requirement. Verified: both targets build, musl binary runs, `objdump` shows no `ymm`/AVX instructions.

## Data compatibility

File formats mirror SillyTavern `src/endpoints/*` where practical:
- Characters: JSON card fields from `src/endpoints/characters.js` (`name, description, personality, scenario, first_mes, mes_example, creator_notes, system_prompt, post_history_instructions, tags, creator, character_version, alternate_greetings, extensions`). PNG card import/export is tracked in `docs/parity.md`.
- Chats: JSONL, one message per line (`{name,is_user,mes,send_date,extra}`) per `src/endpoints/chats.js`.
- Settings/presets/worldinfo/groups/themes: JSON passthrough (server stores the client's JSON object verbatim, so fields stay compatible).

## Parity

See [docs/parity.md](docs/parity.md) — honest per-endpoint status vs `../SillyTavern/src/endpoints/`. Not everything is claimed done until implemented and tested.

## Tests

```sh
zig build test
tests/run.sh   # strict smoke/e2e: every failure exits nonzero; ALL SMOKE TESTS PASSED only with zero failures; skips listed separately (ST_FORCE_FAIL=1 proves nonzero exit)
tests/run-musl.sh   # musl + gnu baseline builds, AVX-family disassembly check incl. XMM VEX forms (NO_AVX_OK)
tests/run-alpine.sh  # musl binary + Zig 0.15 build inside Alpine 3.20 (ALPINE VERIFIED)
```

Each feature is implemented, tested (unit + actual client/server end-to-end), then committed and pushed separately (see `git log`). Failing code and secrets are never committed; failures/skips are reported honestly.


## License

AGPL-3.0 (same as SillyTavern). See LICENSE if present; original SillyTavern is AGPL-3.0.
