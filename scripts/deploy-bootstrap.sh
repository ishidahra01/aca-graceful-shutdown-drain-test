#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <subscription-id> <location> <prefix> [resource-group-name]" >&2
  exit 1
fi

SUBSCRIPTION_ID="$1"
LOCATION="$2"
PREFIX="$3"
RESOURCE_GROUP_NAME="${4:-${PREFIX}-rg}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

az account set --subscription "$SUBSCRIPTION_ID"
az deployment sub create \
  --location "$LOCATION" \
  --template-file "$REPO_ROOT/infra/bootstrap.bicep" \
  --parameters location="$LOCATION" prefix="$PREFIX" resourceGroupName="$RESOURCE_GROUP_NAME"
