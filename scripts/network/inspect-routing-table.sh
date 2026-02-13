#!/bin/bash
#
# inspect-routing-table.sh
# Inspects routing table on Datadog Agent pod (host network) via kubectl exec
#
# Usage: inspect-routing-table.sh [OPTIONS]
# Options:
#   --namespace, -n <ns>  Kubernetes namespace (default: from DD_AGENT_NAMESPACE or "default")
#   --pod, -p <pod>       Specific agent pod (optional, defaults to first available)
#   --node <node>         Target agent on specific node
#   --table <table>       Routing table to show (main, local, all)
#   --ipv4                Show IPv4 routes only
#   --ipv6                Show IPv6 routes only
#   --all                 Get routes from all node agents
#
# Output: JSON with routing table entries
#

set -euo pipefail

# Source common helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/agent-exec.sh"

# Defaults
NAMESPACE="${DD_NAMESPACE}"
POD=""
NODE=""
TABLE=""
IPV4_ONLY=false
IPV6_ONLY=false
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
        --table)
            TABLE="$2"
            shift 2
            ;;
        --ipv4)
            IPV4_ONLY=true
            shift
            ;;
        --ipv6)
            IPV6_ONLY=true
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

# Function to get routing table from agent pod
get_routes() {
    local ns="$1"
    local pod="$2"

    local results="{"
    local first=true

    # Get IPv4 routes
    if [[ "$IPV6_ONLY" != true ]]; then
        local cmd="ip -j route show"
        [[ -n "$TABLE" ]] && cmd+=" table $TABLE"

        local ipv4_output
        ipv4_output=$(exec_on_agent "$ns" "$pod" sh -c "$cmd 2>/dev/null" 2>/dev/null)

        if [[ -n "$ipv4_output" ]] && echo "$ipv4_output" | jq -e . >/dev/null 2>&1; then
            results+="\"ipv4\": $ipv4_output"
            first=false
        else
            # Fallback to parsing text output
            cmd="ip route show"
            [[ -n "$TABLE" ]] && cmd+=" table $TABLE"
            ipv4_output=$(exec_on_agent "$ns" "$pod" sh -c "$cmd 2>/dev/null" 2>/dev/null) || ipv4_output=""

            local ipv4_json
            ipv4_json=$(echo "$ipv4_output" | awk '
            BEGIN { print "["; first=1 }
            NF > 0 {
                if (!first) print ","
                first = 0
                dst = $1
                gateway = ""
                dev = ""
                src = ""
                metric = ""
                for (i=2; i<=NF; i++) {
                    if ($i == "via") { gateway = $(i+1); i++ }
                    else if ($i == "dev") { dev = $(i+1); i++ }
                    else if ($i == "src") { src = $(i+1); i++ }
                    else if ($i == "metric") { metric = $(i+1); i++ }
                }
                printf "  {\"dst\":\"%s\"", dst
                if (gateway != "") printf ",\"gateway\":\"%s\"", gateway
                if (dev != "") printf ",\"dev\":\"%s\"", dev
                if (src != "") printf ",\"prefsrc\":\"%s\"", src
                if (metric != "") printf ",\"metric\":%s", metric
                printf "}"
            }
            END { print "\n]" }
            ')
            results+="\"ipv4\": $ipv4_json"
            first=false
        fi
    fi

    # Get IPv6 routes
    if [[ "$IPV4_ONLY" != true ]]; then
        [[ "$first" != true ]] && results+=","

        local cmd="ip -j -6 route show"
        [[ -n "$TABLE" ]] && cmd+=" table $TABLE"

        local ipv6_output
        ipv6_output=$(exec_on_agent "$ns" "$pod" sh -c "$cmd 2>/dev/null" 2>/dev/null)

        if [[ -n "$ipv6_output" ]] && echo "$ipv6_output" | jq -e . >/dev/null 2>&1; then
            results+="\"ipv6\": $ipv6_output"
        else
            # Fallback to parsing text output
            cmd="ip -6 route show"
            [[ -n "$TABLE" ]] && cmd+=" table $TABLE"
            ipv6_output=$(exec_on_agent "$ns" "$pod" sh -c "$cmd 2>/dev/null" 2>/dev/null) || ipv6_output=""

            local ipv6_json
            ipv6_json=$(echo "$ipv6_output" | awk '
            BEGIN { print "["; first=1 }
            NF > 0 {
                if (!first) print ","
                first = 0
                dst = $1
                gateway = ""
                dev = ""
                metric = ""
                for (i=2; i<=NF; i++) {
                    if ($i == "via") { gateway = $(i+1); i++ }
                    else if ($i == "dev") { dev = $(i+1); i++ }
                    else if ($i == "metric") { metric = $(i+1); i++ }
                }
                printf "  {\"dst\":\"%s\"", dst
                if (gateway != "") printf ",\"gateway\":\"%s\"", gateway
                if (dev != "") printf ",\"dev\":\"%s\"", dev
                if (metric != "") printf ",\"metric\":%s", metric
                printf "}"
            }
            END { print "\n]" }
            ')
            results+="\"ipv6\": $ipv6_json"
        fi
    fi

    results+="}"
    echo "$results"
}

# Build output based on mode
if [[ "$ALL_AGENTS" == true ]]; then
    # Get routes from all node agents
    echo "{"
    echo '  "nodeAgents": ['

    first=true
    while IFS=' ' read -r pod node; do
        [[ -z "$pod" ]] && continue

        if [[ "$first" != true ]]; then
            echo ","
        fi
        first=false

        routes=$(get_routes "$NAMESPACE" "$pod")
        node_name=$(get_pod_node "$NAMESPACE" "$pod")

        echo "    {"
        echo "      \"pod\": \"$pod\","
        echo "      \"node\": \"$node_name\","
        echo "      \"routes\": $routes"
        echo -n "    }"
    done < <(discover_agent_pods "$NAMESPACE" "$NODE")

    echo ""
    echo "  ]"
    echo "}"
else
    # Single agent mode
    pod=$(discover_single_agent_pod "$NAMESPACE" "$POD" "$NODE")
    node_name=$(get_pod_node "$NAMESPACE" "$pod")

    routes=$(get_routes "$NAMESPACE" "$pod")

    jq -n \
        --arg pod "$pod" \
        --arg node "$node_name" \
        --argjson routes "$routes" \
        '{
            pod: $pod,
            node: $node,
            routes: $routes
        }'
fi
