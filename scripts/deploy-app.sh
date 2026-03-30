#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <resource-group> <prefix> <image-tag> [grace-seconds] [drain-on-sigterm] [revision-mode] [concurrent-requests] [min-replicas] [max-replicas] [appgw-request-timeout-seconds]" >&2
  exit 1
fi

RESOURCE_GROUP="$1"
PREFIX="$2"
IMAGE_TAG="$3"
GRACE_SECONDS="${4:-30}"
DRAIN_ON_SIGTERM="${5:-true}"
REVISION_MODE="${6:-Single}"
CONCURRENT_REQUESTS="${7:-5}"
MIN_REPLICAS="${8:-1}"
MAX_REPLICAS="${9:-5}"
APPGW_REQUEST_TIMEOUT_SECONDS="${10:-120}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACR_NAME="$(az acr list --resource-group "$RESOURCE_GROUP" --query "[?starts_with(name, '${PREFIX}')].name | [0]" -o tsv)"
IMAGE_SERVER="$(az acr show --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --query loginServer -o tsv)"
IMAGE_NAME="${IMAGE_SERVER}/graceful-shutdown-drain-test:${IMAGE_TAG}"
ACA_ENV_NAME="${PREFIX}-aca-env"
PRIVATE_DNS_ZONE_NAME="$(az containerapp env show --resource-group "$RESOURCE_GROUP" --name "$ACA_ENV_NAME" --query properties.defaultDomain -o tsv)"
MANAGED_ENV_STATIC_IP="$(az containerapp env show --resource-group "$RESOURCE_GROUP" --name "$ACA_ENV_NAME" --query properties.staticIp -o tsv)"

az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$REPO_ROOT/infra/main.bicep" \
  --parameters prefix="$PREFIX" imageName="$IMAGE_NAME" terminationGracePeriodSeconds="$GRACE_SECONDS" drainReadinessOnSigterm="$DRAIN_ON_SIGTERM" revisionMode="$REVISION_MODE" concurrentRequests="$CONCURRENT_REQUESTS" minReplicas="$MIN_REPLICAS" maxReplicas="$MAX_REPLICAS" appGatewayRequestTimeout="$APPGW_REQUEST_TIMEOUT_SECONDS" privateDnsZoneName="$PRIVATE_DNS_ZONE_NAME" managedEnvironmentStaticIp="$MANAGED_ENV_STATIC_IP"
