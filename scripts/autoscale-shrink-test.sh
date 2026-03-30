#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <resource-group> <container-app-name> <base-url> [short-workers] [short-interval-seconds] [long-parallelism] [long-duration-seconds] [target-scale-out-replicas] [shrink-timeout-seconds] [delay-before-long-seconds] [stop-after-first-scale-reduction]" >&2
  exit 1
fi

RESOURCE_GROUP="$1"
CONTAINER_APP_NAME="$2"
BASE_URL="${3%/}"
SHORT_WORKERS="${4:-4}"
SHORT_INTERVAL_SECONDS="${5:-0.2}"
LONG_PARALLELISM="${6:-2}"
LONG_DURATION_SECONDS="${7:-120}"
TARGET_SCALE_OUT_REPLICAS="${8:-2}"
SHRINK_TIMEOUT_SECONDS="${9:-420}"
DELAY_BEFORE_LONG_SECONDS="${10:-0}"
STOP_AFTER_FIRST_SCALE_REDUCTION_RAW="${11:-false}"

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR_OVERRIDE="${SCRIPT_DIR_OVERRIDE:-}"
SCRIPT_DIR="${SCRIPT_DIR_OVERRIDE:-$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)}"
TMP_DIR="$(mktemp -d)"
SHORT_PIDS=()
PROBE_PID=''
LONG_LOAD_PID=''
LOAD_STOPPED_AT=''
FIRST_SCALE_REDUCTION_AT=''
LOAD_STOP_REPLICA_COUNT='0'
PEAK_REPLICA_COUNT_AFTER_LOAD_STOP='0'
STOPPED_AFTER_FIRST_SCALE_REDUCTION=false
LONG_STARTED_AT_FILE="$TMP_DIR/long-started-at.txt"
LONG_DELAY_STARTED_AT_FILE="$TMP_DIR/long-delay-started-at.txt"
LONG_COMPLETED_AT_FILE="$TMP_DIR/long-completed-at.txt"

shopt -s nocasematch
if [[ "$STOP_AFTER_FIRST_SCALE_REDUCTION_RAW" =~ ^(1|true|yes|on)$ ]]; then
  STOP_AFTER_FIRST_SCALE_REDUCTION=true
else
  STOP_AFTER_FIRST_SCALE_REDUCTION=false
fi
shopt -u nocasematch

: > "$TMP_DIR/replica-timeline.ndjson"
: > "$TMP_DIR/short-load.ndjson"
: > "$TMP_DIR/long-results.ndjson"
: > "$TMP_DIR/probe-results.ndjson"

cleanup() {
  if [[ -n "${PROBE_PID}" ]]; then
    kill "${PROBE_PID}" 2>/dev/null || true
  fi

  if [[ -n "${LONG_LOAD_PID}" ]]; then
    kill "${LONG_LOAD_PID}" 2>/dev/null || true
  fi

  for pid in "${SHORT_PIDS[@]:-}"; do
    kill "${pid}" 2>/dev/null || true
  done

  wait 2>/dev/null || true
}

trap cleanup EXIT

active_revision() {
  az containerapp revision list \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINER_APP_NAME" \
    --query "[?properties.active].name | [0]" \
    -o tsv
}

replica_count() {
  az containerapp replica list \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINER_APP_NAME" \
    --query 'length(@)' \
    -o tsv
}

append_replica_sample() {
  jq -cn \
    --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg revision "$(active_revision)" \
    --argjson replicas "$(replica_count)" \
    '{utc:$utc, revision:$revision, replicas:$replicas}' >> "$TMP_DIR/replica-timeline.ndjson"
}

start_short_load_worker() {
  local worker_id="$1"

  while true; do
    local request_id="short-${worker_id}-$(date +%s%3N)"
    local status

    status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
      -H "x-request-id: ${request_id}" \
      "${BASE_URL}/work?duration=1" || true)

    jq -cn \
      --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg requestId "$request_id" \
      --arg status "$status" \
      '{utc:$utc, requestId:$requestId, status:$status, kind:"short"}' >> "$TMP_DIR/short-load.ndjson"

    sleep "$SHORT_INTERVAL_SECONDS"
  done
}

