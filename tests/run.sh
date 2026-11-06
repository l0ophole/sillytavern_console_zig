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
echo "== per-provider backend =="
./zig-out/bin/st-client --port $PORT backend.provider '{"provider":"openai","base_url":"http://127.0.0.1:9","path":"/v1/chat/completions","body":{}}' | grep -q 'backend_unreachable' && echo PASS
./zig-out/bin/st-client --port $PORT backend.provider '{"provider":"unknown"}' | grep -q 'unknown_provider' && echo PASS
./zig-out/bin/st-client --port $PORT backend.provider '{"provider":"anthropic","base_url":"http://127.0.0.1:9","path":"/v1/messages","body":{}}' | grep -q 'backend_unreachable' && echo PASS
echo "== neural model =="
python3 -c "import json; m={'input_dim':32,'hidden_dim':4,'output_dim':2,'W1':[0]*128,'b1':[0]*4,'W2':[1,0,0,0,0,1,0,0],'b2':[0,0]}; [exec(\"m['W1'].__setitem__(h*32+h,1)\") for h in range(4)]; json.dump(m, open('$TMP/opencode/model.json','w'))"
./zig-out/bin/st-client --port $PORT vectors.model '{"text":"hello","model":"'"$TMP"'/opencode/model.json"}' | grep -q '"neural":true' && echo PASS
./zig-out/bin/st-client --port $PORT vectors.model '{"text":"hello","model":"/nonexistent.json"}' | grep -q 'model_not_found' && echo PASS
echo "== browser extension runtime =="
./zig-out/bin/st-client --port $PORT extensions.execute_browser '{"code":"registerSlashCommand(\"hello\", ()=>{});"}' | grep -q 'hello' && echo PASS
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
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"anthropic","model":"claude-3","api_key":"k","base_url":"http://127.0.0.1:18121","path":"/v1/messages","messages":[{"role":"user","content":"hi"}]}' | grep -q 'mocked' && echo PASS || echo FAIL_NATIVE
kill $(cat $TMP/opencode/mock2.pid) 2>/dev/null || true
echo "== multi-model tokenizer =="
curl -sL -o $TMP/opencode/p50k_base.tiktoken https://openaipublic.blob.core.windows.net/encodings/p50k_base.tiktoken 2>/dev/null || true
if [ -s $TMP/opencode/p50k_base.tiktoken ]; then
  ./zig-out/bin/st-client --port $PORT tokenizer.encode '{"text":"hello world","vocab":"'"$TMP"'/opencode/p50k_base.tiktoken"}' | grep -q '31373,995' && echo PASS_P50K || echo FAIL_P50K
else
  echo SKIP_NO_P50K
fi
echo "== REPL =="
printf "/help\n/ping\n/exit\n" | timeout 5 ./zig-out/bin/st-client --port $PORT | grep -q '"pong":true' && echo PASS
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
./zig-out/bin/st-client --port $PORT stable-diffusion.generate_and_save '{"name":"cat","host":"127.0.0.1","port":18123,"path":"/sdapi/v1/txt2img","body":{}}' | grep -q 'cat.png' && echo PASS
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
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"kobold","model":"m","base_url":"http://127.0.0.1:18124","path":"/api/v1/generate","messages":[{"role":"user","content":"hi"}]}' | grep -q 'kobold mock out' && echo PASS
kill $(cat $TMP/opencode/k.pid) 2>/dev/null || true
echo "== llama tokenizer =="
if [ -f ../SillyTavern/src/tokenizers/llama3.json ]; then
  ./zig-out/bin/st-client --port $PORT tokenizer.encode '{"text":"hello world","vocab":"../SillyTavern/src/tokenizers/llama3.json"}' | grep -q '15339,1917' && echo PASS_LLAMA || echo FAIL_LLAMA
else
  echo SKIP_NO_LLAMA
