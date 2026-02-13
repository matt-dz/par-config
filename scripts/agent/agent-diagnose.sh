#!/bin/bash
#
# agent-diagnose.sh
# Runs Datadog Agent diagnostics and returns results in JSON format via kubectl exec
#
# Usage: agent-diagnose.sh [OPTIONS]
# Options:
#   --namespace, -n <ns>     Kubernetes namespace (default: from DD_AGENT_NAMESPACE or "default")
#   --pod, -p <pod>          Specific agent pod (optional, defaults to first available)
#   --node <node>            Target agent on specific node
#   --include, -i <suite>    Only run specific diagnostic suites (regex)
#   --exclude, -e <suite>    Exclude specific diagnostic suites (regex)
#   --list, -l               List available diagnostic suites
#   --verbose, -v            Include passed diagnoses and descriptions
#   --include-cluster-agent  Also run diagnostics on Cluster Agent (default: true)
#   --no-cluster-agent       Skip Cluster Agent diagnostics
#   --all                    Run diagnostics on all node agents
#
# Output: JSON with diagnostic results
#

set -euo pipefail

# Source common helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/agent-exec.sh"

# Defaults
NAMESPACE="${DD_NAMESPACE}"
POD=""
NODE=""
INCLUDE=""
EXCLUDE=""
LIST=false
VERBOSE=false
INCLUDE_CLUSTER_AGENT=true
ALL_AGENTS=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n)
            NAMESPACE="$2"
            shift 2
            ;;
        --pod|-p)
            POD="$2"
            shift 2
            ;;
        --node)
            NODE="$2"
            shift 2
            ;;
        --include|-i)
            INCLUDE="$2"
            shift 2
            ;;
        --exclude|-e)
            EXCLUDE="$2"
            shift 2
            ;;
        --list|-l)
            LIST=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --include-cluster-agent)
            INCLUDE_CLUSTER_AGENT=true
            shift
            ;;
        --no-cluster-agent)
            INCLUDE_CLUSTER_AGENT=false
            shift
            ;;
        --all)
            ALL_AGENTS=true
            shift
            ;;
        *)
            json_error "Unknown argument: $1"
            ;;
    esac
done

# Verify kubectl is available
check_kubectl

# Build diagnose command arguments
build_diagnose_args() {
    local args="diagnose --json"

    if [[ "$LIST" == true ]]; then
        args+=" --list"
    fi

    if [[ -n "$INCLUDE" ]]; then
        args+=" --include $INCLUDE"
    fi

    if [[ -n "$EXCLUDE" ]]; then
        args+=" --exclude $EXCLUDE"
    fi

    if [[ "$VERBOSE" == true ]]; then
        args+=" --verbose"
    fi

    echo "$args"
}

# Function to run diagnose on a node agent
run_agent_diagnose() {
    local ns="$1"
    local pod="$2"

    local args
    args=$(build_diagnose_args)

    # shellcheck disable=SC2086
    agent_command "$ns" "$pod" $args 2>/dev/null || echo '{"error": "Failed to run agent diagnose"}'
}

# Function to run diagnose on cluster agent
run_cluster_agent_diagnose() {
    local ns="$1"

    local cluster_pod
    cluster_pod=$(discover_cluster_agent_pod "$ns") || {
        echo '{"error": "Cluster agent not found"}'
        return 1
    }

    local args
    args=$(build_diagnose_args)

    # shellcheck disable=SC2086
    cluster_agent_command "$ns" "$cluster_pod" $args 2>/dev/null || echo '{"error": "Failed to run cluster agent diagnose", "pod": "'"$cluster_pod"'"}'
}

# List mode - get from first available agent
if [[ "$LIST" == true ]]; then
    pod=$(discover_single_agent_pod "$NAMESPACE" "$POD" "$NODE")
    run_agent_diagnose "$NAMESPACE" "$pod"
    exit 0
fi

# Build output based on mode
if [[ "$ALL_AGENTS" == true ]]; then
    # Run diagnostics on all node agents
    echo "{"
    echo '  "nodeAgents": ['

    first=true
    while IFS=' ' read -r pod node; do
        [[ -z "$pod" ]] && continue

        if [[ "$first" != true ]]; then
            echo ","
        fi
        first=false

        diagnose=$(run_agent_diagnose "$NAMESPACE" "$pod")
        node_name=$(get_pod_node "$NAMESPACE" "$pod")

        echo "    {"
        echo "      \"pod\": \"$pod\","
        echo "      \"node\": \"$node_name\","
        echo "      \"diagnose\": $diagnose"
        echo -n "    }"
    done < <(discover_agent_pods "$NAMESPACE" "$NODE")

    echo ""
    echo "  ]"

    # Add cluster agent diagnostics if requested
    if [[ "$INCLUDE_CLUSTER_AGENT" == true ]]; then
        cluster_diagnose=$(run_cluster_agent_diagnose "$NAMESPACE")
        cluster_pod=$(discover_cluster_agent_pod "$NAMESPACE" 2>/dev/null || echo "")

        echo '  ,"clusterAgent": {'
        echo "    \"pod\": \"$cluster_pod\","
        echo "    \"diagnose\": $cluster_diagnose"
        echo "  }"
    fi

    echo "}"
else
    # Single agent mode
    pod=$(discover_single_agent_pod "$NAMESPACE" "$POD" "$NODE")
    node_name=$(get_pod_node "$NAMESPACE" "$pod")

    if [[ "$INCLUDE_CLUSTER_AGENT" == true ]]; then
        # Combined output
        agent_diagnose=$(run_agent_diagnose "$NAMESPACE" "$pod")
        cluster_diagnose=$(run_cluster_agent_diagnose "$NAMESPACE")
        cluster_pod=$(discover_cluster_agent_pod "$NAMESPACE" 2>/dev/null || echo "")

        jq -n \
            --arg pod "$pod" \
            --arg node "$node_name" \
            --argjson agent_diagnose "$agent_diagnose" \
            --arg cluster_pod "$cluster_pod" \
            --argjson cluster_diagnose "$cluster_diagnose" \
            '{
                nodeAgent: {
                    pod: $pod,
                    node: $node,
                    diagnose: $agent_diagnose
                },
                clusterAgent: {
                    pod: $cluster_pod,
                    diagnose: $cluster_diagnose
                }
            }'
    else
        # Just the agent diagnose
        diagnose=$(run_agent_diagnose "$NAMESPACE" "$pod")

        jq -n \
            --arg pod "$pod" \
            --arg node "$node_name" \
            --argjson diagnose "$diagnose" \
            '{
                pod: $pod,
                node: $node,
                diagnose: $diagnose
            }'
    fi
fi
