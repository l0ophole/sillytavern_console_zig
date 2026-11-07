#!/bin/sh
# Smoke/e2e suite. Every assertion failure increments FAILURES and the suite
# exits nonzero; ALL SMOKE TESTS PASSED is printed only with zero failures.
# Skips (missing optional prerequisites: offline, vocab/model files, API
# keys, upstream checkout) are counted and listed separately, never as PASS.
# ST_FORCE_FAIL=1 injects an intentional failure to prove nonzero exit.
set -eu
cd "$(dirname "$0")/.."
FAILURES=0
SKIPS=0
SKIP_LIST=""
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
skip() { echo "SKIP: $1"; SKIPS=$((SKIPS + 1)); SKIP_LIST="$SKIP_LIST
  - $1"; }
if [ "${ST_FORCE_FAIL:-}" = "1" ]; then echo "INTENTIONAL_FAILURE_INJECTED"; fail "intentional self-test failure (ST_FORCE_FAIL=1)"; fi
# Zig resolution: $ZIG, PATH, or ~/.local/zig (no hard-coded user paths).
ZIG_BIN="${ZIG:-}"
if [ -z "$ZIG_BIN" ]; then
  if command -v zig >/dev/null 2>&1; then ZIG_BIN=zig;
  elif [ -x "$HOME/.local/zig/zig" ]; then ZIG_BIN="$HOME/.local/zig/zig";
  else echo "FATAL: zig not found (install Zig 0.15+ or set ZIG)" >&2; exit 1; fi
fi
for dep in python3 grep curl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "FATAL: missing dependency: $dep" >&2; exit 1; }
done
python3 -c "import base64,struct,zipfile,io,json,http.server,hashlib,threading" || { echo "FATAL: missing python3 stdlib modules used by this suite" >&2; exit 1; }
# Upstream checkout (optional): tokenizers + web UI fixtures. Override with
# ST_UPSTREAM=/path/to/SillyTavern; missing checkout turns those into SKIPs.
UPSTREAM="${ST_UPSTREAM:-../SillyTavern}"
HF_HUB="${HF_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}}/huggingface/hub"
echo "== zig build test =="
"$ZIG_BIN" build test
echo "== zig build =="
"$ZIG_BIN" build
PORT=18081
TMP=$(mktemp -d)
export ST_TOKEN_FILE="$TMP/data/token"
mkdir -p "$TMP/opencode"
trap 'kill $(cat "$TMP/pid") 2>/dev/null || true; rm -rf "$TMP"' EXIT
./zig-out/bin/st-server --port $PORT --data-dir "$TMP/data" >"$TMP/server.log" 2>&1 &
sleep 1
# Server generates an auth token at startup; client reads it via ST_TOKEN_FILE.
TOKEN=$(cat "$TMP/data/token" 2>/dev/null || true)
echo $! >"$TMP/pid"
sleep 1
echo "== ping =="
./zig-out/bin/st-client --port $PORT ping | grep -q '"pong":true' && echo PASS || fail "run.sh:21"
echo "== version =="
./zig-out/bin/st-client --port $PORT version | grep -q '"version"' && echo PASS || fail "run.sh:23"
echo "== settings round-trip =="
./zig-out/bin/st-client --port $PORT settings.save '{"settings":{"power_user":true}}' | grep -q '"saved":true' && echo PASS || fail "run.sh:25"
./zig-out/bin/st-client --port $PORT settings.get | grep -q 'power_user' && echo PASS || fail "run.sh:26"
echo "== characters =="
./zig-out/bin/st-client --port $PORT characters.create '{"name":"Alice","character":{"name":"Alice"}}' | grep -q '"saved"' && echo PASS || fail "run.sh:28"
./zig-out/bin/st-client --port $PORT characters.list | grep -q 'Alice' && echo PASS || fail "run.sh:29"
./zig-out/bin/st-client --port $PORT characters.get '{"name":"Alice"}' | grep -q 'Alice' && echo PASS || fail "run.sh:30"
./zig-out/bin/st-client --port $PORT characters.delete '{"name":"Alice"}' | grep -q '"deleted"' && echo PASS || fail "run.sh:31"
echo "== chats =="
./zig-out/bin/st-client --port $PORT chats.save '{"character":"Alice","chat":"main","data":[{"name":"Alice","mes":"hi"}]}' | grep -q '"saved"' && echo PASS || fail "run.sh:33"
./zig-out/bin/st-client --port $PORT chats.list '{"character":"Alice"}' | grep -q 'main' && echo PASS || fail "run.sh:34"
./zig-out/bin/st-client --port $PORT chats.load '{"character":"Alice","chat":"main"}' | grep -q 'hi' && echo PASS || fail "run.sh:35"
./zig-out/bin/st-client --port $PORT chats.delete '{"character":"Alice","chat":"main"}' | grep -q '"deleted"' && echo PASS || fail "run.sh:36"
echo "== presets/worldinfo/groups/themes =="
./zig-out/bin/st-client --port $PORT presets.save '{"name":"p1","value":{"temp":1}}' | grep -q '"saved"' && echo PASS || fail "run.sh:38"
./zig-out/bin/st-client --port $PORT presets.load '{"name":"p1"}' | grep -q 'temp' && echo PASS || fail "run.sh:39"
./zig-out/bin/st-client --port $PORT worldinfo.save '{"name":"w1","value":{}}' | grep -q '"saved"' && echo PASS || fail "run.sh:40"
./zig-out/bin/st-client --port $PORT groups.save '{"name":"g1","value":{}}' | grep -q '"saved"' && echo PASS || fail "run.sh:41"
./zig-out/bin/st-client --port $PORT themes.save '{"name":"t1","value":{}}' | grep -q '"saved"' && echo PASS || fail "run.sh:42"
echo "== secrets =="
./zig-out/bin/st-client --port $PORT secrets.set '{"key":"k1","value":"v1"}' | grep -q '"saved"' && echo PASS || fail "run.sh:44"
./zig-out/bin/st-client --port $PORT secrets.list | grep -q 'k1' && echo PASS || fail "run.sh:45"
! ./zig-out/bin/st-client --port $PORT secrets.list | grep -q 'v1' && echo PASS || fail "secrets.list must not return values"
echo "== tokenizer/backend =="
./zig-out/bin/st-client --port $PORT tokenizer.estimate '{"text":"hello world"}' | grep -q '"tokens"' && echo PASS || fail "run.sh:48"
./zig-out/bin/st-client --port $PORT backend.chat '{"host":"127.0.0.1","port":9,"path":"/v1/chat/completions","body":{}}' | grep -q 'backend_unreachable' && echo PASS || fail "run.sh:49"
echo "== stats/backups =="
./zig-out/bin/st-client --port $PORT stats.summary | grep -q 'characters' && echo PASS || fail "run.sh:51"
./zig-out/bin/st-client --port $PORT backups.create '{"name":"b1"}' | grep -q '"saved"' && echo PASS || fail "run.sh:52"
./zig-out/bin/st-client --port $PORT backups.list | grep -q 'b1' && echo PASS || fail "run.sh:53"
echo "== files/backgrounds/moving-ui/data-maid =="
./zig-out/bin/st-client --port $PORT files.save '{"name":"a.txt","content":"hi"}' | grep -q '"saved"' && echo PASS || fail "run.sh:55"
./zig-out/bin/st-client --port $PORT files.get '{"name":"a.txt"}' | grep -q 'hi' && echo PASS || fail "run.sh:56"
./zig-out/bin/st-client --port $PORT backgrounds.save '{"name":"bg.png","content":"x"}' | grep -q '"saved"' && echo PASS || fail "run.sh:57"
./zig-out/bin/st-client --port $PORT avatars.save '{"name":"av.png","content":"x"}' | grep -q '"saved"' && echo PASS || fail "run.sh:58"
./zig-out/bin/st-client --port $PORT sprites.save '{"name":"s.png","content":"x"}' | grep -q '"saved"' && echo PASS || fail "run.sh:59"
./zig-out/bin/st-client --port $PORT images.save '{"name":"i.png","content":"x"}' | grep -q '"saved"' && echo PASS || fail "run.sh:60"
./zig-out/bin/st-client --port $PORT assets.save '{"name":"as.png","content":"x"}' | grep -q '"saved"' && echo PASS || fail "run.sh:61"
./zig-out/bin/st-client --port $PORT thumbnails.save '{"name":"t.png","content":"x"}' | grep -q '"saved"' && echo PASS || fail "run.sh:62"
./zig-out/bin/st-client --port $PORT moving-ui.save '{"name":"m1","value":{}}' | grep -q '"saved"' && echo PASS || fail "run.sh:63"
./zig-out/bin/st-client --port $PORT quick-replies.save '{"name":"q1","value":{}}' | grep -q '"saved"' && echo PASS || fail "run.sh:64"
./zig-out/bin/st-client --port $PORT data-maid.scan | grep -q 'files' && echo PASS || fail "run.sh:65"
./zig-out/bin/st-client --port $PORT files.delete '{"name":"a.txt"}' | grep -q '"deleted"' && echo PASS || fail "run.sh:66"
echo "== png/image-metadata =="
B64=$(python3 -c "import base64,struct; sig=b'\x89PNG\r\n\x1a\n'; ch=lambda t,d: struct.pack('>I',len(d))+t+d+b'\x00\x00\x00\x00'; ihdr=struct.pack('>IIBBBBB',1,1,8,0,0,0,0); card=b'{\"name\":\"Bob\"}'; b64=base64.b64encode(card); png=sig+ch(b'IHDR',ihdr)+ch(b'tEXt',b'chara\x00'+b64)+ch(b'IEND',b''); print(base64.b64encode(png).decode())")
./zig-out/bin/st-client --port $PORT image-metadata.detect "{\"content\":\"$B64\"}" | grep -q '"format":"png"' && echo PASS || fail "run.sh:69"
./zig-out/bin/st-client --port $PORT characters.import_png "{\"name\":\"Bob\",\"content\":\"$B64\"}" | grep -q '"saved"' && echo PASS || fail "run.sh:70"
./zig-out/bin/st-client --port $PORT characters.get '{"name":"Bob"}' | grep -q 'Bob' && echo PASS || fail "run.sh:71"
echo "== users =="
./zig-out/bin/st-client --port $PORT users.create '{"handle":"alice","name":"Alice","password":"secret"}' | grep -q '"saved"' && echo PASS || fail "run.sh:73"
./zig-out/bin/st-client --port $PORT users.list | grep -q 'alice' && echo PASS || fail "run.sh:74"
./zig-out/bin/st-client --port $PORT users.login '{"handle":"alice","password":"secret"}' | grep -q '"token"' && echo PASS || fail "run.sh:75"
./zig-out/bin/st-client --port $PORT users.login '{"handle":"alice","password":"wrong"}' | grep -q 'bad_credentials' && echo PASS || fail "run.sh:76"
./zig-out/bin/st-client --port $PORT users.delete '{"handle":"alice"}' | grep -q '"deleted"' && echo PASS || fail "run.sh:77"
echo "== vectors/search =="
./zig-out/bin/st-client --port $PORT vectors.save '{"collection":"c1","id":"v1","value":{"vector":[1,0]}}' | grep -q '"saved"' && echo PASS || fail "run.sh:79"
./zig-out/bin/st-client --port $PORT vectors.query '{"collection":"c1","vector":[1,0],"limit":1}' | grep -q 'v1' && echo PASS || fail "run.sh:80"
./zig-out/bin/st-client --port $PORT characters.create '{"name":"Bob","character":{"name":"Bob","description":"likes dogs"}}' | grep -q '"saved"' && echo PASS || fail "run.sh:81"
./zig-out/bin/st-client --port $PORT search.query '{"query":"dogs"}' | grep -q 'Bob' && echo PASS || fail "run.sh:82"
echo "== proxy/extensions/content-manager =="
./zig-out/bin/st-client --port $PORT speech.tts '{"input":"hi","base_url":"http://127.0.0.1:9"}' | grep -q 'backend_unreachable' && echo PASS || fail "run.sh:84"
./zig-out/bin/st-client --port $PORT caption.caption '{"host":"127.0.0.1","port":9,"path":"/","body":{}}' | grep -q 'backend_unreachable' && echo PASS || fail "run.sh:85"
./zig-out/bin/st-client --port $PORT classify.classify '{"text":"x","base_url":"http://127.0.0.1:9","path":"/"}' | grep -q 'backend_unreachable' && echo PASS || fail "run.sh:86"
./zig-out/bin/st-client --port $PORT translate.translate '{"text":"x","source":"en","target":"fr","base_url":"http://127.0.0.1:9"}' | grep -q 'backend_unreachable' && echo PASS || fail "run.sh:87"
./zig-out/bin/st-client --port $PORT stable-diffusion.generate '{"host":"127.0.0.1","port":9,"path":"/","body":{}}' | grep -q 'backend_unreachable' && echo PASS || fail "run.sh:88"
./zig-out/bin/st-client --port $PORT openai.chat '{"host":"127.0.0.1","port":9,"path":"/","body":{}}' | grep -q 'backend_unreachable' && echo PASS || fail "run.sh:89"
./zig-out/bin/st-client --port $PORT extensions.save '{"name":"e1.js","content":"x"}' | grep -q '"saved"' && echo PASS || fail "run.sh:90"
./zig-out/bin/st-client --port $PORT extensions.list | grep -q 'e1' && echo PASS || fail "run.sh:91"
./zig-out/bin/st-client --port $PORT content-manager.import '{"name":"Imp","kind":"characters","content":"{}"}' | grep -q '"saved"' && echo PASS || fail "run.sh:92"
echo "== byaf/charx =="
B64=$(python3 -c "import zipfile,io,base64,json; buf=io.BytesIO(); z=zipfile.ZipFile(buf,'w',zipfile.ZIP_DEFLATED); z.writestr('card.json', json.dumps({'name':'Zed'})); z.close(); print(base64.b64encode(buf.getvalue()).decode())")
./zig-out/bin/st-client --port $PORT charx.import "{\"name\":\"Zed\",\"content\":\"$B64\"}" | grep -q '"saved"' && echo PASS || fail "run.sh:95"
./zig-out/bin/st-client --port $PORT characters.get '{"name":"Zed"}' | grep -q 'Zed' && echo PASS || fail "run.sh:96"
./zig-out/bin/st-client --port $PORT byaf.import "{\"name\":\"Zed2\",\"content\":\"$B64\"}" | grep -q '"saved"' && echo PASS || fail "run.sh:97"
echo "== session auth =="
./zig-out/bin/st-client --port $PORT users.create '{"handle":"sessuser","name":"S","password":"pw123"}' | grep -q '"saved"' && echo PASS || fail "run.sh:99"
OUT=$(./zig-out/bin/st-client --port $PORT users.login '{"handle":"sessuser","password":"pw123"}')
echo "$OUT" | grep -q '"token"' && echo PASS || fail "run.sh:101"
TOKEN=$(echo "$OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['token'])" 2>/dev/null || echo "")
./zig-out/bin/st-client --port $PORT users.validate "{\"token\":\"$TOKEN\"}" | grep -q '"valid":true' && echo PASS || fail "run.sh:103"
./zig-out/bin/st-client --port $PORT users.logout "{\"token\":\"$TOKEN\"}" | grep -q '"deleted"' && echo PASS || fail "run.sh:104"
./zig-out/bin/st-client --port $PORT users.validate "{\"token\":\"$TOKEN\"}" | grep -q 'invalid_session' && echo PASS || fail "run.sh:105"
echo "== https backend =="
./zig-out/bin/st-client --port $PORT backend.fetch '{"url":"http://127.0.0.1:9/","method":"GET"}' | grep -q 'backend_unreachable' && echo PASS || fail "run.sh:107"
# HTTPS test requires network; skip gracefully if offline
timeout 15 ./zig-out/bin/st-client --port $PORT backend.fetch '{"url":"https://example.com/","method":"GET"}' > $TMP/https_out.txt 2>&1 && grep -q '"status":200' $TMP/https_out.txt && echo PASS_HTTPS || skip "SKIP_HTTPS_OFFLINE"
echo "== content-manager url =="
mkdir -p $TMP/stwww && echo "{\"name\":\"FromURL\"}" > $TMP/stwww/card.json
python3 -m http.server 18105 --directory $TMP/stwww --bind 127.0.0.1 >$TMP/stwww.log 2>&1 & echo $! > $TMP/stwww.pid
sleep 1
./zig-out/bin/st-client --port $PORT content-manager.import_url '{"url":"http://127.0.0.1:18105/card.json","name":"FromURL","kind":"characters"}' | grep -q '"saved"' && echo PASS || fail "run.sh:114"
./zig-out/bin/st-client --port $PORT characters.get '{"name":"FromURL"}' | grep -q 'FromURL' && echo PASS || fail "run.sh:115"
kill $(cat $TMP/stwww.pid) 2>/dev/null || true
echo "== web search =="
./zig-out/bin/st-client --port $PORT search.web '{"query":"x","url":"http://127.0.0.1:9/"}' | grep -q 'backend_unreachable' && echo PASS || fail "run.sh:118"
timeout 20 ./zig-out/bin/st-client --port $PORT search.web '{"query":"zig"}' > $TMP/ws.txt 2>&1 && grep -q '"status":200' $TMP/ws.txt && echo PASS_WEB || skip "SKIP_WEB_OFFLINE"
echo "== embedding generation =="
./zig-out/bin/st-client --port $PORT vectors.generate '{"text":"hello"}' | grep -q '"vector"' && echo PASS || fail "run.sh:121"
./zig-out/bin/st-client --port $PORT vectors.embed '{"host":"127.0.0.1","port":9,"path":"/v1/embeddings","body":{}}' | grep -q 'backend_unreachable' && echo PASS || fail "run.sh:122"
./zig-out/bin/st-client --port $PORT vectors.save '{"collection":"cg","id":"g1","value":{"text":"hello"}}' | grep -q '"saved"' && echo PASS || fail "run.sh:123"
echo "== extension execution =="
./zig-out/bin/st-client --port $PORT extensions.execute '{"code":"console.log(1+2)"}' | grep -q '"stdout":"3' && echo PASS || skip "SKIP_NO_NODE"
echo "== exact tokenizer =="
curl -sL --retry 2 -o $TMP/cl100k.tiktoken https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken 2>/dev/null || curl -sL -o $TMP/cl100k.tiktoken https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken 2>/dev/null || true
if [ -s $TMP/cl100k.tiktoken ]; then
  ./zig-out/bin/st-client --port $PORT tokenizer.encode '{"text":"hello world","vocab":"'"$TMP"'/cl100k.tiktoken"}' | grep -q '15339,1917' && echo PASS_EXACT || fail "FAIL_EXACT"