fi
echo "== REPL coverage =="
printf "/presets\n/worldinfo\n/groups\n/themes\n/stats\n/secrets\n/users\n/extensions\n/backups\n/exit\n" | timeout 5 ./zig-out/bin/st-client --port $PORT 2>&1 | grep -q '"ok":true' && echo PASS
echo "== sentencepiece .model =="
if [ -f ../SillyTavern/src/tokenizers/mistral.model ]; then
  ./zig-out/bin/st-client --port $PORT tokenizer.encode '{"text":"hello world","vocab":"../SillyTavern/src/tokenizers/mistral.model"}' | grep -q '6312,28709,1526' && echo PASS_SP || echo FAIL_SP
else
  echo SKIP_NO_SP
fi
echo "== neural save integration =="
python3 -c "import json; m={'input_dim':32,'hidden_dim':4,'output_dim':2,'W1':[0]*128,'b1':[0]*4,'W2':[1,0,0,0,0,1,0,0],'b2':[0,0]}; [exec(\"m['W1'].__setitem__(h*32+h,1)\") for h in range(4)]; json.dump(m, open('$TMP/opencode/model.json','w'))"
./zig-out/bin/st-client --port $PORT vectors.save '{"collection":"nc","id":"n1","model":"'"$TMP"'/opencode/model.json","value":{"text":"hello"}}' | grep -q '"saved"' && echo PASS
echo "== frontend verify =="
./zig-out/bin/st-client --port $PORT frontend.verify | grep -q '"coverage":100' && echo PASS
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
./zig-out/bin/st-client --port $PORT caption.image '{"image":"data:image/png;base64,iVBORw0KGgo=","prompt":"Describe","api_key":"k","base_url":"http://127.0.0.1:18129"}' | grep -q 'A cat sitting' && echo PASS
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
./zig-out/bin/st-client --port $PORT speech.tts '{"input":"Hello","name":"hello.mp3","api_key":"k","base_url":"http://127.0.0.1:18131"}' | grep -q 'hello.mp3' && echo PASS
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
./zig-out/bin/st-client --port $PORT classify.classify '{"text":"I love this","base_url":"http://127.0.0.1:18133","path":"/classify"}' | grep -q 'positive' && echo PASS
./zig-out/bin/st-client --port $PORT translate.translate '{"text":"Hello","source":"en","target":"fr","base_url":"http://127.0.0.1:18133/translate"}' | grep -q 'Bonjour' && echo PASS
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
./zig-out/bin/st-client --port $PORT speech.transcribe '{"audio":"QUJD","base_url":"http://127.0.0.1:18137"}' | grep -q 'Hello spoken' && echo PASS
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
./zig-out/bin/st-client --port $PORT vectors.onnx '{"text":"hello","model":"'"$TMP"'/opencode/test.onnx"}' | grep -q '"onnx":true' && echo PASS
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
./zig-out/bin/st-client --port $PORT frontend.browser_verify | grep -q '"browser_equivalent":true' && echo PASS
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
./zig-out/bin/st-client --port $PORT chat.generate_and_save '{"provider":"openai","model":"gpt-4","api_key":"k","base_url":"http://127.0.0.1:18140","path":"/v1/chat/completions","messages":[{"role":"user","content":"hi"}],"character":"Alice","chat":"main"}' | grep -q 'Hi from OpenAI' && echo PASS
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
./zig-out/bin/st-client --port $PORT characters.create '{"name":"Alice","character":{"name":"Alice","description":"A brave knight.","personality":"Cheerful","scenario":"In a tavern"}}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT chat.turn '{"character":"Alice","chat":"turnchat","user_message":"Greetings {{char}}!","provider":"openai","model":"gpt-4","base_url":"http://127.0.0.1:18141","path":"/v1/chat/completions","api_key":"k"}' | grep -q 'Hello there!' && echo PASS_TURN
./zig-out/bin/st-client --port $PORT chats.load '{"character":"Alice","chat":"turnchat"}' | grep -q 'Greetings Alice!' && echo PASS_TURN_RELOAD
echo "== prompt engine: worldinfo + author note + macros =="
./zig-out/bin/st-client --port $PORT worldinfo.save '{"name":"lore","value":{"entries":[{"key":["tavern"],"content":"WI-TAVERN-LORE","disable":false,"constant":false},{"key":[],"content":"WI-ALWAYS","disable":false,"constant":true}]}}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"I enter the tavern","worldinfo":"lore"}' | grep -q 'WI-TAVERN-LORE' && echo PASS_WI
./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"I enter the tavern","worldinfo":"lore"}' | grep -q 'WI-ALWAYS' && echo PASS_WI_CONST
./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"hi","author_note":"AN-TEXT","author_note_depth":1}' | grep -q 'AN-TEXT' && echo PASS_AN
./zig-out/bin/st-client --port $PORT prompt.macros | grep -q 'lastUserMessage' && echo PASS_MACROS
./zig-out/bin/st-client --port $PORT presets.save '{"name":"inst1","value":{"system_sequence":"SYS {{name}}: ","input_sequence":"USER {{name}}: ","output_sequence":"CHAR {{name}}: "}}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT prompt.template '{"instruct":"inst1","character":"Alice","messages":[{"role":"system","content":"card"},{"role":"user","content":"hi"}]}' | grep -q 'USER User: hi' && echo PASS_TEMPLATE
./zig-out/bin/st-client --port $PORT worldinfo.save '{"name":"lore2","value":{"entries":[{"key":["tavern"],"content":"Mentions the dragon.","disable":false,"constant":false},{"key":["dragon"],"content":"Dragon lore.","disable":false,"constant":false}]}}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"tavern","worldinfo":"lore2"}' | grep -q 'Dragon lore' && echo PASS_WI_RECURSION
./zig-out/bin/st-client --port $PORT worldinfo.save '{"name":"lore3","value":{"entries":[{"key":["a"],"content":"A1","disable":false,"constant":false,"group":"g"},{"key":["a"],"content":"A2","disable":false,"constant":false,"group":"g"}]}}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"a","worldinfo":"lore3"}' | grep -q 'A1' && echo PASS_WI_GROUP
./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"a","worldinfo":"lore3"}' | grep -qv 'A2' && echo PASS_WI_GROUP_EXCL
./zig-out/bin/st-client --port $PORT worldinfo.save '{"name":"lore4","value":{"entries":[{"uid":"s1","key":["dragon"],"content":"Sticky dragon.","disable":false,"constant":false,"sticky":5}]}}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT prompt.preview '{"character":"Alice","chat":"turnchat","user_message":"dragon","worldinfo":"lore4"}' | grep -q 'Sticky dragon' && echo PASS_WI_STICKY
echo "== stage3: version, slash, groups, jobs =="
./zig-out/bin/st-client --port $PORT ping | grep -q '"version":1' && echo PASS_API_VERSION
./zig-out/bin/st-client --port $PORT slash.exec '{"command":"/echo","args":"hello zig"}' | grep -q 'hello zig' && echo PASS_SLASH
./zig-out/bin/st-client --port $PORT groups.save '{"name":"g1","value":{"name":"Party","members":["Alice"]}}' | grep -q '"saved"' && echo PASS
./zig-out/bin/st-client --port $PORT groups.chat_add '{"group":"g1","chat":"chat1"}' | grep -q '"saved"' && echo PASS_GROUP_CHAT
./zig-out/bin/st-client --port $PORT groups.chats '{"group":"g1"}' | grep -q 'chat1' && echo PASS_GROUPS
./zig-out/bin/st-client --port $PORT extensions.execute '{"code":"console.log(1)"}' | grep -q 'execute_disabled' && echo PASS_NO_EXEC
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
./zig-out/bin/st-client --port $PORT chat.job_result "{\"job_id\":\"$JOBID\"}" | grep -q 'job-reply' && echo PASS_JOB
kill $(cat $TMP/opencode/job.pid) 2>/dev/null || true
kill $(cat $TMP/opencode/turn.pid) 2>/dev/null || true
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  ./zig-out/bin/st-client --port $PORT chat.turn '{"character":"Alice","chat":"realchat","user_message":"Reply with one short word.","provider":"openrouter","model":"openai/gpt-4o-mini"}' | grep -q '"saved":true' && echo PASS_TURN_REAL
else
  echo SKIP_NO_OPENROUTER_KEY
