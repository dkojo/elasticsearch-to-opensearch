#!/usr/bin/env bash
# Zero-downtime migration, one step at a time:
#   bash scripts/migrate.sh snapshot | restore | catchup | switch | verify
set -euo pipefail
cd "$(dirname "$0")/.."

ES=http://localhost:9200
OS=http://localhost:9201
INDEX=logs-app
STATE=.state
mkdir -p "$STATE"

json() { curl -sS --fail-with-body -H 'Content-Type: application/json' "$@"; }
now_ms() { date +%s%3N; }
count() { json -X POST "$1/$INDEX/_refresh" >/dev/null; json "$1/$INDEX/_count${2:-}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])'; }

# Copy everything Elasticsearch received since a point in time into OpenSearch (same IDs, so repeats are harmless)
catch_up_since() {
  json -X POST "$ES/$INDEX/_refresh" >/dev/null
  json -X POST "$OS/_reindex?wait_for_completion=true" -d "{
    \"source\": {\"remote\": {\"host\": \"http://elasticsearch:9200\"}, \"index\": \"$INDEX\",
                 \"query\": {\"range\": {\"@timestamp\": {\"gte\": $(( $1 - 5000 )), \"format\": \"epoch_millis\"}}}},
    \"dest\": {\"index\": \"$INDEX\"}}" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(f"copied {r[\"total\"]} documents written since then")'
}

case "${1:-}" in
  snapshot)
    now_ms > "$STATE/snapshot_start"
    json -X PUT "$ES/_snapshot/migration" -d '{"type": "fs", "settings": {"location": "/snapshots"}}' >/dev/null
    json -X PUT "$ES/_snapshot/migration/snap-1?wait_for_completion=true" \
      -d "{\"indices\": \"$INDEX\", \"include_global_state\": false}" >/dev/null
    echo "Snapshot snap-1 taken: $(count $ES) documents in Elasticsearch, the app is still writing"
    ;;
  restore)
    json -X PUT "$OS/_snapshot/migration" -d '{"type": "fs", "settings": {"location": "/snapshots", "readonly": true}}' >/dev/null
    json -X POST "$OS/_snapshot/migration/snap-1/_restore?wait_for_completion=true" -d "{\"indices\": \"$INDEX\"}" >/dev/null
    echo "Restored snap-1 into OpenSearch: $(count $OS) documents"
    ;;
  catchup)
    now_ms > "$STATE/catchup_start"
    echo "Catch-up: $(catch_up_since "$(cat "$STATE/snapshot_start")")"
    ;;
  switch)
    sed -i 's/server elasticsearch:9200;/server opensearch:9200;/' router/default.conf
    docker compose exec -T router nginx -t -q
    docker compose exec -T router nginx -s reload
    now_ms > "$STATE/switch_time"
    sleep 2
    echo "Router now points at OpenSearch (graceful reload, nothing dropped)"
    echo "Final catch-up: $(catch_up_since "$(cat "$STATE/catchup_start")")"
    ;;
  verify)
    pkill -TERM -f "app/app.py" || true
    for _ in $(seq 1 20); do [ -f app-stats.json ] && break; sleep 0.5; done
    python3 - "$(count $OS '?q=source:app')" "$(count $OS)" <<'EOF'
import json, sys
in_os, total = int(sys.argv[1]), int(sys.argv[2])
s = json.load(open("app-stats.json"))
print(f"App: {s['writes_ok']} writes acknowledged, {s['searches_ok']} searches, {s['failed']} failed requests")
print(f"OpenSearch has {in_os} of the app's documents ({total} in total)")
ok = s["failed"] == 0 and in_os == s["writes_ok"]
print("PASS  no request failed and no document was lost" if ok else "FAIL  " + ("requests failed" if s["failed"] else f"{s['writes_ok'] - in_os} acknowledged writes are missing"))
sys.exit(0 if ok else 1)
EOF
    ;;
  *)
    echo "usage: $0 snapshot|restore|catchup|switch|verify"; exit 2 ;;
esac
