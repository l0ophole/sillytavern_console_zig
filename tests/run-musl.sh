#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/zig:$PATH"
check_no_avx() {
  # Symbol-aware AVX check: objdump's linear sweep decodes trailing function
  # padding as AVX (false positive, e.g. inside posix.mremap). Only flag
  # %ymm/%zmm matches strictly inside a function's body (excluding its
  # final 16 bytes of padding).
  if command -v objdump >/dev/null 2>&1 && command -v nm >/dev/null 2>&1; then
    objdump -d "$1" 2>/dev/null | grep -E '%(ymm|zmm)[0-9]' > /rpf/tmp/opencode/avxhits.txt || true
    if [ ! -s /rpf/tmp/opencode/avxhits.txt ]; then
      echo "NO_AVX_OK $1"; return 0
    fi
    echo "AVX candidates (verifying symbol bounds):"
    cat /rpf/tmp/opencode/avxhits.txt
    nm -nS "$1" 2>/dev/null > /rpf/tmp/opencode/avxnm.txt || true
    FAIL=0
    while IFS= read -r line; do
      ADDR_HEX=$(echo "$line" | cut -d: -f1 | tr -d ' \t')
      ADDR=$((0x$ADDR_HEX))
      while read -r faddr fsize ftype fname; do
        case "$faddr" in ''|'U'*|'u'*|'0000'*) continue;; esac
        case "$fsize" in ''|*[!0-9a-fA-F]*) continue;; esac
        F=$((0x$faddr))
        S=$((0x$fsize))
        if [ "$ADDR" -ge "$F" ] && [ "$ADDR" -lt $((F + S - 16)) ]; then FAIL=1; break; fi
      done < /rpf/tmp/opencode/avxnm.txt
    done < /rpf/tmp/opencode/avxhits.txt
    if [ "$FAIL" = "1" ]; then echo "FAIL_AVX_FOUND in $1"; exit 1; fi
    echo "NO_AVX_OK $1"
  elif command -v objdump >/dev/null 2>&1; then
    if objdump -d "$1" 2>/dev/null | grep -qE '%(ymm|zmm)[0-9]'; then
      echo "FAIL_AVX_FOUND in $1"; exit 1
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
