# Prints the error of an n8n execution: reads GET /rest/executions/:id JSON on stdin (flatted run data).
import json, sys
d = json.load(sys.stdin)["data"]
arr = json.loads(d["data"]) if isinstance(d["data"], str) else d["data"]
def w(v):
    if isinstance(v, dict): return {k: r(x) for k, x in v.items()}
    if isinstance(v, list): return [r(x) for x in v]
    return v
def r(x):
    if isinstance(x, str):
        t = arr[int(x)]
        return t if isinstance(t, str) else w(t)
    return w(x)
res = w(arr[0])["resultData"]
e = res.get("error") or {}
print("status:", d.get("status"), "| error:", e.get("message"), "|", (e.get("description") or "")[:200], "| node:", (e.get("node") or {}).get("name"))
for n, runs in res.get("runData", {}).items():
    for run in runs:
        if run.get("error"): print("  node", n, "->", run["error"].get("message"))
