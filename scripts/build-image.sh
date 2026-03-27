#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <resource-group> <acr-name> [image-tag]" >&2
  exit 1
fi

RESOURCE_GROUP="$1"
ACR_NAME="$2"
IMAGE_TAG="${3:-latest}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="graceful-shutdown-drain-test:${IMAGE_TAG}"

az acr build \
  --resource-group "$RESOURCE_GROUP" \
  --registry "$ACR_NAME" \
  --image "$IMAGE_NAME" \
  "$REPO_ROOT"

echo "$IMAGE_NAME"
