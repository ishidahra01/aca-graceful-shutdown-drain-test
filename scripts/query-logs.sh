#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <workspace-id> <hours> <replica-substring>" >&2
  exit 1
fi

WORKSPACE_ID="$1"
HOURS="$2"
REPLICA_SUBSTRING="$3"

read -r -d '' QUERY <<'KQL' || true
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(HOURS_PLACEHOLDER * 1h)
| where Log_s contains REPLICA_PLACEHOLDER
| project TimeGenerated, RevisionName_s, ReplicaName_s, Log_s
| order by TimeGenerated asc
KQL

QUERY="${QUERY/HOURS_PLACEHOLDER/${HOURS}}"
QUERY="${QUERY/REPLICA_PLACEHOLDER/${REPLICA_SUBSTRING}}"

az monitor log-analytics query \
  --workspace "$WORKSPACE_ID" \
  --analytics-query "$QUERY"
