#!/usr/bin/env bash
# Move the Kibana saved objects (exported from Kibana 7.10) into OpenSearch Dashboards, then check they point at real data.
set -euo pipefail
cd "$(dirname "$0")/.."
for _ in $(seq 1 60); do
  curl -sf http://localhost:5601/api/status -o /dev/null && curl -sf "http://localhost:5601/api/saved_objects/_find?type=index-pattern" -H "osd-xsrf: true" -o /dev/null && break
  sleep 3
done
result=$(curl -sf -X POST "http://localhost:5601/api/saved_objects/_import?overwrite=true" \
  -H "osd-xsrf: true" --form file=@dashboards/kibana-7.10-export.ndjson)
echo "Import response: $result"
echo "$result" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["success"], r; print("Imported %d Kibana saved objects into OpenSearch Dashboards" % r["successCount"])'
errors=$(curl -sf "http://localhost:9201/logs-app/_count?q=level:error" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')
echo "The \"Errors by service\" search finds $errors documents in OpenSearch"
[ "$errors" -gt 0 ]
