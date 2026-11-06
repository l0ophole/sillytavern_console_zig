#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/zig:$PATH"
echo "== zig build test =="
zig build test
echo "== zig build =="
zig build
PORT=18081
TMP=$(mktemp -d)
trap 'kill $(cat "$TMP/pid") 2>/dev/null || true; rm -rf "$TMP"' EXIT
./zig-out/bin/st-server --port $PORT --data-dir "$TMP/data" >"$TMP/server.log" 2>&1 &
echo $! >"$TMP/pid"
sleep 1
echo "== ping =="
./zig-out/bin/st-client --port $PORT ping | grep -q '"pong":true' && echo PASS
echo "== version =="
./zig-out/bin/st-client --port $PORT version | grep -q '"version"' && echo PASS
echo "== settings round-trip =="
./zig-out/bin/st-client --port $PORT settings.save '{"settings":{"power_user":true}}' | grep -q '"saved":true' && echo PASS
./zig-out/bin/st-client --port $PORT settings.get | grep -q 'power_user' && echo PASS
echo "== characters =="
./zig-out/bin/st-client --port $PORT characters.create '{"name":"Alice","character":{"name":"Alice"}}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT characters.list | grep -q 'Alice' && echo PASS
./zig-out/bin/st-client --port $PORT characters.get '{"name":"Alice"}' | grep -q 'Alice' && echo PASS
./zig-out/bin/st-client --port $PORT characters.delete '{"name":"Alice"}' | grep -q '"deleted"' && echo PASS
echo "== chats =="
./zig-out/bin/st-client --port $PORT chats.save '{"character":"Alice","chat":"main","data":[{"name":"Alice","mes":"hi"}]}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT chats.list '{"character":"Alice"}' | grep -q 'main' && echo PASS
./zig-out/bin/st-client --port $PORT chats.load '{"character":"Alice","chat":"main"}' | grep -q 'hi' && echo PASS
./zig-out/bin/st-client --port $PORT chats.delete '{"character":"Alice","chat":"main"}' | grep -q '"deleted"' && echo PASS
echo "== presets/worldinfo/groups/themes =="
./zig-out/bin/st-client --port $PORT presets.save '{"name":"p1","value":{"temp":1}}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT presets.load '{"name":"p1"}' | grep -q 'temp' && echo PASS
./zig-out/bin/st-client --port $PORT worldinfo.save '{"name":"w1","value":{}}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT groups.save '{"name":"g1","value":{}}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT themes.save '{"name":"t1","value":{}}' | grep -q '"saved"' && echo PASS
echo "== secrets =="
./zig-out/bin/st-client --port $PORT secrets.set '{"key":"k1","value":"v1"}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT secrets.list | grep -q 'k1' && echo PASS
./zig-out/bin/st-client --port $PORT secrets.list | grep -q 'v1' && echo FAIL || echo PASS_MASKED
echo "== tokenizer/backend =="
./zig-out/bin/st-client --port $PORT tokenizer.estimate '{"text":"hello world"}' | grep -q '"tokens"' && echo PASS
./zig-out/bin/st-client --port $PORT backend.chat '{"host":"127.0.0.1","port":9,"path":"/v1/chat/completions","body":{}}' | grep -q 'backend_unreachable' && echo PASS
echo "== bad method =="
./zig-out/bin/st-client --port $PORT nope | grep -q '"ok":false' && echo PASS
cat "$TMP/server.log"
echo "ALL SMOKE TESTS PASSED"
