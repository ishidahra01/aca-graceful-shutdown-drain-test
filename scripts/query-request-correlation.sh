#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <workspace-id> <hours> <durations-csv> <request-ids-csv>" >&2
  echo "Example: $0 <workspace-id> 8 230,260,360 req-230,req-260,req-360" >&2
  exit 1
fi

WORKSPACE_ID="$1"
HOURS="$2"
DURATIONS_CSV="$3"
REQUEST_IDS_CSV="$4"

IFS=',' read -r -a DURATIONS <<< "$DURATIONS_CSV"
IFS=',' read -r -a REQUEST_IDS <<< "$REQUEST_IDS_CSV"

join_kql_string_list() {
  local value
  local joined=""

  for value in "$@"; do
    [[ -n "$value" ]] || continue
    if [[ -n "$joined" ]]; then
      joined+=", "
    fi
    joined+="'${value}'"
  done

  printf '%s' "$joined"
}

REQUEST_PATHS=()
for duration in "${DURATIONS[@]}"; do
  [[ -n "$duration" ]] || continue
  REQUEST_PATHS+=("/work?duration=${duration}")
done

if [[ ${#REQUEST_PATHS[@]} -eq 0 ]]; then
  echo "No durations were provided" >&2
  exit 2
fi

if [[ ${#REQUEST_IDS[@]} -eq 0 ]]; then
  echo "No request IDs were provided" >&2
  exit 3
fi

PATH_FILTER="$(join_kql_string_list "${REQUEST_PATHS[@]}")"
REQUEST_ID_FILTER="$(join_kql_string_list "${REQUEST_IDS[@]}")"

read -r -d '' GATEWAY_QUERY <<KQL || true
AzureDiagnostics
| where TimeGenerated > ago(${HOURS}h)
| where Category == 'ApplicationGatewayAccessLog'
| where originalRequestUriWithArgs_s in (${PATH_FILTER})
| project TimeGenerated, originalRequestUriWithArgs_s, httpStatus_d, serverStatus_s, timeTaken_d, serverResponseLatency_s, error_info_s, transactionId_g, clientIP_s, userAgent_s
| order by TimeGenerated asc
KQL

read -r -d '' APP_QUERY <<KQL || true
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(${HOURS}h)
| extend parsed = parse_json(Log_s)
| extend event = tostring(parsed.event), requestId = tostring(parsed.requestId), path = tostring(parsed.path), elapsedMs = toint(parsed.elapsedMs), replica = tostring(parsed.replica)
| where requestId in (${REQUEST_ID_FILTER})
| where event in ('request.start', 'request.end')
| project TimeGenerated, requestId, event, path, elapsedMs, replica
| order by TimeGenerated asc
KQL

gateway_json="$(az monitor log-analytics query --workspace "$WORKSPACE_ID" --analytics-query "$GATEWAY_QUERY" -o json)"
app_json="$(az monitor log-analytics query --workspace "$WORKSPACE_ID" --analytics-query "$APP_QUERY" -o json)"

jq -n \
  --arg queriedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg hours "$HOURS" \
  --arg durations "$DURATIONS_CSV" \
  --arg requestIds "$REQUEST_IDS_CSV" \
  --arg queryGateway "$GATEWAY_QUERY" \
  --arg queryApp "$APP_QUERY" \
  --argjson gatewayAccessLogs "$gateway_json" \
  --argjson appRequestLogs "$app_json" \
  '{
    queriedAt: $queriedAt,
    hours: $hours,
    durations: $durations,
    requestIds: $requestIds,
    gatewayQuery: $queryGateway,
    appQuery: $queryApp,
    gatewayAccessLogs: $gatewayAccessLogs,
    appRequestLogs: $appRequestLogs
  }'