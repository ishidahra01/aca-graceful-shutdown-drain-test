#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <resource-group> <container-app-name> <base-url> [parallel-long-requests]" >&2
  exit 1
fi

RESOURCE_GROUP="$1"
CONTAINER_APP_NAME="$2"
BASE_URL="${3%/}"
PARALLELISM="${4:-6}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/run-long-requests.sh" "$BASE_URL" 60 "$PARALLELISM" &
LOAD_PID=$!

trap 'kill ${LOAD_PID} 2>/dev/null || true' EXIT

echo "Waiting for replicas to scale out..."
for _ in {1..30}; do
  replica_count=$(az containerapp replica list --resource-group "$RESOURCE_GROUP" --name "$CONTAINER_APP_NAME" --query 'length(@)' -o tsv)
  echo "Current replica count: ${replica_count}"
  if [[ "${replica_count}" -ge 2 ]]; then
    break
  fi
  sleep 10
done

echo "Forcing scale-in to 1 replica"
az containerapp update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_APP_NAME" \
  --min-replicas 1 \
  --max-replicas 1 1>/dev/null

wait "$LOAD_PID" || true
