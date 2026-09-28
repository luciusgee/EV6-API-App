#!/usr/bin/env bash
# Start and check Codemagic builds through the REST API.
# Needs CODEMAGIC_API_TOKEN in the environment (Codemagic: Account settings > API token). Never commit it.
#
#   scripts/codemagic.sh start ios-ci [branch]         # default branch: main
#   scripts/codemagic.sh start ios-testflight [branch]
#   scripts/codemagic.sh status [buildId]              # latest builds, or one build with its steps
#   scripts/codemagic.sh cancel <buildId>
set -euo pipefail

APP_ID="6abae6a37f070ab9c39d307f"   # EV6-API-App in Codemagic (not a secret)
API="https://api.codemagic.io"
: "${CODEMAGIC_API_TOKEN:?Set CODEMAGIC_API_TOKEN (Codemagic: Account settings > API token)}"

call() { curl -sS -H "x-auth-token: $CODEMAGIC_API_TOKEN" -H "Content-Type: application/json" "$@"; }

case "${1:-}" in
  start)
    workflow="${2:?workflow id, e.g. ios-ci or ios-testflight}"
    branch="${3:-main}"
    call -X POST "$API/builds" -d "{\"appId\":\"$APP_ID\",\"workflowId\":\"$workflow\",\"branch\":\"$branch\"}"
    echo
    ;;
  status)
    if [ -n "${2:-}" ]; then
      call "$API/builds/$2" | python3 -c '
import sys, json
b = json.load(sys.stdin).get("build", {})
print(b.get("_id"), b.get("fileWorkflowId"), b.get("branch"), b.get("status"))
for a in b.get("buildActions", []):
    print("  %-10s %s" % (a.get("status") or "", a.get("name")))'
    else
      call "$API/builds?appId=$APP_ID" | python3 -c '
import sys, json
for b in json.load(sys.stdin).get("builds", [])[:10]:
    print(b.get("_id"), b.get("fileWorkflowId"), b.get("branch"), b.get("status"), (b.get("commit") or {}).get("commitMessage", "").splitlines()[0][:60] if b.get("commit") else "")'
    fi
    ;;
  cancel)
    call -X POST "$API/builds/${2:?buildId}/cancel"
    echo
    ;;
  *)
    sed -n '2,9p' "$0"
    exit 1
    ;;
esac
