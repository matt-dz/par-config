#!/bin/bash
#
# get-agent-status.sh
# Retrieves the Datadog Agent status in JSON format via kubectl exec
#
# Usage: get-agent-status.sh [OPTIONS]
# Options:
#   --namespace, -n <ns>     Kubernetes namespace (default: from DD_AGENT_NAMESPACE or "default")
#   --pod, -p <pod>          Specific agent pod (optional, defaults to first available)
#   --node <node>            Target agent on specific node
#   --section <section>      Filter to specific status section (partial match supported)
#   --list-sections          List all available sections
#   --include-cluster-agent  Also fetch Cluster Agent status (default: true)
#   --no-cluster-agent       Skip Cluster Agent status
#   --all                    Get status from all node agents
#
# Output: JSON with agent health, running checks, connectivity info
#

set -euo pipefail

# Source common helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/agent-exec.sh"

# Defaults
NAMESPACE="${DD_NAMESPACE}"
POD=""
NODE=""
SECTION=""
LIST_SECTIONS=false
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
        --section)
            SECTION="$2"
            shift 2
            ;;
        --list-sections)
            LIST_SECTIONS=true
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

# Function to get status from a single agent pod
get_agent_status() {
    local ns="$1"
    local pod="$2"
    local section="$3"

    local status_json
    status_json=$(agent_command "$ns" "$pod" status --json 2>/dev/null) || {
        echo '{"error": "Failed to get agent status"}'
        return 1
    }

    if [[ -n "$section" ]]; then
        echo "$status_json" | jq --arg section "$section" '
            # Try exact match first, then case-insensitive partial match
            if .[$section] then .[$section]
            else
                # Find keys that contain the section string (case-insensitive)
                (keys | map(select(ascii_downcase | contains($section | ascii_downcase)))) as $matches |
                if ($matches | length) == 1 then
                    .[$matches[0]]
                elif ($matches | length) > 1 then
                    {"error": "Multiple sections match", "matches": $matches}
                else
                    {"error": "Section not found", "available_sections": keys}
                end
            end
        '
    else
        echo "$status_json"
    fi
}

# Function to get cluster agent status
get_cluster_agent_status() {
    local ns="$1"
    local section="$2"

    local cluster_pod
    cluster_pod=$(discover_cluster_agent_pod "$ns") || {
        echo '{"error": "Cluster agent not found"}'
        return 1
    }

    local status_json
    status_json=$(cluster_agent_command "$ns" "$cluster_pod" status --json 2>/dev/null) || {
        echo '{"error": "Failed to get cluster agent status", "pod": "'"$cluster_pod"'"}'
        return 1
    }

    if [[ -n "$section" ]]; then
        echo "$status_json" | jq --arg section "$section" '
            if .[$section] then .[$section]
            else
                (keys | map(select(ascii_downcase | contains($section | ascii_downcase)))) as $matches |
                if ($matches | length) == 1 then
                    .[$matches[0]]
                elif ($matches | length) > 1 then
                    {"error": "Multiple sections match", "matches": $matches}
                else
                    {"error": "Section not found", "available_sections": keys}
                end
            end
        '
    else
        echo "$status_json"
    fi
}

# List sections mode - get from first available agent
if [[ "$LIST_SECTIONS" == true ]]; then
    pod=$(discover_single_agent_pod "$NAMESPACE" "$POD" "$NODE")
    agent_command "$NAMESPACE" "$pod" status --json 2>/dev/null | jq 'keys'
    exit 0
fi

# Build output based on mode
if [[ "$ALL_AGENTS" == true ]]; then
    # Get status from all node agents
    echo "{"
    echo '  "nodeAgents": ['

    first=true
    while IFS=' ' read -r pod node; do
        [[ -z "$pod" ]] && continue

        if [[ "$first" != true ]]; then
            echo ","
        fi
        first=false

        status=$(get_agent_status "$NAMESPACE" "$pod" "$SECTION")
        node_name=$(get_pod_node "$NAMESPACE" "$pod")

        echo "    {"
        echo "      \"pod\": \"$pod\","
        echo "      \"node\": \"$node_name\","
        echo "      \"status\": $status"
        echo -n "    }"
    done < <(discover_agent_pods "$NAMESPACE" "$NODE")

    echo ""
    echo "  ]"

    # Add cluster agent status if requested
    if [[ "$INCLUDE_CLUSTER_AGENT" == true ]]; then
        cluster_status=$(get_cluster_agent_status "$NAMESPACE" "$SECTION")
        cluster_pod=$(discover_cluster_agent_pod "$NAMESPACE" 2>/dev/null || echo "")

        echo '  ,"clusterAgent": {'
        echo "    \"pod\": \"$cluster_pod\","
        echo "    \"status\": $cluster_status"
        echo "  }"
    fi

    echo "}"
else
    # Single agent mode
    pod=$(discover_single_agent_pod "$NAMESPACE" "$POD" "$NODE")
    node_name=$(get_pod_node "$NAMESPACE" "$pod")

    if [[ "$INCLUDE_CLUSTER_AGENT" == true ]]; then
        # Combined output
        agent_status=$(get_agent_status "$NAMESPACE" "$pod" "$SECTION")
        cluster_status=$(get_cluster_agent_status "$NAMESPACE" "$SECTION")
        cluster_pod=$(discover_cluster_agent_pod "$NAMESPACE" 2>/dev/null || echo "")

        jq -n \
            --arg pod "$pod" \
            --arg node "$node_name" \
            --argjson agent_status "$agent_status" \
            --arg cluster_pod "$cluster_pod" \
            --argjson cluster_status "$cluster_status" \
            '{
                nodeAgent: {
                    pod: $pod,
                    node: $node,
                    status: $agent_status
                },
                clusterAgent: {
                    pod: $cluster_pod,
                    status: $cluster_status
                }
            }'
    else
        # Just the agent status
        get_agent_status "$NAMESPACE" "$pod" "$SECTION"
    fi
fi