start_probe_loop() {
  while true; do
    local request_id="probe-$(date +%s%3N)"
    local response_file="$TMP_DIR/probe-response.json"
    local status

    status=$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
      -H "x-request-id: ${request_id}" \
      "${BASE_URL}/work?duration=0" || true)

    jq -cn \
      --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg requestId "$request_id" \
      --arg status "$status" \
      --arg body "$(tr -d '\r' < "$response_file" 2>/dev/null || true)" \
      '{utc:$utc, requestId:$requestId, status:$status, body:$body, kind:"probe"}' >> "$TMP_DIR/probe-results.ndjson"

    sleep 2
  done
}

run_single_long_request() {
  local request_index="$1"
  local request_id="long-${request_index}-$(date +%s%3N)"
  local response_file="$TMP_DIR/long-response-${request_index}.json"
  local error_file="$TMP_DIR/long-error-${request_index}.txt"
  local started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local status_code
  local exit_code=0

  printf '%s' "$started_at" > "$LONG_STARTED_AT_FILE"

  status_code=$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
    -H "x-request-id: ${request_id}" \
    "${BASE_URL}/work?duration=${LONG_DURATION_SECONDS}" 2>"$error_file") || exit_code=$?

  jq -cn \
    --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg startedAt "$started_at" \
    --arg requestId "$request_id" \
    --arg statusCode "$status_code" \
    --arg body "$(tr -d '\r' < "$response_file" 2>/dev/null || true)" \
    --arg error "$(tr -d '\r' < "$error_file" 2>/dev/null || true)" \
    --argjson exitCode "$exit_code" \
    '{utc:$utc, startedAt:$startedAt, requestId:$requestId, statusCode:$statusCode, exitCode:$exitCode, body:$body, error:$error, kind:"long"}' >> "$TMP_DIR/long-results.ndjson"
}

start_delayed_long_requests() {
  local delay_seconds="$1"
  local long_pids=()
  local request_index

  date -u +%Y-%m-%dT%H:%M:%SZ > "$LONG_DELAY_STARTED_AT_FILE"

  if [[ "$delay_seconds" != "0" ]]; then
    sleep "$delay_seconds"
  fi

  for request_index in $(seq 1 "$LONG_PARALLELISM"); do
    run_single_long_request "$request_index" &
    long_pids+=("$!")
  done

  for pid in "${long_pids[@]}"; do
    wait "$pid"
  done

  date -u +%Y-%m-%dT%H:%M:%SZ > "$LONG_COMPLETED_AT_FILE"
}

INITIAL_REVISION="$(active_revision)"
echo "Initial active revision: ${INITIAL_REVISION}"

for worker in $(seq 1 "$SHORT_WORKERS"); do
  start_short_load_worker "$worker" &
  SHORT_PIDS+=("$!")
done

echo "Started ${SHORT_WORKERS} short-load workers"

SCALED_OUT=false
for _ in $(seq 1 60); do
  append_replica_sample
  current_replicas="$(tail -n 1 "$TMP_DIR/replica-timeline.ndjson" | jq -r '.replicas')"
  echo "Replica count: ${current_replicas}"
  if [[ "$current_replicas" -ge "$TARGET_SCALE_OUT_REPLICAS" ]]; then
    SCALED_OUT=true
    break
  fi
  sleep 5
done

if [[ "$SCALED_OUT" != true ]]; then
  echo "Replica count did not reach ${TARGET_SCALE_OUT_REPLICAS}" >&2
  exit 2
fi

echo "Scale-out confirmed; stopping short load and waiting for natural shrink"
for pid in "${SHORT_PIDS[@]}"; do
  kill "$pid" 2>/dev/null || true
done
SHORT_PIDS=()
LOAD_STOPPED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LOAD_STOP_REPLICA_COUNT="$current_replicas"
PEAK_REPLICA_COUNT_AFTER_LOAD_STOP="$current_replicas"

if [[ "$LONG_PARALLELISM" -gt 0 ]]; then
  start_delayed_long_requests "$DELAY_BEFORE_LONG_SECONDS" &
  LONG_LOAD_PID="$!"
  echo "Scheduled ${LONG_PARALLELISM} long requests ${DELAY_BEFORE_LONG_SECONDS}s after load stop"
else
  echo "Long requests disabled; measuring shrink timing only"
fi

start_probe_loop &
PROBE_PID="$!"

