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
echo "== bad method =="
./zig-out/bin/st-client --port $PORT nope | grep -q '"ok":false' && echo PASS
cat "$TMP/server.log"
echo "ALL SMOKE TESTS PASSED"