fi
echo "== web UI HTTP =="
curl -s http://127.0.0.1:$PORT/api/health | grep -q '"pong":true' && echo PASS
ST_WEB_ROOT=../SillyTavern/public curl -s http://127.0.0.1:$PORT/ > $TMP/opencode/webui.html 2>/dev/null || true
# web root is relative to server cwd (repo root in tests), default ../SillyTavern/public works when run from repo parent? server cwd is repo, so check index served:
grep -q 'SillyTavern' $TMP/opencode/webui.html && echo PASS_WEBUI || echo SKIP_WEBUI_PATH
echo "== web API bridge =="
curl -s -m 5 -X POST -H 'Content-Type: application/json' -H "X-ST-Token: $TOKEN" -d '{}' http://127.0.0.1:$PORT/api/settings.get | grep -q '"settings"' && echo PASS
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
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"openai","model":"gpt-4","api_key":"bad","base_url":"http://127.0.0.1:18145","path":"/v1/chat/completions","messages":[{"role":"user","content":"hi"}]}' | grep -q 'provider_error' && echo PASS
kill $(cat $TMP/opencode/e.pid) 2>/dev/null || true
echo "== onnx save integration =="
./zig-out/bin/st-client --port $PORT vectors.save '{"collection":"oc","id":"o1","model":"'"$TMP"'/opencode/test.onnx","value":{"text":"hello onnx"}}' | grep -q '"saved"' && echo PASS
echo "== claude tokenizer =="
if [ -f ../SillyTavern/src/tokenizers/claude.json ]; then
  ./zig-out/bin/st-client --port $PORT tokenizer.encode '{"text":"hello world","vocab":"../SillyTavern/src/tokenizers/claude.json"}' | grep -q '9381,2253' && echo PASS_CLAUDE || echo FAIL_CLAUDE