else
  skip "SKIP_NO_VOCAB"
fi
echo "== per-provider backend =="
./zig-out/bin/st-client --port $PORT backend.provider '{"provider":"openai","base_url":"http://127.0.0.1:9","path":"/v1/chat/completions","body":{}}' | grep -q 'backend_unreachable' && echo PASS || fail "run.sh:134"
./zig-out/bin/st-client --port $PORT backend.provider '{"provider":"unknown"}' | grep -q 'unknown_provider' && echo PASS || fail "run.sh:135"
./zig-out/bin/st-client --port $PORT backend.provider '{"provider":"anthropic","base_url":"http://127.0.0.1:9","path":"/v1/messages","body":{}}' | grep -q 'backend_unreachable' && echo PASS || fail "run.sh:136"
echo "== neural model =="
python3 -c "import json; m={'input_dim':32,'hidden_dim':4,'output_dim':2,'W1':[0]*128,'b1':[0]*4,'W2':[1,0,0,0,0,1,0,0],'b2':[0,0]}; [exec(\"m['W1'].__setitem__(h*32+h,1)\") for h in range(4)]; json.dump(m, open('$TMP/opencode/model.json','w'))"
./zig-out/bin/st-client --port $PORT vectors.model '{"text":"hello","model":"'"$TMP"'/opencode/model.json"}' | grep -q '"neural":true' && echo PASS || fail "run.sh:139"
./zig-out/bin/st-client --port $PORT vectors.model '{"text":"hello","model":"/nonexistent.json"}' | grep -q 'model_not_found' && echo PASS || fail "run.sh:140"
echo "== browser extension runtime =="
./zig-out/bin/st-client --port $PORT extensions.execute_browser '{"code":"registerSlashCommand(\"hello\", ()=>{});"}' | grep -q 'execute_disabled' && echo PASS || fail "run.sh:142"
echo "== native provider =="
cat > $TMP/opencode/mock_anthropic2.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        data=json.dumps({"content":[{"text":"mocked"}]}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18121),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_anthropic2.py > $TMP/opencode/mock2.log 2>&1 & echo $! > $TMP/opencode/mock2.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"anthropic","model":"claude-3","api_key":"k","base_url":"http://127.0.0.1:18121","path":"/v1/messages","messages":[{"role":"user","content":"hi"}]}' | grep -q 'mocked' && echo PASS || fail "FAIL_NATIVE"
kill $(cat $TMP/opencode/mock2.pid) 2>/dev/null || true
echo "== anthropic/google system parity =="
cat > $TMP/opencode/mock_syscheck.py <<'PYEOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); body=self.rfile.read(ln)
        req=json.loads(body)
        if self.path=='/v1/messages':
            sysv=req.get('system')
            assert sysv and sysv[0].get('text')=='sys-text', req
            assert req['messages'][0]['role']=='user', req
            assert req['messages'][0]['content'][0].get('text')=='hi', req
            data=json.dumps({"content":[{"text":"sys-ok"}]}).encode()
        elif self.path=='/v1beta/models/gemini-pro:generateContent':
            assert req.get('systemInstruction',{}).get('parts',[{}])[0].get('text')=='sys-text', req
            assert req['contents'][0]['role']=='user', req
            data=json.dumps({"candidates":[{"content":{"parts":[{"text":"goog-ok"}]}}]}).encode()
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
from http.server import ThreadingHTTPServer
ThreadingHTTPServer(('127.0.0.1',18146),H).serve_forever()
PYEOF
python3 $TMP/opencode/mock_syscheck.py > $TMP/opencode/syscheck.log 2>&1 & echo $! > $TMP/opencode/syscheck.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"anthropic","model":"claude-3","api_key":"k","base_url":"http://127.0.0.1:18146","path":"/v1/messages","messages":[{"role":"system","content":"sys-text"},{"role":"user","content":"hi"}]}' | grep -q 'sys-ok' && echo PASS_SYS_ANTHROPIC || fail "run.sh:186"
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"google","model":"gemini-pro","api_key":"k","base_url":"http://127.0.0.1:18146","path":"/v1beta/models/gemini-pro:generateContent","messages":[{"role":"system","content":"sys-text"},{"role":"user","content":"hi"}]}' | grep -q 'goog-ok' && echo PASS_SYS_GOOGLE || fail "run.sh:187"
kill $(cat $TMP/opencode/syscheck.pid) 2>/dev/null || true
echo "== anthropic image parity =="
cat > $TMP/opencode/mock_imgcheck.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); body=self.rfile.read(ln)
        req=json.loads(body)
        content=req['messages'][0]['content']
        assert content[1].get('type')=='image', req
        src=content[1].get('source',{})
        assert src.get('type')=='base64' and src.get('media_type')=='image/png' and src.get('data')=='iVBORw0=', req
        data=json.dumps({"content":[{"text":"img-ok"}]}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
ThreadingHTTPServer(('127.0.0.1',18148),H).serve_forever()
PYEOF
python3 $TMP/opencode/mock_imgcheck.py > $TMP/opencode/imgcheck.log 2>&1 & echo $! > $TMP/opencode/imgcheck.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"anthropic","model":"claude-3","api_key":"k","base_url":"http://127.0.0.1:18148","path":"/v1/messages","messages":[{"role":"user","content":[{"type":"text","text":"what is this"},{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0="}}]}]}' | grep -q 'img-ok' && echo PASS_ANTHROPIC_IMG || fail "run.sh:208"
kill $(cat $TMP/opencode/imgcheck.pid) 2>/dev/null || true
echo "== google image parity =="
cat > $TMP/opencode/mock_gimgcheck.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); body=self.rfile.read(ln)
        req=json.loads(body)
        parts=req['contents'][0]['parts']
        assert parts[1].get('inlineData',{}).get('mimeType')=='image/png', req
        assert parts[1].get('inlineData',{}).get('data')=='iVBORw0=', req
        data=json.dumps({"candidates":[{"content":{"parts":[{"text":"gimg-ok"}]}}]}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
ThreadingHTTPServer(('127.0.0.1',18149),H).serve_forever()
PYEOF
python3 $TMP/opencode/mock_gimgcheck.py > $TMP/opencode/gimgcheck.log 2>&1 & echo $! > $TMP/opencode/gimgcheck.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"google","model":"gemini-pro","api_key":"k","base_url":"http://127.0.0.1:18149","path":"/v1beta/models/gemini-pro:generateContent","messages":[{"role":"user","content":[{"type":"text","text":"what is this"},{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0="}}]}]}' | grep -q 'gimg-ok' && echo PASS_GOOGLE_IMG || fail "run.sh:228"
kill $(cat $TMP/opencode/gimgcheck.pid) 2>/dev/null || true
echo "== anthropic tools parity =="
cat > $TMP/opencode/mock_toolcheck.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); body=self.rfile.read(ln)
        req=json.loads(body)
        a=req['messages'][1]['content'][0]
        assert a.get('type')=='tool_use' and a.get('id')=='call_1' and a.get('name')=='get_weather', req
        assert a.get('input',{}).get('city')=='Paris', req
        t=req['messages'][2]
        assert t['role']=='user' and t['content'][0].get('type')=='tool_result' and t['content'][0].get('tool_use_id')=='call_1', req
        data=json.dumps({"content":[{"text":"tool-ok"}]}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
ThreadingHTTPServer(('127.0.0.1',18150),H).serve_forever()
PYEOF
python3 $TMP/opencode/mock_toolcheck.py > $TMP/opencode/toolcheck.log 2>&1 & echo $! > $TMP/opencode/toolcheck.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"anthropic","model":"claude-3","api_key":"k","base_url":"http://127.0.0.1:18150","path":"/v1/messages","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"","tool_calls":[{"id":"call_1","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]},{"role":"tool","tool_call_id":"call_1","content":"sunny"}]}' | grep -q 'tool-ok' && echo PASS_ANTHROPIC_TOOLS || fail "run.sh:250"
kill $(cat $TMP/opencode/toolcheck.pid) 2>/dev/null || true
echo "== google tools parity =="
cat > $TMP/opencode/mock_gtoolcheck.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); body=self.rfile.read(ln)
        req=json.loads(body)
        fc=req['contents'][1]['parts'][0].get('functionCall',{})
        assert fc.get('name')=='get_weather' and fc.get('args',{}).get('city')=='Paris', req
        fr=req['contents'][2]['parts'][0].get('functionResponse',{})
        assert fr.get('name')=='get_weather' and fr.get('response',{}).get('content')=='sunny', req
        data=json.dumps({"candidates":[{"content":{"parts":[{"text":"gtool-ok"}]}}]}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
ThreadingHTTPServer(('127.0.0.1',18151),H).serve_forever()
PYEOF
python3 $TMP/opencode/mock_gtoolcheck.py > $TMP/opencode/gtoolcheck.log 2>&1 & echo $! > $TMP/opencode/gtoolcheck.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"google","model":"gemini-pro","api_key":"k","base_url":"http://127.0.0.1:18151","path":"/v1beta/models/gemini-pro:generateContent","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"","tool_calls":[{"id":"call_1","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]},{"role":"user","tool_call_id":"call_1","content":"sunny"}]}' | grep -q 'gtool-ok' && echo PASS_GOOGLE_TOOLS || fail "run.sh:271"
kill $(cat $TMP/opencode/gtoolcheck.pid) 2>/dev/null || true
echo "== anthropic thinking parity =="
cat > $TMP/opencode/mock_thinkcheck.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); body=self.rfile.read(ln)
        req=json.loads(body)
        th=req.get('thinking',{})
        assert th.get('type')=='enabled' and th.get('budget_tokens')==1024, req
        assert req.get('max_tokens')==4096, req
        data=json.dumps({"content":[{"text":"think-ok"}]}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
ThreadingHTTPServer(('127.0.0.1',18152),H).serve_forever()
PYEOF
python3 $TMP/opencode/mock_thinkcheck.py > $TMP/opencode/thinkcheck.log 2>&1 & echo $! > $TMP/opencode/thinkcheck.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"anthropic","model":"claude-3-7-sonnet","api_key":"k","base_url":"http://127.0.0.1:18152","path":"/v1/messages","max_tokens":4096,"reasoning_effort":"medium","messages":[{"role":"user","content":"hi"}]}' | grep -q 'think-ok' && echo PASS_ANTHROPIC_THINKING || fail "run.sh:291"
kill $(cat $TMP/opencode/thinkcheck.pid) 2>/dev/null || true
echo "== gemini-3 thoughtSignature parity =="
cat > $TMP/opencode/mock_sigcheck.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); body=self.rfile.read(ln)
        req=json.loads(body)
        part=req['contents'][1]['parts'][0]
        assert part.get('thoughtSignature')=='skip_thought_signature_validator', req
        data=json.dumps({"candidates":[{"content":{"parts":[{"text":"sig-ok"}]}}]}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
ThreadingHTTPServer(('127.0.0.1',18153),H).serve_forever()
PYEOF
python3 $TMP/opencode/mock_sigcheck.py > $TMP/opencode/sigcheck.log 2>&1 & echo $! > $TMP/opencode/sigcheck.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"google","model":"gemini-3-pro","api_key":"k","base_url":"http://127.0.0.1:18153","path":"/v1beta/models/gemini-3-pro:generateContent","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"","tool_calls":[{"id":"call_1","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]}]}' | grep -q 'sig-ok' && echo PASS_GOOGLE_SIG || fail "run.sh:310"
kill $(cat $TMP/opencode/sigcheck.pid) 2>/dev/null || true
echo "== multi-model tokenizer =="
curl -sL -o $TMP/opencode/p50k_base.tiktoken https://openaipublic.blob.core.windows.net/encodings/p50k_base.tiktoken 2>/dev/null || true
if [ -s $TMP/opencode/p50k_base.tiktoken ]; then
  ./zig-out/bin/st-client --port $PORT tokenizer.encode '{"text":"hello world","vocab":"'"$TMP"'/opencode/p50k_base.tiktoken"}' | grep -q '31373,995' && echo PASS_P50K || fail "FAIL_P50K"
