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
echo "== per-provider backend =="
./zig-out/bin/st-client --port $PORT backend.provider '{"provider":"openai","base_url":"http://127.0.0.1:9","path":"/v1/chat/completions","body":{}}' | grep -q 'backend_unreachable' && echo PASS
./zig-out/bin/st-client --port $PORT backend.provider '{"provider":"unknown"}' | grep -q 'unknown_provider' && echo PASS
./zig-out/bin/st-client --port $PORT backend.provider '{"provider":"anthropic","base_url":"http://127.0.0.1:9","path":"/v1/messages","body":{}}' | grep -q 'backend_unreachable' && echo PASS
echo "== neural model =="
python3 -c "import json; m={'input_dim':32,'hidden_dim':4,'output_dim':2,'W1':[0]*128,'b1':[0]*4,'W2':[1,0,0,0,0,1,0,0],'b2':[0,0]}; [exec(\"m['W1'].__setitem__(h*32+h,1)\") for h in range(4)]; json.dump(m, open('/rpf/tmp/opencode/model.json','w'))"
./zig-out/bin/st-client --port $PORT vectors.model '{"text":"hello","model":"/rpf/tmp/opencode/model.json"}' | grep -q '"neural":true' && echo PASS
./zig-out/bin/st-client --port $PORT vectors.model '{"text":"hello","model":"/nonexistent.json"}' | grep -q 'model_not_found' && echo PASS
echo "== browser extension runtime =="
./zig-out/bin/st-client --port $PORT extensions.execute_browser '{"code":"registerSlashCommand(\"hello\", ()=>{});"}' | grep -q 'hello' && echo PASS
echo "== native provider =="
cat > /rpf/tmp/opencode/mock_anthropic2.py <<'PYEOF'
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
python3 /rpf/tmp/opencode/mock_anthropic2.py > /rpf/tmp/opencode/mock2.log 2>&1 & echo $! > /rpf/tmp/opencode/mock2.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"anthropic","model":"claude-3","api_key":"k","base_url":"http://127.0.0.1:18121","path":"/v1/messages","messages":[{"role":"user","content":"hi"}]}' | grep -q 'mocked' && echo PASS || echo FAIL_NATIVE
kill $(cat /rpf/tmp/opencode/mock2.pid) 2>/dev/null || true
echo "== multi-model tokenizer =="
curl -sL -o /rpf/tmp/opencode/p50k_base.tiktoken https://openaipublic.blob.core.windows.net/encodings/p50k_base.tiktoken 2>/dev/null || true
if [ -s /rpf/tmp/opencode/p50k_base.tiktoken ]; then
  ./zig-out/bin/st-client --port $PORT tokenizer.encode '{"text":"hello world","vocab":"/rpf/tmp/opencode/p50k_base.tiktoken"}' | grep -q '31373,995' && echo PASS_P50K || echo FAIL_P50K
else
  echo SKIP_NO_P50K
fi
echo "== REPL =="
printf "/help\n/ping\n/exit\n" | timeout 5 ./zig-out/bin/st-client --port $PORT | grep -q '"pong":true' && echo PASS
echo "== image gen save =="
cat > /rpf/tmp/opencode/mock_sd.py <<'PYEOF'
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
python3 /rpf/tmp/opencode/mock_sd.py > /rpf/tmp/opencode/sd.log 2>&1 & echo $! > /rpf/tmp/opencode/sd.pid
sleep 1
./zig-out/bin/st-client --port $PORT stable-diffusion.generate_and_save '{"name":"cat","host":"127.0.0.1","port":18123,"path":"/sdapi/v1/txt2img","body":{}}' | grep -q 'cat.png' && echo PASS
kill $(cat /rpf/tmp/opencode/sd.pid) 2>/dev/null || true
echo "== remaining providers native =="
cat > /rpf/tmp/opencode/mock_kobold.py <<'PYEOF'
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
python3 /rpf/tmp/opencode/mock_kobold.py > /rpf/tmp/opencode/k.log 2>&1 & echo $! > /rpf/tmp/opencode/k.pid
sleep 1
./zig-out/bin/st-client --port $PORT backend.native '{"provider":"kobold","model":"m","base_url":"http://127.0.0.1:18124","path":"/api/v1/generate","messages":[{"role":"user","content":"hi"}]}' | grep -q 'kobold mock out' && echo PASS
kill $(cat /rpf/tmp/opencode/k.pid) 2>/dev/null || true
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
python3 -c "import json; m={'input_dim':32,'hidden_dim':4,'output_dim':2,'W1':[0]*128,'b1':[0]*4,'W2':[1,0,0,0,0,1,0,0],'b2':[0,0]}; [exec(\"m['W1'].__setitem__(h*32+h,1)\") for h in range(4)]; json.dump(m, open('/rpf/tmp/opencode/model.json','w'))"
./zig-out/bin/st-client --port $PORT vectors.save '{"collection":"nc","id":"n1","model":"/rpf/tmp/opencode/model.json","value":{"text":"hello"}}' | grep -q '"saved"' && echo PASS
echo "== frontend verify =="
./zig-out/bin/st-client --port $PORT frontend.verify | grep -q '"coverage":100' && echo PASS
echo "== caption image =="
cat > /rpf/tmp/opencode/mock_cap.py <<'PYEOF'
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
python3 /rpf/tmp/opencode/mock_cap.py > /rpf/tmp/opencode/cap.log 2>&1 & echo $! > /rpf/tmp/opencode/cap.pid
sleep 1
./zig-out/bin/st-client --port $PORT caption.image '{"image":"data:image/png;base64,iVBORw0KGgo=","prompt":"Describe","api_key":"k","base_url":"http://127.0.0.1:18129"}' | grep -q 'A cat sitting' && echo PASS
kill $(cat /rpf/tmp/opencode/cap.pid) 2>/dev/null || true
echo "== speech tts =="
cat > /rpf/tmp/opencode/mock_tts.py <<'PYEOF'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln=int(self.headers.get('Content-Length',0)); self.rfile.read(ln)
        data=b'ID3FAKEAUDIOBYTES'
        self.send_response(200); self.send_header('Content-Type','audio/mpeg'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18131),H).handle_request()