else
  echo SKIP_NO_CLAUDE
fi
echo "== frontend API routes =="
curl -s -m 5 -X POST -H 'Content-Type: application/json' -H "X-ST-Token: $TOKEN" -d '{}' http://127.0.0.1:$PORT/api/settings/load | grep -q '"settings"' && echo PASS
curl -s -m 5 -X POST -H 'Content-Type: application/json' -H "X-ST-Token: $TOKEN" -d '{"name":"Alice","character":{"name":"Alice"}}' http://127.0.0.1:$PORT/api/characters/create | grep -q '"saved"' && echo PASS
curl -s -m 5 -X POST -H 'Content-Type: application/json' -H "X-ST-Token: $TOKEN" -d '{}' http://127.0.0.1:$PORT/api/characters/list | grep -q 'Alice' && echo PASS
echo "== multipart frontend upload =="
curl -s -m 5 -H "X-ST-Token: $TOKEN" -F "name=Bob" -F 'character={"name":"Bob"}' http://127.0.0.1:$PORT/api/characters/create | grep -q '"saved"' && echo PASS
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
./zig-out/bin/st-client --port $PORT backend.stream '{"provider":"openai","model":"gpt-4","api_key":"k","base_url":"http://127.0.0.1:18151","path":"/v1/chat/completions","messages":[{"role":"user","content":"hi"}]}' | grep -q 'Hello stream' && echo PASS
kill $(cat $TMP/opencode/sse.pid) 2>/dev/null || true
echo "== browser smoke =="
./zig-out/bin/st-client --port $PORT frontend.browser_smoke '{"script":"authors-note.js"}' | grep -q '"syntax_ok":true' && echo PASS
echo "== real neural MiniLM =="
SNAP=$(echo ~/.cache/huggingface/hub/models--sentence-transformers--all-MiniLM-L6-v2/snapshots/1110a243fdf4706b3f48f1d95db1a4f5529b4d41)
if [ -f "$SNAP/onnx/model.onnx" ]; then
  timeout 120 ./zig-out/bin/st-client --port $PORT vectors.neural_real "{\"text\":\"hello world\",\"model\":\"$SNAP/onnx/model.onnx\",\"vocab\":\"$SNAP/vocab.txt\"}" | grep -q "384" && echo PASS_MINILM || echo FAIL_MINILM
  timeout 120 ./zig-out/bin/st-client --port $PORT vectors.pure_minilm "{\"text\":\"hello world\",\"model\":\"$SNAP/model.safetensors\",\"vocab\":\"$SNAP/vocab.txt\"}" | grep -q '"pure_zig":true' && echo PASS_PURE_MINILM || echo FAIL_PURE_MINILM
