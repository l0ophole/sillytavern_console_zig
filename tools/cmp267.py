import json, urllib.request, urllib.error, sys

JS = "http://127.0.0.1:8021"
ZG = "http://127.0.0.1:8022"

BASE = {
    "name": "Alice", "id": "Alice", "file": "Alice.png", "file_name": "chat1",
    "avatar_url": "Alice.png", "avatar": "Alice.png", "character": "Alice",
    "chat": [{"mes": "hi"}], "data": [{"mes": "hi"}], "content": "hello",
    "url": "http://127.0.0.1:9/x", "query": "hi", "text": "hello",
    "messages": [{"role": "user", "content": "hi"}], "prompt": "hi",
    "handle": "default-user", "password": "x", "key": "k", "value": "v",
    "kind": "characters", "force": False, "is_group": False,
    "exportfilename": "x.json", "format": "jsonl", "metadata": False,
    "simple": False, "user": "default-user",
}

routes = []
with open("docs/route-table.md") as f:
    for line in f:
        line = line.strip()
        if line.startswith("| `/api/"):
            r = line.split("|")[1].strip()
            routes.append(r)
print(f"routes={len(routes)}", flush=True)

def post(base, path, body):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=3) as r:
            return r.status, r.read()[:300].decode(errors="ignore")
    except urllib.error.HTTPError as e:
        return e.code, (e.read()[:300] if e.fp else b"").decode(errors="ignore")
    except Exception as e:
        return -1, str(e)[:80]

def shape(body):
    body = body.strip()
    if not body:
        return "empty"
    if body.startswith("["):
        return "array"
    if body.startswith("{"):
        try:
            keys = sorted(json.loads(body).keys())
            return "object[" + ",".join(keys[:4]) + "]"
        except Exception:
            return "object?"
    if body.startswith("<"):
        return "html"
    return "text"

results = []
for i, r in enumerate(routes):
    js_status, js_body = post(JS, r, BASE)
    zg_status, zg_body = post(ZG, r, BASE)
    js_shape, zg_shape = shape(js_body), shape(zg_body)
    if "backend_unreachable" in zg_body:
        zg_shape = "proxy"
    tag = "MATCH" if (js_shape == zg_shape) else ("PROXY?" if zg_shape == "proxy" else "MISMATCH")
    results.append((r, js_status, js_shape, zg_status, zg_shape, tag))
    if i % 50 == 0:
        print(f"...{i}/{len(routes)}", flush=True)

counts = {}
for x in results:
    counts[x[5]] = counts.get(x[5], 0) + 1
print(counts)
with open("/tmp/cmp267.tsv", "w") as f:
    for r, js_s, js_sh, zg_s, zg_sh, tag in results:
        f.write(f"{tag}\t{r}\tJS:{js_s}/{js_sh}\tZG:{zg_s}/{zg_sh}\n")
print("--- MISMATCH (first 40) ---")
shown = 0
for r, js_s, js_sh, zg_s, zg_sh, tag in results:
    if tag == "MISMATCH" and shown < 40:
        print(f"{r} JS:{js_s}/{js_sh} ZG:{zg_s}/{zg_sh}")
        shown += 1
