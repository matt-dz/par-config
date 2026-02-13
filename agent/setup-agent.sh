#!/bin/bash
# Deploy Datadog Agent to Kind cluster
# Usage: ./setup-agent.sh [api-key] [app-key]
#
# If keys are not provided, will prompt for them or use environment variables:
#   DD_API_KEY (required), DD_APP_KEY (optional)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/datadog-agent-values.yaml"
RELEASE_NAME="datadog-agent"
NAMESPACE="default"

echo "=== Deploying Datadog Agent ==="

# Get API key (required)
if [[ -n "${1:-}" ]]; then
    DD_API_KEY="$1"
elif [[ -z "${DD_API_KEY:-}" ]]; then
    read -sp "Enter Datadog API Key: " DD_API_KEY
    echo
fi

# Get App key (optional)
if [[ -n "${2:-}" ]]; then
    DD_APP_KEY="$2"
elif [[ -z "${DD_APP_KEY:-}" ]]; then
    read -sp "Enter Datadog App Key (optional, press Enter to skip): " DD_APP_KEY
    echo
fi

# Validate API key (required)
if [[ -z "${DD_API_KEY:-}" ]]; then
    echo "Error: API key is required"
    exit 1
fi

# Create or update secret
echo "=== Creating Datadog secret ==="
if [[ -n "${DD_APP_KEY:-}" ]]; then
    kubectl create secret generic datadog-secret \
        --from-literal=api-key="${DD_API_KEY}" \
        --from-literal=app-key="${DD_APP_KEY}" \
        --namespace="${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
else
    echo "Note: App key not provided, creating secret with API key only"
    kubectl create secret generic datadog-secret \
        --from-literal=api-key="${DD_API_KEY}" \
        --namespace="${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
fi

# Update Helm repo
echo "=== Updating Helm repos ==="
helm repo update datadog

# Check if release exists
if helm status "${RELEASE_NAME}" --namespace="${NAMESPACE}" >/dev/null 2>&1; then
    echo "=== Upgrading existing Datadog Agent release ==="
    ACTION="upgrade"
else
    echo "=== Installing Datadog Agent ==="
    ACTION="install"
fi

# Install/upgrade Datadog Agent
helm ${ACTION} "${RELEASE_NAME}" datadog/datadog \
    --namespace="${NAMESPACE}" \
    --values="${VALUES_FILE}" \
    --wait \
    --timeout=5m

# Wait for pods to be ready
echo "=== Waiting for Datadog Agent pods ==="
kubectl wait --for=condition=Ready pods -l app=datadog --timeout=120s --namespace="${NAMESPACE}" || true
kubectl wait --for=condition=Ready pods -l app=datadog-cluster-agent --timeout=120s --namespace="${NAMESPACE}" || true

# Show status
echo "=== Datadog Agent Status ==="
kubectl get pods -l app.kubernetes.io/name=datadog --namespace="${NAMESPACE}"

echo ""
echo "=== Datadog Agent deployed! ==="
echo "Next: Run ~/par/setup-par.sh to deploy the Private Action Runner"