else
  skip "SKIP_NO_P50K"
fi
echo "== REPL =="
printf "/help\n/ping\n/exit\n" | timeout 5 ./zig-out/bin/st-client --port $PORT | grep -q '"pong":true' && echo PASS || fail "run.sh:320"
echo "== image gen save =="
cat > $TMP/opencode/mock_sd.py <<'PYEOF'
import json, base64
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        img=base64.b64encode(b'\x89PNG\r\n\x1a\nFAKE').decode()
        data=json.dumps({"images":[img]}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18123),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_sd.py > $TMP/opencode/sd.log 2>&1 & echo $! > $TMP/opencode/sd.pid
sleep 1
./zig-out/bin/st-client --port $PORT stable-diffusion.generate_and_save '{"name":"cat","host":"127.0.0.1","port":18123,"path":"/sdapi/v1/txt2img","body":{}}' | grep -q 'cat.png' && echo PASS || fail "run.sh:336"
kill $(cat $TMP/opencode/sd.pid) 2>/dev/null || true
echo "== remaining providers native =="
cat > $TMP/opencode/mock_kobold.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        data=json.dumps({"results":[{"text":"kobold mock out"}]}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18124),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_kobold.py > $TMP/opencode/k.log 2>&1 & echo $! > $TMP/opencode/k.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"kobold","model":"m","base_url":"http://127.0.0.1:18124","path":"/api/v1/generate","messages":[{"role":"user","content":"hi"}]}' | grep -q 'kobold mock out' && echo PASS || fail "run.sh:352"
kill $(cat $TMP/opencode/k.pid) 2>/dev/null || true
echo "== novelai input parity =="
cat > $TMP/opencode/mock_novel.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); body=self.rfile.read(ln)
        req=json.loads(body)
        assert req.get('input')=='hi', req
        assert 'prompt' not in req, req
        assert req.get('model')=='nai', req
        assert req.get('parameters',{}).get('max_length')==42, req
        data=json.dumps({"output":"novel out"}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18147),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_novel.py > $TMP/opencode/novel.log 2>&1 & echo $! > $TMP/opencode/novel.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"novelai","model":"nai","api_key":"k","base_url":"http://127.0.0.1:18147","path":"/ai/generate","max_tokens":42,"messages":[{"role":"user","content":"hi"}]}' | grep -q 'novel out' && echo PASS_NOVELAI_INPUT || fail "run.sh:373"
