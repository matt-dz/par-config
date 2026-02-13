#!/bin/bash
#
# agent-exec.sh
# Shared helper for Datadog Agent pod discovery and command execution
#
# This script provides common functions for discovering and executing
# commands on Datadog Agent and Cluster Agent pods via kubectl exec.
#
# Usage: Source this file in other scripts
#   source "$(dirname "$0")/../common/agent-exec.sh"
#

# Configuration - can be overridden via environment variables
DD_NAMESPACE="${DD_AGENT_NAMESPACE:-default}"
DD_AGENT_SELECTOR="app.kubernetes.io/name=datadog"
DD_AGENT_CONTAINER="${DD_AGENT_CONTAINER:-agent}"
DD_CLUSTER_AGENT_SELECTOR="app.kubernetes.io/component=cluster-agent"
DD_CLUSTER_AGENT_CONTAINER="${DD_CLUSTER_AGENT_CONTAINER:-cluster-agent}"
DD_AGENT_BIN="${DD_AGENT_BIN:-/opt/datadog-agent/bin/agent/agent}"
DD_CLUSTER_AGENT_BIN="${DD_CLUSTER_AGENT_BIN:-/opt/datadog-agent/bin/cluster-agent/cluster-agent}"

# Output helpers
json_error() {
    local message="$1"
    echo "{\"error\": \"$message\"}" >&2
    exit 1
}

json_warning() {
    local message="$1"
    echo "{\"warning\": \"$message\"}" >&2
}

# Verify kubectl is available
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        json_error "kubectl command not found"
    fi
}

# Discover node agent pods
# Args:
#   $1 - namespace (optional, defaults to DD_NAMESPACE)
#   $2 - node filter (optional, only return pod on specific node)
# Output: Lines of "pod_name node_name" pairs
discover_agent_pods() {
    local namespace="${1:-$DD_NAMESPACE}"
    local node="$2"

    check_kubectl

    local selector="${DD_AGENT_SELECTOR}"
    # Filter to node agents only (not cluster agent)
    local label_selector="${selector},app.kubernetes.io/component=agent"

    local cmd="kubectl get pods -n ${namespace} -l ${label_selector}"

    if [[ -n "$node" ]]; then
        cmd+=" --field-selector spec.nodeName=${node}"
    fi

    cmd+=" -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName}{\"\\n\"}{end}'"

    eval "$cmd" 2>/dev/null | grep -v '^$'
}

# Discover a single agent pod (first available or specific)
# Args:
#   $1 - namespace (optional)
#   $2 - pod name (optional, if not provided returns first available)
#   $3 - node filter (optional)
# Output: Single pod name
discover_single_agent_pod() {
    local namespace="${1:-$DD_NAMESPACE}"
    local pod="$2"
    local node="$3"

    if [[ -n "$pod" ]]; then
        # Verify the pod exists
        if kubectl get pod -n "${namespace}" "${pod}" &>/dev/null; then
            echo "$pod"
        else
            json_error "Pod '${pod}' not found in namespace '${namespace}'"
        fi
    else
        # Get first available pod
        local result
        result=$(discover_agent_pods "$namespace" "$node" | head -1 | awk '{print $1}')
        if [[ -z "$result" ]]; then
            json_error "No agent pods found in namespace '${namespace}'"
        fi
        echo "$result"
    fi
}

# Discover cluster agent pod
# Args:
#   $1 - namespace (optional, defaults to DD_NAMESPACE)
# Output: Cluster agent pod name
discover_cluster_agent_pod() {
    local namespace="${1:-$DD_NAMESPACE}"

    check_kubectl

    local result
    result=$(kubectl get pods -n "${namespace}" -l "${DD_CLUSTER_AGENT_SELECTOR}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "$result" ]]; then
        return 1
    fi
    echo "$result"
}

# Execute command on agent pod
# Args:
#   $1 - namespace
#   $2 - pod name
#   $@ - command and arguments
exec_on_agent() {
    local namespace="$1"
    local pod="$2"
    shift 2

    kubectl exec -n "${namespace}" "${pod}" -c "${DD_AGENT_CONTAINER}" -- "$@"
}

# Execute command on cluster agent pod
# Args:
#   $1 - namespace
#   $2 - pod name
#   $@ - command and arguments
exec_on_cluster_agent() {
    local namespace="$1"
    local pod="$2"
    shift 2

    kubectl exec -n "${namespace}" "${pod}" -c "${DD_CLUSTER_AGENT_CONTAINER}" -- "$@"
}

# Run agent CLI command on node agent
# Args:
#   $1 - namespace
#   $2 - pod name
#   $@ - agent subcommand and arguments
agent_command() {
    local namespace="$1"
    local pod="$2"
    shift 2

    exec_on_agent "$namespace" "$pod" "${DD_AGENT_BIN}" "$@"
}

# Run cluster agent CLI command
# Args:
#   $1 - namespace
#   $2 - pod name
#   $@ - cluster-agent subcommand and arguments
cluster_agent_command() {
    local namespace="$1"
    local pod="$2"
    shift 2

    exec_on_cluster_agent "$namespace" "$pod" "${DD_CLUSTER_AGENT_BIN}" "$@"
}

# Get node name for a pod
# Args:
#   $1 - namespace
#   $2 - pod name
# Output: Node name
get_pod_node() {
    local namespace="$1"
    local pod="$2"

    kubectl get pod -n "${namespace}" "${pod}" -o jsonpath='{.spec.nodeName}' 2>/dev/null
}

# Parse common arguments for namespace, pod, and node
# This function sets global variables: PARSED_NAMESPACE, PARSED_POD, PARSED_NODE
# Args: "$@" - all script arguments
# Returns: Remaining arguments after parsing common ones
parse_common_args() {
    PARSED_NAMESPACE="${DD_NAMESPACE}"
    PARSED_POD=""
    PARSED_NODE=""

    local remaining_args=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            --namespace|-n)
                PARSED_NAMESPACE="$2"
                shift 2
                ;;
            --pod|-p)
                PARSED_POD="$2"
                shift 2
                ;;
            --node)
                PARSED_NODE="$2"
                shift 2
                ;;
            *)
                remaining_args+=("$1")
                shift
                ;;
        esac
    done

    # Return remaining args
    echo "${remaining_args[@]}"
}

# Execute command on all agent pods and collect results as JSON array
# Args:
#   $1 - namespace
#   $2 - node filter (optional, empty string for all nodes)
#   $@ - command and arguments to execute
exec_on_all_agents() {
    local namespace="$1"
    local node_filter="$2"
    shift 2

    local results="["
    local first=true

    while IFS=' ' read -r pod node; do
        [[ -z "$pod" ]] && continue

        local output
        output=$(exec_on_agent "$namespace" "$pod" "$@" 2>/dev/null) || output="{\"error\": \"command failed\"}"

        if [[ "$first" != true ]]; then
            results+=","
        fi
        first=false

        results+="{\"pod\": \"$pod\", \"node\": \"$node\", \"result\": $output}"
    done < <(discover_agent_pods "$namespace" "$node_filter")

    results+="]"
    echo "$results"
}
