import json, urllib.request, urllib.error

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
            routes.append(line.split("|")[1].strip().strip("`"))

def post(base, path, body):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=3) as r:
            return r.status, r.read()[:400].decode(errors="ignore")
    except urllib.error.HTTPError as e:
        return e.code, (e.read()[:400] if e.fp else b"").decode(errors="ignore")
    except Exception as e:
        return -1, str(e)[:80]

def sig(status, body):
    b = body.strip()
    if "backend_unreachable" in b:
        return "PROXY"
    if not b:
        return f"{status}:empty"
    if b.startswith("["):
        try:
            kind = type(json.loads(b)[0]).__name__ if json.loads(b) else "empty"
            return f"{status}:array[{kind}]"
        except Exception:
            return f"{status}:array?"
    if b.startswith("{"):
        try:
            return f"{status}:object{sorted(json.loads(b).keys())}"
        except Exception:
            return f"{status}:object?"
    if b.startswith("<"):
        return f"{status}:html"
    return f"{status}:text:{b[:30]}"

out = []
for i, r in enumerate(routes):
    js_s, js_b = post(JS, r, BASE)
    zg_s, zg_b = post(ZG, r, BASE)
    a, c = sig(js_s, js_b), sig(zg_s, zg_b)
    if "backend_unreachable" in zg_b:
        c = "PROXY"
    tag = "MATCH" if a == c else ("PROXY" if c == "PROXY" else "MISMATCH")
    out.append((tag, r, a, c, js_b[:80].replace("\n", " "), zg_b[:80].replace("\n", " ")))
    if i % 60 == 0:
        print(f"...{i}/{len(routes)}", flush=True)

from collections import Counter
print(Counter(x[0] for x in out))
with open("cmp-out.tsv", "w") as f:
    for tag, r, a, c, jb, zb in out:
        f.write(f"{tag}\t{r}\tJS:{a}\tZG:{c}\n")
print("--- MISMATCH (first 50) ---")
n = 0
for tag, r, a, c, jb, zb in out:
    if tag == "MISMATCH" and n < 50:
        print(f"{r}\n  JS {a} :: {jb}\n  ZG {c} :: {zb}")
        n += 1