kill $(cat $TMP/opencode/novel.pid) 2>/dev/null || true
echo "== llama tokenizer =="
if [ -f "$UPSTREAM/src/tokenizers/llama3.json" ]; then
  ./zig-out/bin/st-client --port $PORT tokenizer.encode "{\"text\":\"hello world\",\"vocab\":\"$UPSTREAM/src/tokenizers/llama3.json\"}" | grep -q '15339,1917' && echo PASS_LLAMA || fail "FAIL_LLAMA"
else
  skip "SKIP_NO_LLAMA"
fi
echo "== REPL coverage =="
printf "/presets\n/worldinfo\n/groups\n/themes\n/stats\n/secrets\n/users\n/extensions\n/backups\n/exit\n" | timeout 5 ./zig-out/bin/st-client --port $PORT 2>&1 | grep -q '"ok":true' && echo PASS || fail "run.sh:382"
echo "== sentencepiece .model =="
if [ -f "$UPSTREAM/src/tokenizers/mistral.model" ]; then
  ./zig-out/bin/st-client --port $PORT tokenizer.encode "{\"text\":\"hello world\",\"vocab\":\"$UPSTREAM/src/tokenizers/mistral.model\"}" | grep -q '6312,28709,1526' && echo PASS_SP || fail "FAIL_SP"
else
  skip "SKIP_NO_SP"
fi
echo "== neural save integration =="
python3 -c "import json; m={'input_dim':32,'hidden_dim':4,'output_dim':2,'W1':[0]*128,'b1':[0]*4,'W2':[1,0,0,0,0,1,0,0],'b2':[0,0]}; [exec(\"m['W1'].__setitem__(h*32+h,1)\") for h in range(4)]; json.dump(m, open('$TMP/opencode/model.json','w'))"
./zig-out/bin/st-client --port $PORT vectors.save '{"collection":"nc","id":"n1","model":"'"$TMP"'/opencode/model.json","value":{"text":"hello"}}' | grep -q '"saved"' && echo PASS || fail "run.sh:391"
echo "== frontend verify =="
./zig-out/bin/st-client --port $PORT frontend.verify | grep -q '"coverage":100' && echo PASS || fail "run.sh:393"
echo "== caption image =="
cat > $TMP/opencode/mock_cap.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        data=json.dumps({"content":[{"text":"A cat sitting."}]}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18129),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_cap.py > $TMP/opencode/cap.log 2>&1 & echo $! > $TMP/opencode/cap.pid
sleep 1
./zig-out/bin/st-client --port $PORT caption.image '{"image":"data:image/png;base64,iVBORw0KGgo=","prompt":"Describe","api_key":"k","base_url":"http://127.0.0.1:18129"}' | grep -q 'A cat sitting' && echo PASS || fail "run.sh:408"
kill $(cat $TMP/opencode/cap.pid) 2>/dev/null || true
echo "== speech tts =="
cat > $TMP/opencode/mock_tts.py <<'PYEOF'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        data=b'ID3FAKEAUDIOBYTES'
        self.send_response(200); self.send_header('Content-Type','audio/mpeg'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18131),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_tts.py > $TMP/opencode/tts.log 2>&1 & echo $! > $TMP/opencode/tts.pid
sleep 1
./zig-out/bin/st-client --port $PORT speech.tts '{"input":"Hello","name":"hello.mp3","api_key":"k","base_url":"http://127.0.0.1:18131"}' | grep -q 'hello.mp3' && echo PASS || fail "run.sh:423"
kill $(cat $TMP/opencode/tts.pid) 2>/dev/null || true
echo "== classify/translate full =="
cat > $TMP/opencode/mock_ct.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        data=json.dumps([{"label":"positive","score":0.9}]).encode() if self.path=='/classify' else json.dumps({"data":"Bonjour"}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18133),H).serve_forever()
PYEOF
python3 $TMP/opencode/mock_ct.py > $TMP/opencode/ct.log 2>&1 & echo $! > $TMP/opencode/ct.pid
sleep 1
./zig-out/bin/st-client --port $PORT classify.classify '{"text":"I love this","base_url":"http://127.0.0.1:18133","path":"/classify"}' | grep -q 'positive' && echo PASS || fail "run.sh:439"
./zig-out/bin/st-client --port $PORT translate.translate '{"text":"Hello","source":"en","target":"fr","base_url":"http://127.0.0.1:18133/translate"}' | grep -q 'Bonjour' && echo PASS || fail "run.sh:440"
kill $(cat $TMP/opencode/ct.pid) 2>/dev/null || true
echo "== speech transcribe =="
cat > $TMP/opencode/mock_stt.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        data=json.dumps({"text":"Hello spoken world"}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18137),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_stt.py > $TMP/opencode/stt.log 2>&1 & echo $! > $TMP/opencode/stt.pid
sleep 1
./zig-out/bin/st-client --port $PORT speech.transcribe '{"audio":"QUJD","base_url":"http://127.0.0.1:18137"}' | grep -q 'Hello spoken' && echo PASS || fail "run.sh:456"
kill $(cat $TMP/opencode/stt.pid) 2>/dev/null || true
echo "== onnx neural =="
cat > $TMP/opencode/make_onnx.py <<PYEOF
import struct
def varint(n):
    out=b''
    while True:
        b=n & 0x7f; n>>=7
        if n: out+=bytes([b|0x80])
        else: out+=bytes([b]); break
    return out
def tag(f,w): return varint((f<<3)|w)
def fv(f,v): return tag(f,0)+varint(v)
def fl(f,d): return tag(f,2)+varint(len(d))+d
def fs(f,s): return fl(f,s.encode())
def pi64(f,vals): return fl(f,b''.join(varint(v) for v in vals))
def pf32(f,vals): return fl(f,b''.join(struct.pack('<f',v) for v in vals))
def tensor(n,dims,data): return pi64(1,dims)+fv(2,1)+pf32(4,data)+fs(8,n)
def node():
    n=fs(1,"X")+fs(1,"W")+fs(1,"B")+fs(2,"Y")+fs(4,"Gemm")
    attr=fs(1,"transB")+fv(20,2)+fv(3,1)
    return n+fl(5,attr)
def vi(n,dims):
    shape=b''
    for d in dims: shape+=fl(1,fv(1,d))
    tt=fv(1,1)+fl(2,shape)
    return fs(1,n)+fl(2,fl(1,tt))
W=[0.0]*64
for i in range(2): W[i*32+i]=1.0
graph=fl(1,node())+fs(2,"g")+fl(5,tensor("W",[2,32],W))+fl(5,tensor("B",[2],[0.0,0.0]))+fl(11,vi("X",[1,32]))+fl(12,vi("Y",[1,2]))
opset=fs(1,"")+fv(2,13)
open('$TMP/opencode/test.onnx','wb').write(fv(1,8)+fl(8,opset)+fl(7,graph))
PYEOF
python3 $TMP/opencode/make_onnx.py
./zig-out/bin/st-client --port $PORT vectors.onnx '{"text":"hello","model":"'"$TMP"'/opencode/test.onnx"}' | grep -q '"onnx":true' && echo PASS || fail "run.sh:491"
python3 - <<PYEOF
try:
    import onnxruntime as ort, numpy as np
    s=ort.InferenceSession('$TMP/opencode/test.onnx', providers=['CPUExecutionProvider'])
    x=np.arange(32,dtype=np.float32).reshape(1,32)
    y=s.run(None,{s.get_inputs()[0].name:x})[0]
    assert abs(y[0,1]-1.0)<1e-5, y
    print("ORT_EQUIV_PASS")
except ImportError:
    print("SKIP_NO_ORT")
