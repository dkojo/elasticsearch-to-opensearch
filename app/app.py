"""The application: writes a log document every 50 ms and searches every 250 ms, always through the router.
It keeps going for the whole migration. On SIGTERM it saves what happened to app-stats.json:
how many writes were acknowledged, and how many requests of any kind failed.

  python3 app/app.py http://localhost:8080
"""
import json
import signal
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

ROUTER = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"
INDEX = "logs-app"
stats = {"writes_ok": 0, "searches_ok": 0, "failed": 0, "errors": []}
running = True


def request(method, path, body=None):
    req = urllib.request.Request(ROUTER + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.status


def stop(*_):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
seq = 0
while running:
    seq += 1
    doc = {"@timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
           "source": "app", "level": "error" if seq % 25 == 0 else "info", "message": f"order {seq} processed"}
    try:
        request("PUT", f"/{INDEX}/_doc/app-{seq}", doc)
        stats["writes_ok"] += 1
        if seq % 5 == 0:
            request("GET", f"/{INDEX}/_search?size=1&q=level:error")
            stats["searches_ok"] += 1
    except (urllib.error.URLError, OSError) as e:
        stats["failed"] += 1
        stats["errors"].append(f"{datetime.now(timezone.utc).isoformat()} {e}")
    time.sleep(0.05)

with open("app-stats.json", "w", encoding="utf-8") as f:
    json.dump(stats, f, indent=2)
