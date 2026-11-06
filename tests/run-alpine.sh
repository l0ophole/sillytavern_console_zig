#!/bin/sh
# Verify musl binary runs on Alpine and Zig 0.15 builds+runs inside Alpine.
# Requires docker with alpine:3.20 image.
set -eu
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/zig:$PATH"
echo "== musl build on host =="
zig build -Dtarget=x86_64-linux-musl -Dcpu=baseline
mkdir -p /rpf/tmp/opencode/alpine_test
cp zig-out/bin/st-server zig-out/bin/st-client /rpf/tmp/opencode/alpine_test/
echo "== run musl binary in Alpine container =="
docker run --rm -v /rpf/tmp/opencode/alpine_test:/st:ro alpine:3.20 sh -c '/st/st-server --port 18080 --data-dir /tmp/data > /tmp/s.log 2>&1 & sleep 1; /st/st-client --port 18080 ping; kill %1'
echo "== build Zig 0.15 inside Alpine =="
cat > /rpf/tmp/opencode/alpine_build.sh <<'EOS'
apk add --no-cache curl xz >/dev/null 2>&1
curl -fsSL -o /tmp/zig.tar.xz https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz
mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
mkdir -p /tmp/build && cp -r /src/src /src/build.zig /tmp/build/ && cd /tmp/build
/opt/zig/zig build test && echo UNIT_PASS
/opt/zig/zig build && echo BUILD_PASS
./zig-out/bin/st-server --port 18081 --data-dir /tmp/data > /tmp/s.log 2>&1 &
sleep 2
./zig-out/bin/st-client --port 18081 ping
kill %1
EOS
docker run --rm -v "$PWD:/src:ro" -v /rpf/tmp/opencode/alpine_build.sh:/build.sh:ro alpine:3.20 sh /build.sh
echo "ALPINE VERIFIED"