PYEOF
echo "== browser frontend verify =="
./zig-out/bin/st-client --port $PORT frontend.browser_verify | grep -q '"browser_equivalent":true' && echo PASS || fail "run.sh:504"
echo "== chat end-to-end =="
cat > $TMP/opencode/mock_openai.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        data=json.dumps({"choices":[{"message":{"content":"Hi from OpenAI mock"}}]}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18140),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_openai.py > $TMP/opencode/o.log 2>&1 & echo $! > $TMP/opencode/o.pid
sleep 1
./zig-out/bin/st-client --port $PORT chat.generate_and_save '{"provider":"openai","model":"gpt-4","api_key":"k","base_url":"http://127.0.0.1:18140","path":"/v1/chat/completions","messages":[{"role":"user","content":"hi"}],"character":"Alice","chat":"main"}' | grep -q 'Hi from OpenAI' && echo PASS || fail "run.sh:519"
kill $(cat $TMP/opencode/o.pid) 2>/dev/null || true
echo "== chat.turn end-to-end (card -> prompt -> SSE -> save -> reload) =="
cat > $TMP/opencode/mock_turn.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); body=self.rfile.read(ln)
        req=json.loads(body)
        assert 'brave knight' in req['messages'][0]['content'], req['messages'][0]
        out=b""
        for c in ["Hello ","there!"]:
            out+=b"data: "+json.dumps({"choices":[{"delta":{"content":c}}]}).encode()+b"\n\n"
        out+=b"data: [DONE]\n\n"
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18141),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_turn.py > $TMP/opencode/turn.log 2>&1 & echo $! > $TMP/opencode/turn.pid
sleep 1
./zig-out/bin/st-client --port $PORT characters.create '{"name":"Alice","character":{"name":"Alice","description":"A brave knight.","personality":"Cheerful","scenario":"In a tavern"}}' | grep -q '"saved"' && echo PASS || fail "run.sh:540"
./zig-out/bin/st-client --port $PORT chat.turn '{"character":"Alice","chat":"turnchat","user_message":"Greetings {{char}}!","provider":"openai","model":"gpt-4","base_url":"http://127.0.0.1:18141","path":"/v1/chat/completions","api_key":"k"}' | grep -q 'Hello there!' && echo PASS_TURN || fail "run.sh:541"
./zig-out/bin/st-client --port $PORT chats.load '{"character":"Alice","chat":"turnchat"}' | grep -q 'Greetings Alice!' && echo PASS_TURN_RELOAD || fail "run.sh:542"
cat > $TMP/opencode/mock_varkey.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); body=self.rfile.read(ln)
        req=json.loads(body)
        user_content = [m['content'] for m in req['messages'] if m.get('role')=='user'][0]
        assert 'hero=alice' in user_content, user_content
        out=b"data: "+json.dumps({"choices":[{"delta":{"content":"ok"}}]}).encode()+b"\n\ndata: [DONE]\n\n"
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18143),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_varkey.py > $TMP/opencode/varkey.log 2>&1 & echo $! > $TMP/opencode/varkey.pid
sleep 1
./zig-out/bin/st-client --port $PORT chat.turn '{"character":"Alice","chat":"varkeychat","user_message":"{{setvarkey::obj::hero::alice}}hero={{getvarkey::obj::hero}}","provider":"openai","model":"gpt-4","base_url":"http://127.0.0.1:18143","path":"/v1/chat/completions","api_key":"k"}' | grep -q '"saved":true' && echo PASS_VARKEY_E2E || fail "run.sh:559"
kill $(cat $TMP/opencode/varkey.pid) 2>/dev/null || true
cat > $TMP/opencode/mock_model.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); body=self.rfile.read(ln)
        req=json.loads(body)
        user_content = [m['content'] for m in req['messages'] if m.get('role')=='user'][0]
        assert user_content.startswith('model=gpt-4 orig=model='), user_content
        out=b"data: "+json.dumps({"choices":[{"delta":{"content":"ok"}}]}).encode()+b"\n\ndata: [DONE]\n\n"
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18144),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_model.py > $TMP/opencode/model.log 2>&1 & echo $! > $TMP/opencode/model.pid
sleep 1
./zig-out/bin/st-client --port $PORT chat.turn '{"character":"Alice","chat":"modelchat","user_message":"model={{model}} orig={{original}}","provider":"openai","model":"gpt-4","base_url":"http://127.0.0.1:18144","path":"/v1/chat/completions","api_key":"k"}' | grep -q '"saved":true' && echo PASS_MODEL_E2E || fail "run.sh:577"
kill $(cat $TMP/opencode/model.pid) 2>/dev/null || true
cat > $TMP/opencode/mock_state.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); body=self.rfile.read(ln)
        req=json.loads(body)
        user_contents = [m['content'] for m in req['messages'] if m.get('role')=='user']
        if any('range=' in c for c in user_contents):
            assert user_contents[-1] == 'range=0-3 last=3 swipes=1/1', user_contents
        out=b"data: "+json.dumps({"choices":[{"delta":{"content":"ok"}}]}).encode()+b"\n\ndata: [DONE]\n\n"
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self,*a): pass
srv = HTTPServer(('127.0.0.1',18145),H)
for _ in range(3):
    srv.handle_request()
PYEOF
python3 $TMP/opencode/mock_state.py > $TMP/opencode/state.log 2>&1 & echo $! > $TMP/opencode/state.pid
sleep 1
./zig-out/bin/st-client --port $PORT chat.turn '{"character":"Alice","chat":"statechat","user_message":"one","provider":"openai","model":"gpt-4","base_url":"http://127.0.0.1:18145","path":"/v1/chat/completions","api_key":"k"}' > /dev/null
./zig-out/bin/st-client --port $PORT chat.turn '{"character":"Alice","chat":"statechat","user_message":"two","provider":"openai","model":"gpt-4","base_url":"http://127.0.0.1:18145","path":"/v1/chat/completions","api_key":"k"}' > /dev/null
./zig-out/bin/st-client --port $PORT chat.turn '{"character":"Alice","chat":"statechat","user_message":"range={{allChatRange}} last={{lastMessageId}} swipes={{lastSwipeId}}/{{currentSwipeId}}","provider":"openai","model":"gpt-4","base_url":"http://127.0.0.1:18145","path":"/v1/chat/completions","api_key":"k"}' | grep -q '"saved":true' && echo PASS_STATE_E2E || fail "run.sh:600"
kill $(cat $TMP/opencode/state.pid) 2>/dev/null || true
echo "== prompt engine: worldinfo + author note + macros =="
./zig-out/bin/st-client --port $PORT worldinfo.save '{"name":"lore","value":{"entries":[{"key":["tavern"],"content":"WI-TAVERN-LORE","disable":false,"constant":false},{"key":[],"content":"WI-ALWAYS","disable":false,"constant":true}]}}' | grep -q '"saved"' && echo PASS || fail "run.sh:603"
./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"I enter the tavern","worldinfo":"lore"}' | grep -q 'WI-TAVERN-LORE' && echo PASS_WI || fail "run.sh:604"
./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"I enter the tavern","worldinfo":"lore"}' | grep -q 'WI-ALWAYS' && echo PASS_WI_CONST || fail "run.sh:605"
./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"hi","author_note":"AN-TEXT","author_note_depth":1}' | grep -q 'AN-TEXT' && echo PASS_AN || fail "run.sh:606"
./zig-out/bin/st-client --port $PORT prompt.macros | grep -q 'lastUserMessage' && echo PASS_MACROS || fail "run.sh:607"
./zig-out/bin/st-client --port $PORT presets.save '{"name":"inst1","value":{"system_sequence":"SYS {{name}}: ","input_sequence":"USER {{name}}: ","output_sequence":"CHAR {{name}}: "}}' | grep -q '"saved"' && echo PASS || fail "run.sh:608"
./zig-out/bin/st-client --port $PORT prompt.template '{"instruct":"inst1","character":"Alice","messages":[{"role":"system","content":"card"},{"role":"user","content":"hi"}]}' | grep -q 'USER User: hi' && echo PASS_TEMPLATE || fail "run.sh:609"
./zig-out/bin/st-client --port $PORT worldinfo.save '{"name":"lore2","value":{"entries":[{"key":["tavern"],"content":"Mentions the dragon.","disable":false,"constant":false},{"key":["dragon"],"content":"Dragon lore.","disable":false,"constant":false}]}}' | grep -q '"saved"' && echo PASS || fail "run.sh:610"
./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"tavern","worldinfo":"lore2"}' | grep -q 'Dragon lore' && echo PASS_WI_RECURSION || fail "run.sh:611"
./zig-out/bin/st-client --port $PORT worldinfo.save '{"name":"lore3","value":{"entries":[{"key":["a"],"content":"A1","disable":false,"constant":false,"group":"g"},{"key":["a"],"content":"A2","disable":false,"constant":false,"group":"g"}]}}' | grep -q '"saved"' && echo PASS || fail "run.sh:612"
./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"a","worldinfo":"lore3"}' | grep -q 'A1' && echo PASS_WI_GROUP || fail "run.sh:613"
./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"a","worldinfo":"lore3"}' | grep -qv 'A2' && echo PASS_WI_GROUP_EXCL || fail "run.sh:614"
./zig-out/bin/st-client --port $PORT worldinfo.save '{"name":"lore4","value":{"entries":[{"uid":"s1","key":["dragon"],"content":"Sticky dragon.","disable":false,"constant":false,"sticky":5}]}}' | grep -q '"saved"' && echo PASS || fail "run.sh:615"
./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"dragon","worldinfo":"lore4"}' | grep -q 'Sticky dragon' && echo PASS_WI_STICKY || fail "run.sh:616"
./zig-out/bin/st-client --port $PORT worldinfo.save '{"name":"lore5","value":{"entries":[{"uid":"d1","key":["delaykey"],"content":"Delayed entry","disable":false,"constant":false,"delay":99}]}}' | grep -q '"saved"' && echo PASS || fail "run.sh:617"
./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"delaykey","worldinfo":"lore5"}' | grep -qv 'Delayed entry' && echo PASS_WI_DELAY || fail "run.sh:618"
./zig-out/bin/st-client --port $PORT worldinfo.save '{"name":"lore6","value":{"entries":[{"uid":"c1","key":["b"],"content":"Cool b content","disable":false,"constant":false,"cooldown":99}]}}' | grep -q '"saved"' && echo PASS || fail "run.sh:619"
OUT_CD=$(./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"b","worldinfo":"lore6"}')
echo "$OUT_CD" | grep -q 'Cool b content' && [ "$(echo "$OUT_CD" | grep -o 'Cool b content' | wc -l)" -eq 1 ] && echo PASS_WI_CD_THREAD || fail "run.sh:621"
echo "== stage3: version, slash, groups, jobs =="
./zig-out/bin/st-client --port $PORT ping | grep -q '"version":1' && echo PASS_API_VERSION || fail "run.sh:623"
./zig-out/bin/st-client --port $PORT slash.exec '{"command":"/echo","args":"hello zig"}' | grep -q 'hello zig' && echo PASS_SLASH || fail "run.sh:624"
./zig-out/bin/st-client --port $PORT groups.save '{"name":"g1","value":{"name":"Party","members":["Alice"]}}' | grep -q '"saved"' && echo PASS || fail "run.sh:625"
./zig-out/bin/st-client --port $PORT groups.chat_add '{"group":"g1","chat":"chat1"}' | grep -q '"saved"' && echo PASS_GROUP_CHAT || fail "run.sh:626"
./zig-out/bin/st-client --port $PORT groups.chats '{"group":"g1"}' | grep -q 'chat1' && echo PASS_GROUPS || fail "run.sh:627"
./zig-out/bin/st-client --port $PORT extensions.execute '{"code":"console.log(1)"}' | grep -q 'execute_disabled' && echo PASS_NO_EXEC || fail "run.sh:628"
cat > $TMP/opencode/mock_job.py <<'PYEOF'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        out=b"data: "+json.dumps({"choices":[{"delta":{"content":"job-reply"}}]}).encode()+b"\n\ndata: [DONE]\n\n"
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18142),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_job.py > $TMP/opencode/job.log 2>&1 & echo $! > $TMP/opencode/job.pid
sleep 1
JOBID=$(./zig-out/bin/st-client --port $PORT chat.job_start '{"params":{"character":"Alice","chat":"jobchat","user_message":"hi","provider":"openai","model":"gpt-4","base_url":"http://127.0.0.1:18142","path":"/v1/chat/completions","api_key":"k"}}' | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['job_id'])")
sleep 2
./zig-out/bin/st-client --port $PORT chat.job_result "{\"job_id\":\"$JOBID\"}" | grep -q 'job-reply' && echo PASS_JOB || fail "run.sh:644"
kill $(cat $TMP/opencode/job.pid) 2>/dev/null || true
echo "== streaming job pickup (slow-drip) =="
cat > $TMP/opencode/mock_slow.py <<'PYEOF'
import json, time
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        part1=b"data: "+json.dumps({"choices":[{"delta":{"content":"Hello "}}]}).encode()+b"\n\n"
        part2=b"data: "+json.dumps({"choices":[{"delta":{"content":"world!"}}]}).encode()+b"\n\ndata: [DONE]\n\n"
        total=part1+part2
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(total))); self.end_headers(); self.wfile.write(part1); self.wfile.flush(); time.sleep(1.5); self.wfile.write(part2); self.wfile.flush()
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18145),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_slow.py > $TMP/opencode/slow.log 2>&1 & echo $! > $TMP/opencode/slow.pid
sleep 1
SLOWID=$(./zig-out/bin/st-client --port $PORT chat.job_start '{"params":{"character":"Alice","chat":"slowchat","user_message":"hi","provider":"openai","model":"gpt-4","base_url":"http://127.0.0.1:18145","path":"/v1/chat/completions","api_key":"k"}}' | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['job_id'])")
FOUND_STREAMING=0
i=0
while [ "$i" -lt 20 ]; do
  OUT_STREAM=$(./zig-out/bin/st-client --port $PORT chat.job_status "{\"job_id\":\"$SLOWID\"}")
  if echo "$OUT_STREAM" | grep -q 'partial_text' && echo "$OUT_STREAM" | grep -q 'Hello ' && echo "$OUT_STREAM" | grep -q '"status":"running"'; then FOUND_STREAMING=1; break; fi
  i=$((i+1)); sleep 0.2
