"""Create the logs-app index in Elasticsearch and fill it with history: the data that has to move.

  python3 scripts/seed.py 20000
"""
import json
import random
import sys
import urllib.request
from datetime import datetime, timedelta, timezone

ES = "http://localhost:9200"
INDEX = "logs-app"
COUNT = int(sys.argv[1]) if len(sys.argv) > 1 else 2000


def call(method, path, body, content_type="application/json"):
    req = urllib.request.Request(ES + path, method=method, data=body.encode(), headers={"Content-Type": content_type})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


call("PUT", f"/{INDEX}", json.dumps({
    "settings": {"number_of_shards": 1, "number_of_replicas": 0},
    "mappings": {"properties": {"@timestamp": {"type": "date"}, "source": {"type": "keyword"},
                                "level": {"type": "keyword"}, "service": {"type": "keyword"}, "message": {"type": "text"}}},
}))

random.seed(42)
start = datetime.now(timezone.utc) - timedelta(days=7)
services = ["checkout", "payments", "search", "accounts"]
for batch in range(0, COUNT, 5000):
    lines = []
    for i in range(batch, min(batch + 5000, COUNT)):
        ts = start + timedelta(seconds=i * (7 * 86400 / COUNT))
        lines.append(json.dumps({"index": {"_id": f"hist-{i}"}}))
        lines.append(json.dumps({"@timestamp": ts.isoformat(timespec="milliseconds"), "source": "history",
                                 "service": random.choice(services), "level": random.choices(["info", "warn", "error"], [90, 8, 2])[0],
                                 "message": f"request {i} handled"}))
    result = call("POST", f"/{INDEX}/_bulk", "\n".join(lines) + "\n", "application/x-ndjson")
    if result["errors"]:
        sys.exit("bulk load reported errors")
call("POST", f"/{INDEX}/_refresh", "{}")
print(f"Seeded {COUNT} historical documents into Elasticsearch 7.10 ({INDEX})")
