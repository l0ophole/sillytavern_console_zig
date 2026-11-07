#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Resolve zig: $ZIG, PATH, or ~/.local/zig.
ZIG_BIN="${ZIG:-}"
if [ -z "$ZIG_BIN" ]; then
  if command -v zig >/dev/null 2>&1; then ZIG_BIN=zig;
  elif [ -x "$HOME/.local/zig/zig" ]; then ZIG_BIN="$HOME/.local/zig/zig";
  else echo "FATAL: zig not found (set ZIG)" >&2; exit 1; fi
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# AVX-family candidates: %ymm/%zmm registers AND VEX-encoded XMM forms
# (vmov/vadd/...ps/pd/ss/sd with %xmm operands) — baseline x86-64 has no VEX.
avx_hits() {
  objdump -d "$1" 2>/dev/null | grep -E '%(ymm|zmm)[0-9]|\sv[a-z]+(ps|pd|ss|sd)\b.*%xmm|\sv[a-z]+(ps|pd|ss|sd)\b.*%ymm' || true
}
check_no_avx() {
  # Symbol-aware AVX check: objdump's linear sweep decodes trailing function
  # padding as AVX (false positive, e.g. inside posix.mremap). Only flag
  # matches strictly inside a function's body (excluding its
  # final 16 bytes of padding).
  if command -v objdump >/dev/null 2>&1 && command -v nm >/dev/null 2>&1; then
    avx_hits "$1" > "$WORK/avxhits.txt"
    if [ ! -s "$WORK/avxhits.txt" ]; then
      echo "NO_AVX_OK $1"; return 0
    fi
    echo "AVX candidates (verifying symbol bounds):"
    cat "$WORK/avxhits.txt"
    nm -nS "$1" 2>/dev/null > "$WORK/avxnm.txt" || true
    FAIL=0
    while IFS= read -r line; do
      ADDR_HEX=$(echo "$line" | cut -d: -f1 | tr -d ' \t')
      case "$ADDR_HEX" in ''|*[!0-9a-fA-F]*) continue;; esac
      ADDR=$((0x$ADDR_HEX))
      while read -r faddr fsize ftype fname; do
        case "$faddr" in ''|'U'*|'u'*|'0000'*) continue;; esac
        case "$fsize" in ''|*[!0-9a-fA-F]*) continue;; esac
        F=$((0x$faddr))
        S=$((0x$fsize))
        if [ "$ADDR" -ge "$F" ] && [ "$ADDR" -lt $((F + S - 16)) ]; then FAIL=1; break; fi
      done < "$WORK/avxnm.txt"
    done < "$WORK/avxhits.txt"
    if [ "$FAIL" = "1" ]; then echo "FAIL_AVX_FOUND in $1"; exit 1; fi
    echo "NO_AVX_OK $1"
  elif command -v objdump >/dev/null 2>&1; then
    if avx_hits "$1" | grep -q '.'; then
      echo "FAIL_AVX_FOUND in $1"; avx_hits "$1" | head -3; exit 1
    fi
    echo "NO_AVX_OK $1"
  else
    echo "SKIP_NO_OBJDUMP"
  fi
}
echo "== musl baseline build =="
rm -rf zig-out
"$ZIG_BIN" build -Dtarget=x86_64-linux-musl -Dcpu=baseline
file zig-out/bin/st-server
check_no_avx zig-out/bin/st-server
echo "== gnu baseline build =="
rm -rf zig-out
"$ZIG_BIN" build -Dtarget=x86_64-linux-gnu -Dcpu=baseline
file zig-out/bin/st-server
check_no_avx zig-out/bin/st-server
echo "MUSL+GNU BUILD OK"