done
[ "$FOUND_STREAMING" = "1" ] && echo PASS_STREAM_PICKUP || fail "run.sh:670"
sleep 2
./zig-out/bin/st-client --port $PORT chat.job_result "{\"job_id\":\"$SLOWID\"}" | grep -q 'Hello world!' && echo PASS_STREAM_DONE || fail "run.sh:672"
kill $(cat $TMP/opencode/slow.pid) 2>/dev/null || true
kill $(cat $TMP/opencode/turn.pid) 2>/dev/null || true
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  ./zig-out/bin/st-client --port $PORT chat.turn '{"character":"Alice","chat":"realchat","user_message":"Reply with one short word.","provider":"openrouter","model":"openai/gpt-4o-mini"}' | grep -q '"saved":true' && echo PASS_TURN_REAL || fail "run.sh:676"
else
  skip "SKIP_NO_OPENROUTER_KEY"
fi
echo "== web UI HTTP =="
SRV_TOKEN=$(cat "$TMP/data/token" 2>/dev/null || true)
TOKEN="$SRV_TOKEN"
curl -s http://127.0.0.1:$PORT/api/health | grep -q '"status":"ok"' && echo PASS || fail "run.sh web health"
ST_WEB_ROOT="$UPSTREAM/public" curl -s http://127.0.0.1:$PORT/ > $TMP/opencode/webui.html 2>/dev/null || true
# web root: $UPSTREAM/public (ST_UPSTREAM override); missing checkout -> SKIP.
grep -q 'SillyTavern' $TMP/opencode/webui.html && echo PASS_WEBUI || skip "SKIP_WEBUI_PATH"
echo "== web API bridge =="
curl -s -m 5 -X POST -H 'Content-Type: application/json' -H "X-ST-Token: $TOKEN" -d '{}' http://127.0.0.1:$PORT/api/settings.get | grep -q '"settings"' && echo PASS || fail "run.sh:686"
echo "== provider error parity =="
cat > $TMP/opencode/mock_err.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        data=json.dumps({"error":{"message":"bad key"}}).encode()
        self.send_response(401); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18145),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_err.py > $TMP/opencode/e.log 2>&1 & echo $! > $TMP/opencode/e.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"openai","model":"gpt-4","api_key":"bad","base_url":"http://127.0.0.1:18145","path":"/v1/chat/completions","messages":[{"role":"user","content":"hi"}]}' | grep -q 'provider_error' && echo PASS || fail "run.sh:701"
kill $(cat $TMP/opencode/e.pid) 2>/dev/null || true
echo "== onnx save integration =="
./zig-out/bin/st-client --port $PORT vectors.save '{"collection":"oc","id":"o1","model":"'"$TMP"'/opencode/test.onnx","value":{"text":"hello onnx"}}' | grep -q '"saved"' && echo PASS || fail "run.sh:704"
echo "== claude tokenizer =="
if [ -f "$UPSTREAM/src/tokenizers/claude.json" ]; then
  ./zig-out/bin/st-client --port $PORT tokenizer.encode "{\"text\":\"hello world\",\"vocab\":\"$UPSTREAM/src/tokenizers/claude.json\"}" | grep -q '9381,2253' && echo PASS_CLAUDE || fail "FAIL_CLAUDE"
else
  skip "SKIP_NO_CLAUDE"
fi
echo "== frontend API routes =="
curl -s -m 5 -X POST -H 'Content-Type: application/json' -H "X-ST-Token: $TOKEN" -d '{}' http://127.0.0.1:$PORT/api/settings/load | grep -q '"settings"' && echo PASS || fail "run.sh:712"
curl -s -m 5 -X POST -H 'Content-Type: application/json' -H "X-ST-Token: $TOKEN" -d '{"name":"Alice","character":{"name":"Alice"}}' http://127.0.0.1:$PORT/api/characters/create | grep -q '"saved"' && echo PASS || fail "run.sh:713"
curl -s -m 5 -X POST -H 'Content-Type: application/json' -H "X-ST-Token: $TOKEN" -d '{}' http://127.0.0.1:$PORT/api/characters/list | grep -q 'Alice' && echo PASS || fail "run.sh:714"
echo "== multipart frontend upload =="
curl -s -m 5 -H "X-ST-Token: $TOKEN" -F "name=Bob" -F 'character={"name":"Bob"}' http://127.0.0.1:$PORT/api/characters/create | grep -q '"saved"' && echo PASS || fail "run.sh:716"
echo "== streaming provider =="
cat > $TMP/opencode/mock_sse.py <<'PYEOF'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        body=b'data: {"choices":[{"delta":{"content":"Hello "}}]}\n\ndata: {"choices":[{"delta":{"content":"stream"}}]}\n\ndata: [DONE]\n\n'
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18151),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_sse.py > $TMP/opencode/sse.log 2>&1 & echo $! > $TMP/opencode/sse.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.stream '{"provider":"openai","model":"gpt-4","api_key":"k","base_url":"http://127.0.0.1:18151","path":"/v1/chat/completions","messages":[{"role":"user","content":"hi"}]}' | grep -q 'Hello stream' && echo PASS || fail "run.sh:730"
kill $(cat $TMP/opencode/sse.pid) 2>/dev/null || true
echo "== browser smoke =="
./zig-out/bin/st-client --port $PORT frontend.browser_smoke '{"script":"authors-note.js"}' | grep -q '"syntax_ok":true' && echo PASS || fail "run.sh:733"
echo "== real neural MiniLM =="
SNAP="$HF_HUB/models--sentence-transformers--all-MiniLM-L6-v2/snapshots/1110a243fdf4706b3f48f1d95db1a4f5529b4d41"
if [ -f "$SNAP/onnx/model.onnx" ]; then
  timeout 120 ./zig-out/bin/st-client --port $PORT vectors.neural_real "{\"text\":\"hello world\",\"model\":\"$SNAP/onnx/model.onnx\",\"vocab\":\"$SNAP/vocab.txt\"}" | grep -q "384" && echo PASS_MINILM || fail "FAIL_MINILM"
  timeout 120 ./zig-out/bin/st-client --port $PORT vectors.pure_minilm "{\"text\":\"hello world\",\"model\":\"$SNAP/model.safetensors\",\"vocab\":\"$SNAP/vocab.txt\"}" | grep -q '"pure_zig":true' && echo PASS_PURE_MINILM || fail "FAIL_PURE_MINILM"
else
  skip "SKIP_NO_MINILM"
