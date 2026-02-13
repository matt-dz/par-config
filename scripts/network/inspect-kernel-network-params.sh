#!/bin/bash
#
# inspect-kernel-network-params.sh
# Inspects kernel network parameters (sysctl) on Datadog Agent pod (host network) via kubectl exec
#
# Usage: inspect-kernel-network-params.sh [OPTIONS]
# Options:
#   --namespace, -n <ns>  Kubernetes namespace (default: from DD_AGENT_NAMESPACE or "default")
#   --pod, -p <pod>       Specific agent pod (optional, defaults to first available)
#   --node <node>         Target agent on specific node
#   --filter <pattern>    Filter parameters by pattern (e.g., "ipv4.tcp")
#   --category <cat>      Filter by category: core, ipv4, ipv6, bridge, netfilter
#   --all                 Get params from all node agents
#
# Output: JSON with kernel network parameters
#

set -euo pipefail

# Source common helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/agent-exec.sh"

# Defaults
NAMESPACE="${DD_NAMESPACE}"
POD=""
NODE=""
FILTER_PATTERN=""
CATEGORY=""
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
        --filter)
            FILTER_PATTERN="$2"
            shift 2
            ;;
        --category)
            CATEGORY="$2"
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

# Function to get kernel network params from agent pod
get_kernel_params() {
    local ns="$1"
    local pod="$2"
    local filter="$3"
    local category="$4"

    # Build grep pattern based on category
    local grep_pattern="^net\."
    case "$category" in
        core)
            grep_pattern="^net\.core\."
            ;;
        ipv4)
            grep_pattern="^net\.ipv4\."
            ;;
        ipv6)
            grep_pattern="^net\.ipv6\."
            ;;
        bridge)
            grep_pattern="^net\.bridge\."
            ;;
        netfilter)
            grep_pattern="^net\.netfilter\."
            ;;
        "")
            grep_pattern="^net\."
            ;;
        *)
            grep_pattern="^net\.${category}\."
            ;;
    esac

    # Get sysctl values
    local output
    output=$(exec_on_agent "$ns" "$pod" sh -c "sysctl -a 2>/dev/null | grep -E '$grep_pattern'" 2>/dev/null) || {
        echo '{}'
        return 1
    }

    # Apply additional filter if specified
    if [[ -n "$filter" ]]; then
        output=$(echo "$output" | grep -i "$filter" || true)
    fi

    # Parse sysctl output to JSON
    echo "$output" | awk '
    BEGIN {
        print "{"
        first = 1
    }
    /=/ {
        # Split on first = only
        eq_pos = index($0, "=")
        if (eq_pos > 0) {
            key = substr($0, 1, eq_pos - 1)
            value = substr($0, eq_pos + 1)
            # Trim whitespace
            gsub(/^[ \t]+|[ \t]+$/, "", key)
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            # Escape special characters in value
            gsub(/\\/, "\\\\", value)
            gsub(/"/, "\\\"", value)
            gsub(/\t/, "\\t", value)

            if (!first) print ","
            first = 0

            # Try to detect if value is numeric
            if (value ~ /^-?[0-9]+$/) {
                printf "  \"%s\": %s", key, value
            } else {
                printf "  \"%s\": \"%s\"", key, value
            }
        }
    }
    END {
        print "\n}"
    }
    '
}

# Build output based on mode
if [[ "$ALL_AGENTS" == true ]]; then
    # Get params from all node agents
    echo "{"
    echo '  "nodeAgents": ['

    first=true
    while IFS=' ' read -r pod node; do
        [[ -z "$pod" ]] && continue

        if [[ "$first" != true ]]; then
            echo ","
        fi
        first=false

        params=$(get_kernel_params "$NAMESPACE" "$pod" "$FILTER_PATTERN" "$CATEGORY")
        node_name=$(get_pod_node "$NAMESPACE" "$pod")

        echo "    {"
        echo "      \"pod\": \"$pod\","
        echo "      \"node\": \"$node_name\","
        echo "      \"params\": $params"
        echo -n "    }"
    done < <(discover_agent_pods "$NAMESPACE" "$NODE")

    echo ""
    echo "  ]"
    echo "}"
else
    # Single agent mode
    pod=$(discover_single_agent_pod "$NAMESPACE" "$POD" "$NODE")
    node_name=$(get_pod_node "$NAMESPACE" "$pod")

    params=$(get_kernel_params "$NAMESPACE" "$pod" "$FILTER_PATTERN" "$CATEGORY")

    jq -n \
        --arg pod "$pod" \
        --arg node "$node_name" \
        --argjson params "$params" \
        '{
            pod: $pod,
            node: $node,
            params: $params
        }'
fi
