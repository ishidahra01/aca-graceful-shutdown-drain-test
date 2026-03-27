#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <resource-group> <container-app-name>" >&2
  exit 1
fi

RESOURCE_GROUP="$1"
CONTAINER_APP_NAME="$2"
MARKER="rev-$(date +%Y%m%d%H%M%S)"

echo "Creating a new revision with TEST_MARKER=${MARKER}"
az containerapp update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_APP_NAME" \
  --set-env-vars TEST_MARKER="$MARKER" 1>/dev/null

echo "Active revisions:"
az containerapp revision list \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_APP_NAME" \
  --query '[].{name:name,active:properties.active,trafficWeight:properties.trafficWeight,healthState:properties.healthState}'
