#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/zig:$PATH"
echo "== musl baseline build =="
rm -rf zig-out
zig build -Dtarget=x86_64-linux-musl -Dcpu=baseline
file zig-out/bin/st-server
echo "== gnu baseline build =="
rm -rf zig-out
zig build -Dtarget=x86_64-linux-gnu -Dcpu=baseline
file zig-out/bin/st-server
echo "MUSL+GNU BUILD OK"
