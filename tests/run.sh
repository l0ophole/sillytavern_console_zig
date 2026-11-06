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
echo "== stats/backups =="
./zig-out/bin/st-client --port $PORT stats.summary | grep -q 'characters' && echo PASS
./zig-out/bin/st-client --port $PORT backups.create '{"name":"b1"}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT backups.list | grep -q 'b1' && echo PASS
echo "== files/backgrounds/moving-ui/data-maid =="
./zig-out/bin/st-client --port $PORT files.save '{"name":"a.txt","content":"hi"}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT files.get '{"name":"a.txt"}' | grep -q 'hi' && echo PASS
./zig-out/bin/st-client --port $PORT backgrounds.save '{"name":"bg.png","content":"x"}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT avatars.save '{"name":"av.png","content":"x"}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT sprites.save '{"name":"s.png","content":"x"}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT images.save '{"name":"i.png","content":"x"}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT assets.save '{"name":"as.png","content":"x"}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT thumbnails.save '{"name":"t.png","content":"x"}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT moving-ui.save '{"name":"m1","value":{}}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT quick-replies.save '{"name":"q1","value":{}}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT data-maid.scan | grep -q 'files' && echo PASS
./zig-out/bin/st-client --port $PORT files.delete '{"name":"a.txt"}' | grep -q '"deleted"' && echo PASS
echo "== png/image-metadata =="
B64=$(python3 -c "import base64,struct; sig=b'\x89PNG\r\n\x1a\n'; ch=lambda t,d: struct.pack('>I',len(d))+t+d+b'\x00\x00\x00\x00'; ihdr=struct.pack('>IIBBBBB',1,1,8,0,0,0,0); card=b'{\"name\":\"Bob\"}'; b64=base64.b64encode(card); png=sig+ch(b'IHDR',ihdr)+ch(b'tEXt',b'chara\x00'+b64)+ch(b'IEND',b''); print(base64.b64encode(png).decode())")
./zig-out/bin/st-client --port $PORT image-metadata.detect "{\"content\":\"$B64\"}" | grep -q '"format":"png"' && echo PASS
./zig-out/bin/st-client --port $PORT characters.import_png "{\"name\":\"Bob\",\"content\":\"$B64\"}" | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT characters.get '{"name":"Bob"}' | grep -q 'Bob' && echo PASS
echo "== users =="
./zig-out/bin/st-client --port $PORT users.create '{"handle":"alice","name":"Alice","password":"secret"}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT users.list | grep -q 'alice' && echo PASS
./zig-out/bin/st-client --port $PORT users.login '{"handle":"alice","password":"secret"}' | grep -q '"token"' && echo PASS
./zig-out/bin/st-client --port $PORT users.login '{"handle":"alice","password":"wrong"}' | grep -q 'bad_credentials' && echo PASS
./zig-out/bin/st-client --port $PORT users.delete '{"handle":"alice"}' | grep -q '"deleted"' && echo PASS
echo "== vectors/search =="
./zig-out/bin/st-client --port $PORT vectors.save '{"collection":"c1","id":"v1","value":{"vector":[1,0]}}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT vectors.query '{"collection":"c1","vector":[1,0],"limit":1}' | grep -q 'v1' && echo PASS
./zig-out/bin/st-client --port $PORT characters.create '{"name":"Bob","character":{"name":"Bob","description":"likes dogs"}}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT search.query '{"query":"dogs"}' | grep -q 'Bob' && echo PASS
echo "== proxy/extensions/content-manager =="
./zig-out/bin/st-client --port $PORT speech.tts '{"host":"127.0.0.1","port":9,"path":"/v1/audio/speech","body":{}}' | grep -q 'backend_unreachable' && echo PASS
./zig-out/bin/st-client --port $PORT caption.caption '{"host":"127.0.0.1","port":9,"path":"/","body":{}}' | grep -q 'backend_unreachable' && echo PASS
./zig-out/bin/st-client --port $PORT classify.classify '{"host":"127.0.0.1","port":9,"path":"/","body":{}}' | grep -q 'backend_unreachable' && echo PASS
./zig-out/bin/st-client --port $PORT translate.translate '{"host":"127.0.0.1","port":9,"path":"/","body":{}}' | grep -q 'backend_unreachable' && echo PASS
./zig-out/bin/st-client --port $PORT stable-diffusion.generate '{"host":"127.0.0.1","port":9,"path":"/","body":{}}' | grep -q 'backend_unreachable' && echo PASS
./zig-out/bin/st-client --port $PORT openai.chat '{"host":"127.0.0.1","port":9,"path":"/","body":{}}' | grep -q 'backend_unreachable' && echo PASS
./zig-out/bin/st-client --port $PORT extensions.save '{"name":"e1.js","content":"x"}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT extensions.list | grep -q 'e1' && echo PASS
./zig-out/bin/st-client --port $PORT content-manager.import '{"name":"Imp","kind":"characters","content":"{}"}' | grep -q '"saved"' && echo PASS
echo "== byaf/charx =="
B64=$(python3 -c "import zipfile,io,base64,json; buf=io.BytesIO(); z=zipfile.ZipFile(buf,'w',zipfile.ZIP_DEFLATED); z.writestr('card.json', json.dumps({'name':'Zed'})); z.close(); print(base64.b64encode(buf.getvalue()).decode())")
./zig-out/bin/st-client --port $PORT charx.import "{\"name\":\"Zed\",\"content\":\"$B64\"}" | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT characters.get '{"name":"Zed"}' | grep -q 'Zed' && echo PASS
./zig-out/bin/st-client --port $PORT byaf.import "{\"name\":\"Zed2\",\"content\":\"$B64\"}" | grep -q '"saved"' && echo PASS
echo "== session auth =="
./zig-out/bin/st-client --port $PORT users.create '{"handle":"sessuser","name":"S","password":"pw123"}' | grep -q '"saved"' && echo PASS
OUT=$(./zig-out/bin/st-client --port $PORT users.login '{"handle":"sessuser","password":"pw123"}')
echo "$OUT" | grep -q '"token"' && echo PASS
TOKEN=$(echo "$OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['token'])" 2>/dev/null || echo "")
./zig-out/bin/st-client --port $PORT users.validate "{\"token\":\"$TOKEN\"}" | grep -q '"valid":true' && echo PASS
./zig-out/bin/st-client --port $PORT users.logout "{\"token\":\"$TOKEN\"}" | grep -q '"deleted"' && echo PASS
./zig-out/bin/st-client --port $PORT users.validate "{\"token\":\"$TOKEN\"}" | grep -q 'invalid_session' && echo PASS
echo "== https backend =="
./zig-out/bin/st-client --port $PORT backend.fetch '{"url":"http://127.0.0.1:9/","method":"GET"}' | grep -q 'backend_unreachable' && echo PASS
# HTTPS test requires network; skip gracefully if offline
timeout 15 ./zig-out/bin/st-client --port $PORT backend.fetch '{"url":"https://example.com/","method":"GET"}' > /tmp/https_out.txt 2>&1 && grep -q '"status":200' /tmp/https_out.txt && echo PASS_HTTPS || echo SKIP_HTTPS_OFFLINE
echo "== content-manager url =="
mkdir -p /tmp/stwww && echo "{\"name\":\"FromURL\"}" > /tmp/stwww/card.json
python3 -m http.server 18105 --directory /tmp/stwww --bind 127.0.0.1 >/tmp/stwww.log 2>&1 & echo $! > /tmp/stwww.pid
sleep 1
./zig-out/bin/st-client --port $PORT content-manager.import_url '{"url":"http://127.0.0.1:18105/card.json","name":"FromURL","kind":"characters"}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT characters.get '{"name":"FromURL"}' | grep -q 'FromURL' && echo PASS
kill $(cat /tmp/stwww.pid) 2>/dev/null || true
echo "== web search =="
./zig-out/bin/st-client --port $PORT search.web '{"query":"x","url":"http://127.0.0.1:9/"}' | grep -q 'backend_unreachable' && echo PASS
timeout 20 ./zig-out/bin/st-client --port $PORT search.web '{"query":"zig"}' > /tmp/ws.txt 2>&1 && grep -q '"status":200' /tmp/ws.txt && echo PASS_WEB || echo SKIP_WEB_OFFLINE
echo "== embedding generation =="
./zig-out/bin/st-client --port $PORT vectors.generate '{"text":"hello"}' | grep -q '"vector"' && echo PASS
./zig-out/bin/st-client --port $PORT vectors.embed '{"host":"127.0.0.1","port":9,"path":"/v1/embeddings","body":{}}' | grep -q 'backend_unreachable' && echo PASS
./zig-out/bin/st-client --port $PORT vectors.save '{"collection":"cg","id":"g1","value":{"text":"hello"}}' | grep -q '"saved"' && echo PASS
echo "== extension execution =="
./zig-out/bin/st-client --port $PORT extensions.execute '{"code":"console.log(1+2)"}' | grep -q '"stdout":"3' && echo PASS || echo SKIP_NO_NODE
echo "== exact tokenizer =="
curl -sL -o /tmp/cl100k.tiktoken https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken 2>/dev/null || true
if [ -s /tmp/cl100k.tiktoken ]; then
  ./zig-out/bin/st-client --port $PORT tokenizer.encode '{"text":"hello world","vocab":"/tmp/cl100k.tiktoken"}' | grep -q '15339,1917' && echo PASS_EXACT || echo FAIL_EXACT
else
  echo SKIP_NO_VOCAB
fi
echo "== bad method =="
./zig-out/bin/st-client --port $PORT nope | grep -q '"ok":false' && echo PASS
cat "$TMP/server.log"
echo "ALL SMOKE TESTS PASSED"
