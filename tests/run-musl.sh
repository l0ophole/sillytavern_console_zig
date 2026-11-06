#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/zig:$PATH"
check_no_avx() {
  if command -v objdump >/dev/null 2>&1; then
    if objdump -d "$1" 2>/dev/null | grep -qE '%(ymm|zmm)[0-9]'; then
      echo "FAIL_AVX_FOUND in $1"; objdump -d "$1" | grep -E '%(ymm|zmm)[0-9]' | head -3; exit 1
    fi
    echo "NO_AVX_OK $1"
  else
    echo "SKIP_NO_OBJDUMP"
  fi
}
echo "== musl baseline build =="
rm -rf zig-out
zig build -Dtarget=x86_64-linux-musl -Dcpu=baseline
file zig-out/bin/st-server
check_no_avx zig-out/bin/st-server
echo "== gnu baseline build =="
rm -rf zig-out
zig build -Dtarget=x86_64-linux-gnu -Dcpu=baseline
file zig-out/bin/st-server
check_no_avx zig-out/bin/st-server
echo "MUSL+GNU BUILD OK"
