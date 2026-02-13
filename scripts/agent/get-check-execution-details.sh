#!/bin/bash
#
# get-check-execution-details.sh
# Retrieves execution details (runnerStats) for Datadog Agent checks via kubectl exec
#
# Usage: get-check-execution-details.sh [OPTIONS]
# Options:
#   --namespace, -n <ns>  Kubernetes namespace (default: from DD_AGENT_NAMESPACE or "default")
#   --pod, -p <pod>       Specific agent pod (optional, defaults to first available)
#   --node <node>         Target agent on specific node
#   --check <name>        Filter to specific check (partial match supported)
#   --format <format>     Output format: full, summary (default: full)
#   --all                 Get check details from all node agents
#
# Output: JSON with check execution statistics and metrics
#

set -euo pipefail

# Source common helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/agent-exec.sh"

# Defaults
NAMESPACE="${DD_NAMESPACE}"
POD=""
NODE=""
CHECK_FILTER=""
FORMAT="full"
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
        --check)
            CHECK_FILTER="$2"
            shift 2
            ;;
        --format)
            FORMAT="$2"
            shift 2
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

# Function to extract check execution details from agent status
get_check_details() {
    local ns="$1"
    local pod="$2"
    local filter="$3"
    local format="$4"

    local status_json
    status_json=$(agent_command "$ns" "$pod" status --json 2>/dev/null) || {
        echo '{"error": "Failed to get agent status"}'
        return 1
    }

    # Extract runnerStats and filter/format
    if [[ "$format" == "summary" ]]; then
        echo "$status_json" | jq --arg filter "$filter" '
            .runnerStats // {} |
            to_entries |
            map(select(
                $filter == "" or
                (.key | ascii_downcase | contains($filter | ascii_downcase))
            )) |
            map({
                check: .key,
                lastRun: .value.LastRun,
                averageExecutionTime: .value.AverageExecutionTime,
                lastExecutionTime: .value.LastExecutionTime,
                errors: (.value.Errors // 0),
                warnings: (.value.Warnings // 0)
            })
        '
    else
        echo "$status_json" | jq --arg filter "$filter" '
            .runnerStats // {} |
            if $filter == "" then
                .
            else
                to_entries |
                map(select(
                    .key | ascii_downcase | contains($filter | ascii_downcase)
                )) |
                from_entries
            end
        '
    fi
}

# Build output based on mode
if [[ "$ALL_AGENTS" == true ]]; then
    # Get check details from all node agents
    echo "{"
    echo '  "nodeAgents": ['

    first=true
    while IFS=' ' read -r pod node; do
        [[ -z "$pod" ]] && continue

        if [[ "$first" != true ]]; then
            echo ","
        fi
        first=false

        details=$(get_check_details "$NAMESPACE" "$pod" "$CHECK_FILTER" "$FORMAT")
        node_name=$(get_pod_node "$NAMESPACE" "$pod")

        echo "    {"
        echo "      \"pod\": \"$pod\","
        echo "      \"node\": \"$node_name\","
        echo "      \"checkDetails\": $details"
        echo -n "    }"
    done < <(discover_agent_pods "$NAMESPACE" "$NODE")

    echo ""
    echo "  ]"
    echo "}"
else
    # Single agent mode
    pod=$(discover_single_agent_pod "$NAMESPACE" "$POD" "$NODE")
    node_name=$(get_pod_node "$NAMESPACE" "$pod")

    details=$(get_check_details "$NAMESPACE" "$pod" "$CHECK_FILTER" "$FORMAT")

    jq -n \
        --arg pod "$pod" \
        --arg node "$node_name" \
        --argjson details "$details" \
        '{
            pod: $pod,
            node: $node,
            checkDetails: $details
        }'
fi
