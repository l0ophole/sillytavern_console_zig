#!/bin/sh
# Verify musl binary runs on Alpine and Zig 0.15 builds+runs inside Alpine.
# Requires docker with alpine:3.20 image. Work dirs are mktemp-based
# (no hard-coded paths); Zig tarball cache lives in
# ${ST_ZIG_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/st-zig}.
set -eu
cd "$(dirname "$0")/.."
ZIG_BIN="${ZIG:-}"
if [ -z "$ZIG_BIN" ]; then
  if command -v zig >/dev/null 2>&1; then ZIG_BIN=zig;
  elif [ -x "$HOME/.local/zig/zig" ]; then ZIG_BIN="$HOME/.local/zig/zig";
  else echo "FATAL: zig not found (set ZIG)" >&2; exit 1; fi
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CACHE_DIR="${ST_ZIG_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/st-zig}"
echo "== musl build on host =="
"$ZIG_BIN" build -Dtarget=x86_64-linux-musl -Dcpu=baseline
mkdir -p "$WORK/alpine_test"
cp zig-out/bin/st-server zig-out/bin/st-client "$WORK/alpine_test/"
echo "== run musl binary in Alpine container =="
docker run --rm -v "$WORK/alpine_test:/st:ro" alpine:3.20 sh -c '/st/st-server --port 18080 --data-dir /tmp/data > /tmp/s.log 2>&1 & sleep 1; /st/st-client --port 18080 ping; kill %1'
echo "== build Zig 0.15 inside Alpine =="
# Prefer host-cached tarball (avoids flaky in-container download and host
# /tmp quota issues); fall back to downloading on the host if no cache.
if [ -f "$CACHE_DIR/zig.tar.xz" ]; then
  echo "using cached Zig tarball ($CACHE_DIR/zig.tar.xz)"
else
  mkdir -p "$CACHE_DIR"
  curl -fsSL -o "$CACHE_DIR/zig.tar.xz" https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz
  echo "downloaded Zig tarball to cache"
fi
CACHE_ARGS="-v $CACHE_DIR/zig.tar.xz:/cache/zig.tar.xz:ro"
cat > "$WORK/alpine_build.sh" <<'EOS'
set -eu
mkdir -p /opt/zig && tar -xJf /cache/zig.tar.xz -C /opt/zig --strip-components=1
mkdir -p /tmp/build && cp -r /src/src /src/build.zig /tmp/build/ && cd /tmp/build
/opt/zig/zig build test && echo UNIT_PASS
/opt/zig/zig build && echo BUILD_PASS
./zig-out/bin/st-server --port 18081 --data-dir /tmp/data > /tmp/s.log 2>&1 &
sleep 2
./zig-out/bin/st-client --port 18081 ping
kill %1
EOS
docker run --rm -v "$PWD:/src:ro" $CACHE_ARGS -v "$WORK/alpine_build.sh:/build.sh:ro" alpine:3.20 sh /build.sh
echo "ALPINE VERIFIED"
