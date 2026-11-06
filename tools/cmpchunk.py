import json, urllib.request, urllib.error, sys

JS = "http://127.0.0.1:8021"
ZG = "http://127.0.0.1:8022"
BASE = {
    "name": "Alice", "id": "Alice", "file": "Alice.png", "file_name": "chat1",
    "avatar_url": "Alice.png", "avatar": "Alice.png", "character": "Alice",
    "chat": [{"mes": "hi"}], "data": [{"mes": "hi"}], "content": "hello",
    "url": "not-a-url", "query": "hi", "text": "hello",
    "messages": [{"role": "user", "content": "hi"}], "prompt": "hi",
    "handle": "default-user", "password": "x", "key": "k", "value": "v",
    "kind": "characters", "force": False, "is_group": False,
    "exportfilename": "x.json", "format": "jsonl", "metadata": False,
    "simple": False, "user": "default-user",
}
rows = []
with open("docs/route-table.md") as f:
    for line in f:
        line = line.strip()
        if line.startswith("| `/api/"):
            parts = line.split("|")
            rows.append((parts[1].strip().strip("`"), parts[4].strip()))
start, end = int(sys.argv[1]), int(sys.argv[2])
rows = rows[start:end]

def post(base, path, body):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=3) as r:
            return r.status, r.read()[:400].decode(errors="ignore")
    except urllib.error.HTTPError as e:
        return e.code, (e.read()[:400] if e.fp else b"").decode(errors="ignore")
    except Exception as e:
        return -1, str(e)[:60]

def sig(status, body):
    b = body.strip()
    if "backend_unreachable" in b:
        return "PROXY"
    if not b:
        return f"{status}:empty"
    if b.startswith("["):
        try:
            v = json.loads(b)
            return f"{status}:array[{type(v[0]).__name__ if v else 'empty'}]"
        except Exception:
            return f"{status}:array?"
    if b.startswith("{"):
        try:
            return f"{status}:object{sorted(json.loads(b).keys())}"
        except Exception:
            return f"{status}:object?"
    if b.startswith("<"):
        return f"{status}:html"
    return f"{status}:text:{b[:24]}"

with open("cmp-chunks.tsv", "a") as f:
    for r, probe in rows:
        zg_s, zg_b = post(ZG, r, BASE)
        c = sig(zg_s, zg_b)
        if "backend_unreachable" in zg_b:
            c = "PROXY"
        if probe == "backend_unreachable" or c == "PROXY":
            f.write(f"PROXY\t{r}\tJS:skipped\tZG:{c}\tJSB:''\tZGB:{zg_b[:60]!r}\n")
            f.flush()
            continue
        js_s, js_b = post(JS, r, BASE)
        a = sig(js_s, js_b)
        tag = "MATCH" if a == c else "MISMATCH"
        f.write(f"{tag}\t{r}\tJS:{a}\tZG:{c}\tJSB:{js_b[:60]!r}\tZGB:{zg_b[:60]!r}\n")
        f.flush()
print(f"chunk {start}-{end} done")