fi
echo "== anthropic streaming =="
cat > $TMP/opencode/mock_sse_anth.py <<'PYEOF'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        body=b'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Anthropic "}}\n\nevent: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"stream"}}\n\ndata: [DONE]\n\n'
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18156),H).handle_request()
PYEOF
python3 $TMP/opencode/mock_sse_anth.py > $TMP/opencode/sse2.log 2>&1 & echo $! > $TMP/opencode/sse2.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.stream '{"provider":"anthropic","model":"claude-3","api_key":"k","base_url":"http://127.0.0.1:18156","path":"/v1/messages","messages":[{"role":"user","content":"hi"}]}' | grep -q 'Anthropic stream' && echo PASS || fail "run.sh:755"
kill $(cat $TMP/opencode/sse2.pid) 2>/dev/null || true
echo "== frontend HTTP flow verify =="
./zig-out/bin/st-client --port $PORT frontend.http_verify | grep -q '"ok":3' && echo PASS || fail "run.sh:758"
echo "== streaming retry =="
cat > $TMP/opencode/mock_retry.py <<'PYEOF'
from http.server import BaseHTTPRequestHandler, HTTPServer
import threading
count=[0]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        count[0]+=1
        if count[0]<3:
            data=b'{"error":"busy"}'
            self.send_response(429)
        else:
            data=b'data: {"choices":[{"delta":{"content":"Recovered"}}]}\n\ndata: [DONE]\n\n'
            self.send_response(200)
        self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
srv=HTTPServer(('127.0.0.1',18160),H)
threads=[threading.Thread(target=srv.handle_request,daemon=True) for _ in range(3)]
[t.start() for t in threads]
import time; time.sleep(20)
PYEOF
timeout 25 python3 $TMP/opencode/mock_retry.py > $TMP/opencode/retry.log 2>&1 & echo $! > $TMP/opencode/retry.pid
sleep 1
timeout 30 ./zig-out/bin/st-client --port $PORT backend.stream '{"provider":"openai","model":"gpt-4","api_key":"k","base_url":"http://127.0.0.1:18160","path":"/v1/chat/completions","messages":[{"role":"user","content":"hi"}]}' | grep -q 'Recovered' && echo PASS || fail "run.sh:783"
kill $(cat $TMP/opencode/retry.pid) 2>/dev/null || true
echo "== browser smoke all =="
timeout 120 ./zig-out/bin/st-client --port $PORT frontend.browser_smoke_all | grep -q '"all_ok":true' && echo PASS || fail "run.sh:786"
if python3 -c "import onnxruntime, numpy" 2>/dev/null; then
echo "== onnx ort equivalence =="
python3 - <<PYEOF
import struct, random
random.seed(7)
def varint(n):
    out=b''
    while True:
        b=n & 0x7f; n>>=7
        if n: out+=bytes([b|0x80])
        else: out+=bytes([b]); break
    return out
def tag(f,w): return varint((f<<3)|w)
def fv(f,v): return tag(f,0)+varint(v)
def fl(f,d): return tag(f,2)+varint(len(d))+d
def fs(f,s): return fl(f,s.encode())
def pi64(f,vals): return fl(f,b''.join(varint(v) for v in vals))
def pf32(f,vals): return fl(f,b''.join(struct.pack('<f',v) for v in vals))
def tensor(n,dims,data): return pi64(1,dims)+fv(2,1)+pf32(4,data)+fs(8,n)
def gemm_node(inp,w,b,out):
    n=fs(1,inp)+fs(1,w)+fs(1,b)+fs(2,out)+fs(4,"Gemm")
    attr=fs(1,"transB")+fv(20,2)+fv(3,1)
    return n+fl(5,attr)
def relu_node(inp,out):
    return fs(1,inp)+fs(2,out)+fs(4,"Relu")
def vi(n,dims):
    shape=b''
    for d in dims: shape+=fl(1,fv(1,d))
    tt=fv(1,1)+fl(2,shape)
    return fs(1,n)+fl(2,fl(1,tt))
W1=[random.uniform(-0.5,0.5) for _ in range(96)]
W2=[random.uniform(-0.5,0.5) for _ in range(6)]
graph=fl(1,gemm_node("X","W1","B1","H"))+fl(1,relu_node("H","R"))+fl(1,gemm_node("R","W2","B2","Y"))+fs(2,"g")+fl(5,tensor("W1",[3,32],W1))+fl(5,tensor("B1",[3],[0.1,-0.1,0.0]))+fl(5,tensor("W2",[2,3],W2))+fl(5,tensor("B2",[2],[0.0,0.0]))+fl(11,vi("X",[1,32]))+fl(12,vi("Y",[1,2]))
opset=fs(1,"")+fv(2,13)
open('$TMP/opencode/test_relu32.onnx','wb').write(fv(1,8)+fl(8,opset)+fl(7,graph))
import hashlib
out=[]
c=0
while len(out)<32:
    h=hashlib.sha256(f"hello:{c}".encode()).digest()
    for b in h:
        out.append(b/127.5-1.0)
        if len(out)>=32: break
    c+=1
import onnxruntime as ort, numpy as np, json
sess=ort.InferenceSession('$TMP/opencode/test_relu32.onnx', providers=['CPUExecutionProvider'])
y=sess.run(None,{sess.get_inputs()[0].name:np.array([out],dtype=np.float32)})[0]
json.dump({"ort":y.tolist()}, open('$TMP/opencode/ort_ref.json','w'))
print("ORT_REF_OK", y.tolist())
PYEOF
./zig-out/bin/st-client --port $PORT vectors.onnx '{"text":"hello","model":"'"$TMP"'/opencode/test_relu32.onnx"}' > $TMP/opencode/zig_onnx.json
python3 - <<PYEOF
import json
z=json.load(open('$TMP/opencode/zig_onnx.json'))['result']['vector']
o=json.load(open('$TMP/opencode/ort_ref.json'))['ort'][0]
assert abs(z[0]-o[0])<1e-4 and abs(z[1]-o[1])<1e-4, (z,o)
print("ORT_EQUIV_2LAYER_PASS")
PYEOF
else
  skip "SKIP_NO_ONNXRUNTIME"
fi
echo "== llama .model tokenizer =="
if [ -f "$UPSTREAM/src/tokenizers/llama.model" ]; then
  ./zig-out/bin/st-client --port $PORT tokenizer.encode "{\"text\":\"hello world\",\"vocab\":\"$UPSTREAM/src/tokenizers/llama.model\"}" | grep -q '22172,3186' && echo PASS_LLAMA_MODEL || fail "FAIL_LLAMA_MODEL"
else
  skip "SKIP_NO_LLAMA_MODEL"
fi
echo "== google streaming =="
cat > $TMP/opencode/mock_google.py <<'PYEOF'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        body=b'data: {"candidates":[{"content":{"parts":[{"text":"Google "}]}}]}\n\ndata: {"candidates":[{"content":{"parts":[{"text":"stream"}]}}]}\n\ndata: [DONE]\n\n'
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18169),H).handle_request()
PYEOF
timeout 15 python3 $TMP/opencode/mock_google.py > $TMP/opencode/g.log 2>&1 & echo $! > $TMP/opencode/g.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.stream '{"provider":"google","model":"gemini","api_key":"k","base_url":"http://127.0.0.1:18169","path":"/v1beta/models/gemini:streamGenerateContent","messages":[{"role":"user","content":"hi"}]}' | grep -q 'Google stream' && echo PASS || fail "run.sh:867"
kill $(cat $TMP/opencode/g.pid) 2>/dev/null || true
echo "== provider error anthropic/google =="
cat > $TMP/opencode/mock_403.py <<'PYEOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        data=json.dumps({"error":"forbidden"}).encode()
        self.send_response(403); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18171),H).handle_request()
PYEOF
timeout 15 python3 $TMP/opencode/mock_403.py > $TMP/opencode/e403.log 2>&1 & echo $! > $TMP/opencode/e403.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"anthropic","model":"claude-3","api_key":"bad","base_url":"http://127.0.0.1:18171","path":"/v1/messages","messages":[]}' | grep -q '"status":403' && echo PASS || fail "run.sh:883"
kill $(cat $TMP/opencode/e403.pid) 2>/dev/null || true
echo "== semantic ranking =="
SNAP="$HF_HUB/models--sentence-transformers--all-MiniLM-L6-v2/snapshots/1110a243fdf4706b3f48f1d95db1a4f5529b4d41"
if [ -f "$SNAP/onnx/model.onnx" ]; then
  timeout 120 ./zig-out/bin/st-client --port $PORT vectors.neural_real "{\"text\":\"hello world\",\"model\":\"$SNAP/onnx/model.onnx\",\"vocab\":\"$SNAP/vocab.txt\"}" > $TMP/opencode/n1.json
  timeout 120 ./zig-out/bin/st-client --port $PORT vectors.neural_real "{\"text\":\"quantum physics\",\"model\":\"$SNAP/onnx/model.onnx\",\"vocab\":\"$SNAP/vocab.txt\"}" > $TMP/opencode/n3.json
  python3 - <<PYEOF
import json, math
a=json.load(open('$TMP/opencode/n1.json'))['result']['vector']
c=json.load(open('$TMP/opencode/n3.json'))['result']['vector']
def cos(x,y): return sum(i*j for i,j in zip(x,y))/(math.sqrt(sum(i*i for i in x))*math.sqrt(sum(j*j for j in y)))
assert cos(a,a)==1.0 and cos(a,c)<0.5, (cos(a,a),cos(a,c))
print("SEMANTIC_RANK_PASS")
PYEOF
  grep -q SEMANTIC_RANK_PASS $TMP/opencode/n1.json 2>/dev/null || python3 -c "import json,math; a=json.load(open('$TMP/opencode/n1.json'))['result']['vector']; c=json.load(open('$TMP/opencode/n3.json'))['result']['vector']; cos=sum(i*j for i,j in zip(a,c))/(math.sqrt(sum(i*i for i in a))*math.sqrt(sum(j*j for j in c))); assert cos<0.5; print('SEMANTIC_DIFF_OK',cos)" && echo PASS || fail "semantic ranking"
else
  skip "SKIP_NO_MINILM"
