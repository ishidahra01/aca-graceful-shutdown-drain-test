#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <base-url> [duration-seconds] [parallelism]" >&2
  exit 1
fi

BASE_URL="${1%/}"
DURATION="${2:-45}"
PARALLELISM="${3:-4}"

seq 1 "$PARALLELISM" | xargs -I{} -P "$PARALLELISM" bash -c '
  request_id="long-{}-$(date +%s)"
  curl --silent --show-error --fail \
    -H "x-request-id: ${request_id}" \
    "'""${BASE_URL}"'"/work?duration='""${DURATION}"'"" \
    | jq -c "{requestId, durationSeconds, replica, readiness, draining}"
'