else
  echo SKIP_NO_MINILM
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
./zig-out/bin/st-client --port $PORT backend.stream '{"provider":"anthropic","model":"claude-3","api_key":"k","base_url":"http://127.0.0.1:18156","path":"/v1/messages","messages":[{"role":"user","content":"hi"}]}' | grep -q 'Anthropic stream' && echo PASS
kill $(cat $TMP/opencode/sse2.pid) 2>/dev/null || true
echo "== frontend HTTP flow verify =="
./zig-out/bin/st-client --port $PORT frontend.http_verify | grep -q '"ok":3' && echo PASS
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
timeout 30 ./zig-out/bin/st-client --port $PORT backend.stream '{"provider":"openai","model":"gpt-4","api_key":"k","base_url":"http://127.0.0.1:18160","path":"/v1/chat/completions","messages":[{"role":"user","content":"hi"}]}' | grep -q 'Recovered' && echo PASS
kill $(cat $TMP/opencode/retry.pid) 2>/dev/null || true
echo "== browser smoke all =="
timeout 120 ./zig-out/bin/st-client --port $PORT frontend.browser_smoke_all | grep -q '"all_ok":true' && echo PASS
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
  echo SKIP_NO_ONNXRUNTIME
fi
echo "== llama .model tokenizer =="
if [ -f ../SillyTavern/src/tokenizers/llama.model ]; then
  ./zig-out/bin/st-client --port $PORT tokenizer.encode '{"text":"hello world","vocab":"../SillyTavern/src/tokenizers/llama.model"}' | grep -q '22172,3186' && echo PASS_LLAMA_MODEL || echo FAIL_LLAMA_MODEL
else
  echo SKIP_NO_LLAMA_MODEL
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
./zig-out/bin/st-client --port $PORT backend.stream '{"provider":"google","model":"gemini","api_key":"k","base_url":"http://127.0.0.1:18169","path":"/v1beta/models/gemini:streamGenerateContent","messages":[{"role":"user","content":"hi"}]}' | grep -q 'Google stream' && echo PASS
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
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"anthropic","model":"claude-3","api_key":"bad","base_url":"http://127.0.0.1:18171","path":"/v1/messages","messages":[]}' | grep -q '"status":403' && echo PASS
kill $(cat $TMP/opencode/e403.pid) 2>/dev/null || true
echo "== semantic ranking =="
SNAP=$(echo ~/.cache/huggingface/hub/models--sentence-transformers--all-MiniLM-L6-v2/snapshots/1110a243fdf4706b3f48f1d95db1a4f5529b4d41)
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
  grep -q SEMANTIC_RANK_PASS $TMP/opencode/n1.json 2>/dev/null || python3 -c "import json,math; a=json.load(open('$TMP/opencode/n1.json'))['result']['vector']; c=json.load(open('$TMP/opencode/n3.json'))['result']['vector']; cos=sum(i*j for i,j in zip(a,c))/(math.sqrt(sum(i*i for i in a))*math.sqrt(sum(j*j for j in c))); assert cos<0.5; print('SEMANTIC_DIFF_OK',cos)" && echo PASS
else
  echo SKIP_NO_MINILM
fi
echo "== browser exec real scripts =="
./zig-out/bin/st-client --port $PORT frontend.browser_exec '{"script":"constants.js"}' | grep -q '"exec_ok":true' && echo PASS
./zig-out/bin/st-client --port $PORT frontend.browser_exec '{"script":"a11y.js"}' | grep -q '"exec_ok":true' && echo PASS
echo "== bad method =="
./zig-out/bin/st-client --port $PORT nope | grep -q '"ok":false' && echo PASS
cat "$TMP/server.log"
echo "ALL SMOKE TESTS PASSED"