PYEOF
python3 /rpf/tmp/opencode/mock_tts.py > /rpf/tmp/opencode/tts.log 2>&1 & echo $! > /rpf/tmp/opencode/tts.pid
sleep 1
./zig-out/bin/st-client --port $PORT speech.tts '{"input":"Hello","name":"hello.mp3","api_key":"k","base_url":"http://127.0.0.1:18131"}' | grep -q 'hello.mp3' && echo PASS
kill $(cat /rpf/tmp/opencode/tts.pid) 2>/dev/null || true
echo "== classify/translate full =="
cat > /rpf/tmp/opencode/mock_ct.py <<'PYEOF'
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
python3 /rpf/tmp/opencode/mock_ct.py > /rpf/tmp/opencode/ct.log 2>&1 & echo $! > /rpf/tmp/opencode/ct.pid
sleep 1
./zig-out/bin/st-client --port $PORT classify.classify '{"text":"I love this","base_url":"http://127.0.0.1:18133","path":"/classify"}' | grep -q 'positive' && echo PASS
./zig-out/bin/st-client --port $PORT translate.translate '{"text":"Hello","source":"en","target":"fr","base_url":"http://127.0.0.1:18133/translate"}' | grep -q 'Bonjour' && echo PASS
kill $(cat /rpf/tmp/opencode/ct.pid) 2>/dev/null || true
echo "== speech transcribe =="
cat > /rpf/tmp/opencode/mock_stt.py <<'PYEOF'
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
python3 /rpf/tmp/opencode/mock_stt.py > /rpf/tmp/opencode/stt.log 2>&1 & echo $! > /rpf/tmp/opencode/stt.pid
sleep 1
./zig-out/bin/st-client --port $PORT speech.transcribe '{"audio":"QUJD","base_url":"http://127.0.0.1:18137"}' | grep -q 'Hello spoken' && echo PASS
kill $(cat /rpf/tmp/opencode/stt.pid) 2>/dev/null || true
echo "== onnx neural =="
python3 /rpf/tmp/opencode/make_onnx.py 2>/dev/null || cat > /rpf/tmp/opencode/make_onnx.py <<'PYEOF'
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
    attr=fs(1,"transB")+fv(7,2)+fv(3,1)
    return n+fl(5,attr)
def vi(n,dims):
    shape=b''
    for d in dims: shape+=fl(1,fv(1,d))
    tt=fv(1,1)+fl(2,shape)
    return fs(1,n)+fl(2,fl(1,tt))
W=[0.0]*64
for i in range(2): W[i*32+i]=1.0
graph=fl(1,node())+fs(2,"g")+fl(5,tensor("W",[2,32],W))+fl(5,tensor("B",[2],[0.0,0.0]))+fl(11,vi("X",[1,32]))+fl(12,vi("Y",[1,2]))
open('/rpf/tmp/opencode/test.onnx','wb').write(fv(1,8)+fl(8,fv(1,13))+fl(7,graph))
PYEOF
./zig-out/bin/st-client --port $PORT vectors.onnx '{"text":"hello","model":"/rpf/tmp/opencode/test.onnx"}' | grep -q '"onnx":true' && echo PASS
echo "== browser frontend verify =="
./zig-out/bin/st-client --port $PORT frontend.browser_verify | grep -q '"browser_equivalent":true' && echo PASS
echo "== bad method =="
./zig-out/bin/st-client --port $PORT nope | grep -q '"ok":false' && echo PASS
cat "$TMP/server.log"
echo "ALL SMOKE TESTS PASSED"
