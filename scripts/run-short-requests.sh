#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <base-url> [duration-seconds] [interval-seconds]" >&2
  exit 1
fi

BASE_URL="${1%/}"
DURATION="${2:-0}"
INTERVAL="${3:-1}"

while true; do
  request_id="short-$(date +%s%3N)"
  curl --silent --show-error \
    -H "x-request-id: ${request_id}" \
    "${BASE_URL}/work?duration=${DURATION}" \
    | jq -c "{timestamp: now, requestId, replica, readiness, draining, ok}" || true
  sleep "$INTERVAL"
done
