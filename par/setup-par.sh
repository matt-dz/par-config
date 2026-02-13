#!/bin/bash
# Deploy Private Action Runner with kubectl support
# Usage: ./setup-par.sh [cluster-name]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${1:-par-dev}"
IMAGE_NAME="par-runner-kubectl"
IMAGE_TAG="latest"
RELEASE_NAME="datadog-par"
NAMESPACE="default"

echo "=== Setting up Private Action Runner ==="

# Build custom Docker image with kubectl
echo "=== Building custom PAR image with kubectl ==="
cd "${SCRIPT_DIR}"

if [[ ! -f "Dockerfile" ]]; then
    echo "Error: Dockerfile not found in ${SCRIPT_DIR}"
    exit 1
fi

# Build from parent directory to include scripts/ in context
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" -f Dockerfile ..

# Load image into Kind cluster
echo "=== Loading image into Kind cluster ==="
kind load docker-image "${IMAGE_NAME}:${IMAGE_TAG}" --name "${CLUSTER_NAME}"

# Apply RBAC configuration
echo "=== Applying RBAC configuration ==="
if [[ -f "${SCRIPT_DIR}/rbac.yaml" ]]; then
    kubectl apply -f "${SCRIPT_DIR}/rbac.yaml"
else
    echo "Warning: rbac.yaml not found, skipping RBAC setup"
fi

# Create/update script credentials secret
echo "=== Applying script credentials ==="
if [[ -f "${SCRIPT_DIR}/script.yaml" ]]; then
    kubectl create secret generic par-script-credentials \
        --from-file=script.yaml="${SCRIPT_DIR}/script.yaml" \
        --namespace="${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
else
    echo "Warning: script.yaml not found, skipping credentials setup"
fi

# Update Helm repo
echo "=== Updating Helm repos ==="
helm repo update datadog

# Check if release exists
if helm status "${RELEASE_NAME}" --namespace="${NAMESPACE}" >/dev/null 2>&1; then
    echo "=== Upgrading existing PAR release ==="
    ACTION="upgrade"
else
    echo "=== Installing Private Action Runner ==="
    ACTION="install"
fi

# Install/upgrade PAR
helm ${ACTION} "${RELEASE_NAME}" datadog/private-action-runner \
    --namespace="${NAMESPACE}" \
    --values="${SCRIPT_DIR}/values.yaml" \
    --wait \
    --timeout=5m

# Wait for pod to be ready
echo "=== Waiting for PAR pod ==="
sleep 5
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/instance="${RELEASE_NAME}" --timeout=120s --namespace="${NAMESPACE}" || true

# Show status
echo "=== PAR Status ==="
kubectl get pods -l app.kubernetes.io/instance="${RELEASE_NAME}" --namespace="${NAMESPACE}"

# Verify kubectl is available
echo ""
echo "=== Verifying kubectl in PAR pod ==="
PAR_POD=$(kubectl get pods -l app.kubernetes.io/instance="${RELEASE_NAME}" -o jsonpath='{.items[0].metadata.name}' --namespace="${NAMESPACE}")
if kubectl exec "${PAR_POD}" --namespace="${NAMESPACE}" -- kubectl version --client 2>/dev/null; then
    echo "kubectl is available in PAR pod"
else
    echo "Warning: kubectl verification failed"
fi

# Verify pods/exec permission
echo ""
echo "=== Verifying pods/exec RBAC permission ==="
if kubectl exec "${PAR_POD}" --namespace="${NAMESPACE}" -- kubectl auth can-i create pods/exec 2>/dev/null; then
    echo "pods/exec permission: GRANTED"
else
    echo "Warning: pods/exec permission check failed"
fi

echo ""
echo "=== Private Action Runner deployed! ==="
echo ""
echo "Test kubectl exec into Datadog Agent:"
echo "  kubectl exec ${PAR_POD} -- kubectl exec <agent-pod> -c agent -- /opt/datadog-agent/bin/agent/agent version"