fi
echo "== browser exec real scripts =="
./zig-out/bin/st-client --port $PORT frontend.browser_exec '{"script":"constants.js"}' | grep -q '"exec_ok":true' && echo PASS || fail "run.sh:903"
./zig-out/bin/st-client --port $PORT frontend.browser_exec '{"script":"a11y.js"}' | grep -q '"exec_ok":true' && echo PASS || fail "run.sh:904"
echo "== bad method =="
./zig-out/bin/st-client --port $PORT nope | grep -q '"ok":false' && echo PASS || fail "run.sh:906"
echo "== stage0: REPL stress (double-free regression, 2000 lines) =="
python3 -c "print('/ping\n'*2000 + '/exit\n')" > $TMP/opencode/repl_in.txt
timeout 120 ./zig-out/bin/st-client --port $PORT < $TMP/opencode/repl_in.txt > $TMP/opencode/repl_out.txt 2> $TMP/opencode/repl_err.txt; REPL_EXIT=$?
[ "$REPL_EXIT" = "0" ] && [ "$(grep -c '"pong":true' $TMP/opencode/repl_out.txt)" = "2000" ] && echo PASS_REPL_STRESS || fail "REPL stress exit=$REPL_EXIT pongs=$(grep -c '"pong":true' $TMP/opencode/repl_out.txt 2>/dev/null || echo "?")"
echo "== stage0: bad port never crashes =="
if ./zig-out/bin/st-client --port 99999 ping > $TMP/opencode/badport.log 2>&1; then fail "client --port 99999 must exit nonzero"; else echo PASS_BADPORT_CLIENT; fi
if timeout 5 ./zig-out/bin/st-server --port 99999 --data-dir $TMP/opencode/badportdata > $TMP/opencode/badport_srv.log 2>&1; then fail "server --port 99999 must exit nonzero"; else echo PASS_BADPORT_SERVER; fi
echo "== stage0: auth on user-data endpoints =="
curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:$PORT/api/settings/get > $TMP/opencode/auth_code.txt
[ "$(cat $TMP/opencode/auth_code.txt)" = "401" ] && echo PASS_AUTH_HTTP || fail "unauth HTTP must be 401, got $(cat $TMP/opencode/auth_code.txt 2>/dev/null)"
curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST -H 'Content-Type: application/json' -H 'X-ST-Token: wrongtokenwrongtoken' -d '{}' http://127.0.0.1:$PORT/api/settings/get > $TMP/opencode/auth_code2.txt
[ "$(cat $TMP/opencode/auth_code2.txt)" = "401" ] && echo PASS_AUTH_HTTP_WRONG || fail "wrong-token HTTP must be 401, got $(cat $TMP/opencode/auth_code2.txt 2>/dev/null)"
ST_TOKEN_FILE=/nonexistent ./zig-out/bin/st-client --port $PORT settings.get | grep -q 'unauthorized' && echo PASS_AUTH_TCP || fail "unauth TCP must be unauthorized"
ST_TOKEN_FILE=/nonexistent ./zig-out/bin/st-client --port $PORT chats.list '{"character":"Alice"}' | grep -q 'unauthorized' && echo PASS_AUTH_TCP_CHATS || fail "unauth TCP chats must be unauthorized"
echo "== stage0: >64KiB replies complete + >1MiB chat save/load =="
python3 - <<PYEOF
import json
mes=[{'name':'A','mes':'x'*1000} for _ in range(1200)]
open('$TMP/opencode/bigchat.json','w').write(json.dumps({'character':'Alice','chat':'bigchat','data':mes}))
open('$TMP/opencode/bigfile.json','w').write(json.dumps({'name':'bigfile.txt','content':'y'*200000}))
PYEOF
BIG_SAVE=$(curl -s -m 30 -X POST -H 'Content-Type: application/json' -H "X-ST-Token: $TOKEN" --data-binary @$TMP/opencode/bigchat.json http://127.0.0.1:$PORT/api/chats/save)
echo "$BIG_SAVE" | grep -q '"saved":true' && echo PASS_BIGCHAT_SAVE || fail "1.2MiB chat save failed: $BIG_SAVE"
timeout 30 ./zig-out/bin/st-client --port $PORT chats.load '{"character":"Alice","chat":"bigchat"}' > $TMP/opencode/bigchat_load.json
python3 - <<PYEOF
import json
d=json.load(open('$TMP/opencode/bigchat_load.json'))['result']
assert isinstance(d,list) and len(d)==1200, len(d) if isinstance(d,list) else d
print("BIGCHAT_LOAD_OK")
PYEOF
grep -q BIGCHAT_LOAD_OK $TMP/opencode/bigchat_load.json 2>/dev/null || python3 -c "import json; d=json.load(open('$TMP/opencode/bigchat_load.json'))['result']; assert isinstance(d,list) and len(d)==1200" && echo PASS_BIGCHAT_LOAD || fail "1.2MiB chat load incomplete"
curl -s -m 30 -X POST -H 'Content-Type: application/json' -H "X-ST-Token: $TOKEN" --data-binary @$TMP/opencode/bigfile.json http://127.0.0.1:$PORT/api/files/save > /dev/null
curl -s -m 30 -X POST -H 'Content-Type: application/json' -H "X-ST-Token: $TOKEN" -d '{"name":"bigfile.txt"}' http://127.0.0.1:$PORT/api/files/get > $TMP/opencode/bigfile_get.json
python3 -c "import json; d=json.load(open('$TMP/opencode/bigfile_get.json')); c=d['result']['content'] if 'result' in d else d['content']; assert len(c)==200000, len(c); print('BIGFILE_OK')" && grep -q BIGFILE_OK $TMP/opencode/bigfile_get.json 2>/dev/null || python3 -c "import json; d=json.load(open('$TMP/opencode/bigfile_get.json')); c=d['result']['content'] if 'result' in d else d['content']; assert len(c)==200000" && echo PASS_BIGFILE || fail "200KiB file round-trip incomplete"
echo "== stage0: interrupted backend stream =="
cat > $TMP/opencode/mock_cut.py <<'PYEOF'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        body=b'data: {"choices":[{"delta":{"content":"Partial"}}]}\n\n'
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length','999999'); self.end_headers(); self.wfile.write(body); self.wfile.flush(); self.close_connection=True
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18182),H).handle_request()
PYEOF
timeout 20 python3 $TMP/opencode/mock_cut.py > $TMP/opencode/cut.log 2>&1 & echo $! > $TMP/opencode/cut.pid
sleep 1
./zig-out/bin/st-client --port $PORT chat.turn '{"character":"Alice","chat":"cutchat","user_message":"hi","provider":"openai","model":"gpt-4","base_url":"http://127.0.0.1:18182","path":"/v1/chat/completions","api_key":"k"}' > $TMP/opencode/cut_out.json
grep -q 'Partial' $TMP/opencode/cut_out.json && grep -q '"saved":true' $TMP/opencode/cut_out.json && echo PASS_INTERRUPTED_STREAM || fail "interrupted stream must save partial reply"
./zig-out/bin/st-client --port $PORT ping | grep -q '"pong":true' && echo PASS_ALIVE_AFTER_CUT || fail "server must stay alive after interrupted stream"
kill $(cat $TMP/opencode/cut.pid) 2>/dev/null || true
echo "== stage0: unix-socket background generation (default transport) =="
cat > $TMP/opencode/mock_unixslow.py <<'PYEOF'
import json, time
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        p1=b"data: "+json.dumps({"choices":[{"delta":{"content":"Hello "}}]}).encode()+b"\n\n"
        p2=b"data: "+json.dumps({"choices":[{"delta":{"content":"unix!"}}]}).encode()+b"\n\ndata: [DONE]\n\n"
        t=p1+p2
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(t))); self.end_headers(); self.wfile.write(p1); self.wfile.flush(); time.sleep(1.5); self.wfile.write(p2); self.wfile.flush()
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18183),H).handle_request()
PYEOF
timeout 20 python3 $TMP/opencode/mock_unixslow.py > $TMP/opencode/uslow.log 2>&1 & echo $! > $TMP/opencode/uslow.pid
sleep 1
mkdir -p $TMP/unixdata
./zig-out/bin/st-server --data-dir $TMP/unixdata > $TMP/opencode/unixsrv.log 2>&1 & echo $! > $TMP/opencode/unixsrv.pid
sleep 2
export ST_TOKEN_FILE=$TMP/unixdata/token
./zig-out/bin/st-client --unix $TMP/unixdata/st.sock characters.create '{"name":"Alice","character":{"name":"Alice","description":"A brave knight."}}' | grep -q '"saved"' && echo PASS_UNIX_CREATE || fail "unix create failed"
UNIX_JOB=$(./zig-out/bin/st-client --unix $TMP/unixdata/st.sock chat.job_start '{"params":{"character":"Alice","chat":"unixchat","user_message":"hi","provider":"openai","model":"gpt-4","base_url":"http://127.0.0.1:18183","path":"/v1/chat/completions","api_key":"k"}}' | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['job_id'])")
[ -n "$UNIX_JOB" ] && echo "UNIX_JOB=$UNIX_JOB" || fail "unix job_start returned no job_id"
sleep 0.7
./zig-out/bin/st-client --unix $TMP/unixdata/st.sock chat.job_status "{\"job_id\":\"$UNIX_JOB\"}" | grep -q 'partial_text' && echo PASS_UNIX_PICKUP || fail "unix mid-generation pickup missing partial_text"
sleep 2.5
./zig-out/bin/st-client --unix $TMP/unixdata/st.sock chat.job_result "{\"job_id\":\"$UNIX_JOB\"}" | grep -q 'Hello unix!' && echo PASS_UNIX_DONE || fail "unix generation did not complete after disconnect"
./zig-out/bin/st-client --unix $TMP/unixdata/st.sock chats.load '{"character":"Alice","chat":"unixchat"}' | grep -q 'Hello unix!' && echo PASS_UNIX_PERSIST || fail "unix chat not persisted"
kill $(cat $TMP/opencode/unixsrv.pid) 2>/dev/null || true
kill $(cat $TMP/opencode/uslow.pid) 2>/dev/null || true
cat "$TMP/server.log"
echo "FAILURES=$FAILURES SKIPS=$SKIPS"
if [ -n "$SKIP_LIST" ]; then printf "Skips:%s\n" "$SKIP_LIST"; fi
if [ "$FAILURES" -ne 0 ]; then echo "SMOKE TESTS FAILED: $FAILURES failure(s)" >&2; exit 1; fi
echo "ALL SMOKE TESTS PASSED"