SHRUNK=false
end_time=$(( $(date +%s) + SHRINK_TIMEOUT_SECONDS ))
while [[ $(date +%s) -lt $end_time ]]; do
  append_replica_sample
  current_replicas="$(tail -n 1 "$TMP_DIR/replica-timeline.ndjson" | jq -r '.replicas')"
  current_revision="$(tail -n 1 "$TMP_DIR/replica-timeline.ndjson" | jq -r '.revision')"
  echo "Replica count after load stop: ${current_replicas} (revision: ${current_revision})"
  if [[ "$current_replicas" -gt "$PEAK_REPLICA_COUNT_AFTER_LOAD_STOP" ]]; then
    PEAK_REPLICA_COUNT_AFTER_LOAD_STOP="$current_replicas"
  fi
  if [[ -z "$FIRST_SCALE_REDUCTION_AT" && "$current_replicas" -lt "$PEAK_REPLICA_COUNT_AFTER_LOAD_STOP" ]]; then
    FIRST_SCALE_REDUCTION_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$STOP_AFTER_FIRST_SCALE_REDUCTION" == true ]]; then
      STOPPED_AFTER_FIRST_SCALE_REDUCTION=true
      break
    fi
  fi
  if [[ "$current_revision" != "$INITIAL_REVISION" ]]; then
    echo "Active revision changed unexpectedly to ${current_revision}" >&2
    exit 3
  fi
  if [[ "$current_replicas" -le 1 ]]; then
    SHRUNK=true
    break
  fi
  sleep 5
done

if [[ -n "$LONG_LOAD_PID" ]]; then
  wait "$LONG_LOAD_PID" || true
fi

LONG_DELAY_STARTED_AT="$(cat "$LONG_DELAY_STARTED_AT_FILE" 2>/dev/null || true)"
LONG_STARTED_AT="$(cat "$LONG_STARTED_AT_FILE" 2>/dev/null || true)"
LONG_COMPLETED_AT="$(cat "$LONG_COMPLETED_AT_FILE" 2>/dev/null || true)"

if [[ -n "$PROBE_PID" ]]; then
  kill "$PROBE_PID" 2>/dev/null || true
  wait "$PROBE_PID" 2>/dev/null || true
  PROBE_PID=''
fi

jq -n \
  --arg initialRevision "$INITIAL_REVISION" \
  --arg loadStoppedAt "$LOAD_STOPPED_AT" \
  --arg longDelayStartedAt "$LONG_DELAY_STARTED_AT" \
  --arg longStartedAt "$LONG_STARTED_AT" \
  --arg longCompletedAt "$LONG_COMPLETED_AT" \
  --arg firstScaleReductionAt "$FIRST_SCALE_REDUCTION_AT" \
  --argjson delayBeforeLongSeconds "$DELAY_BEFORE_LONG_SECONDS" \
  --argjson longParallelism "$LONG_PARALLELISM" \
  --argjson longDurationSeconds "$LONG_DURATION_SECONDS" \
  --argjson loadStopReplicaCount "$LOAD_STOP_REPLICA_COUNT" \
  --argjson peakReplicaCountAfterLoadStop "$PEAK_REPLICA_COUNT_AFTER_LOAD_STOP" \
  --argjson stopAfterFirstScaleReduction "$STOP_AFTER_FIRST_SCALE_REDUCTION" \
  --argjson stoppedAfterFirstScaleReduction "$STOPPED_AFTER_FIRST_SCALE_REDUCTION" \
  --arg artifacts "$TMP_DIR" \
  --argjson scaledOut "$SCALED_OUT" \
  --argjson shrunk "$SHRUNK" \
  --slurpfile replicaTimeline "$TMP_DIR/replica-timeline.ndjson" \
  --slurpfile longResults "$TMP_DIR/long-results.ndjson" \
  --slurpfile probeResults "$TMP_DIR/probe-results.ndjson" \
  '{initialRevision:$initialRevision, loadStoppedAt:$loadStoppedAt, loadStopReplicaCount:$loadStopReplicaCount, peakReplicaCountAfterLoadStop:$peakReplicaCountAfterLoadStop, firstScaleReductionAt:$firstScaleReductionAt, delayBeforeLongSeconds:$delayBeforeLongSeconds, longParallelism:$longParallelism, longDurationSeconds:$longDurationSeconds, longDelayStartedAt:$longDelayStartedAt, longStartedAt:$longStartedAt, longCompletedAt:$longCompletedAt, stopAfterFirstScaleReduction:$stopAfterFirstScaleReduction, stoppedAfterFirstScaleReduction:$stoppedAfterFirstScaleReduction, scaledOut:$scaledOut, shrunk:$shrunk, replicaTimeline:$replicaTimeline, longResults:$longResults, probeResults:$probeResults, artifacts:$artifacts}'
