#!/bin/bash
#
# inspect-network-interfaces.sh
# Inspects network interfaces on Datadog Agent pod (host network) via kubectl exec
#
# Usage: inspect-network-interfaces.sh [OPTIONS]
# Options:
#   --namespace, -n <ns>  Kubernetes namespace (default: from DD_AGENT_NAMESPACE or "default")
#   --pod, -p <pod>       Specific agent pod (optional, defaults to first available)
#   --node <node>         Target agent on specific node
#   --interface <name>    Filter to specific interface
#   --all                 Get interfaces from all node agents
#
# Output: JSON with network interface information including addresses and state
#

set -euo pipefail

# Source common helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/agent-exec.sh"

# Defaults
NAMESPACE="${DD_NAMESPACE}"
POD=""
NODE=""
INTERFACE_FILTER=""
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
        --interface)
            INTERFACE_FILTER="$2"
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

# Function to get network interfaces from agent pod
get_interfaces() {
    local ns="$1"
    local pod="$2"
    local interface="$3"

    # Try ip command with JSON output first
    local cmd="ip -j addr show"
    if [[ -n "$interface" ]]; then
        cmd+=" dev $interface"
    fi

    local output
    output=$(exec_on_agent "$ns" "$pod" sh -c "$cmd 2>/dev/null" 2>/dev/null)

    if [[ -n "$output" ]] && echo "$output" | jq -e . >/dev/null 2>&1; then
        # Successfully got JSON output
        echo "$output"
        return 0
    fi

    # Fallback to parsing text output
    cmd="ip addr show"
    if [[ -n "$interface" ]]; then
        cmd+=" dev $interface"
    fi

    output=$(exec_on_agent "$ns" "$pod" sh -c "$cmd 2>/dev/null" 2>/dev/null) || {
        echo '[]'
        return 1
    }

    # Parse ip addr show output to JSON
    echo "$output" | awk '
    BEGIN {
        print "["
        first_iface = 1
        iface_name = ""
        state = ""
        mtu = ""
        mac = ""
        in_addr = 0
    }
    /^[0-9]+:/ {
        # Print previous interface if exists
        if (iface_name != "") {
            if (!first_iface) print ","
            first_iface = 0
            printf "  {\"ifname\":\"%s\",\"operstate\":\"%s\",\"mtu\":%s,\"address\":\"%s\",\"addr_info\":[%s]}", iface_name, state, mtu, mac, addrs
        }
        # Start new interface
        split($2, a, ":")
        iface_name = a[1]
        gsub(/@.*/, "", iface_name)
        # Extract state and mtu
        state = "UNKNOWN"
        if (match($0, /state [A-Z]+/)) {
            state = substr($0, RSTART+6, RLENGTH-6)
        }
        mtu = "0"
        if (match($0, /mtu [0-9]+/)) {
            mtu = substr($0, RSTART+4, RLENGTH-4)
        }
        mac = ""
        addrs = ""
        addr_first = 1
        next
    }
    /link\/ether/ {
        mac = $2
        next
    }
    /inet6? / {
        split($2, a, "/")
        addr = a[1]
        prefix = a[2]
        family = ($1 == "inet") ? "inet" : "inet6"
        scope = ""
        if (match($0, /scope [a-z]+/)) {
            scope = substr($0, RSTART+6, RLENGTH-6)
        }
        if (!addr_first) addrs = addrs ","
        addr_first = 0
        addrs = addrs sprintf("{\"family\":\"%s\",\"local\":\"%s\",\"prefixlen\":%s,\"scope\":\"%s\"}", family, addr, prefix, scope)
        next
    }
    END {
        if (iface_name != "") {
            if (!first_iface) print ","
            printf "  {\"ifname\":\"%s\",\"operstate\":\"%s\",\"mtu\":%s,\"address\":\"%s\",\"addr_info\":[%s]}", iface_name, state, mtu, mac, addrs
        }
        print "\n]"
    }
    '
}

# Build output based on mode
if [[ "$ALL_AGENTS" == true ]]; then
    # Get interfaces from all node agents
    echo "{"
    echo '  "nodeAgents": ['

    first=true
    while IFS=' ' read -r pod node; do
        [[ -z "$pod" ]] && continue

        if [[ "$first" != true ]]; then
            echo ","
        fi
        first=false

        interfaces=$(get_interfaces "$NAMESPACE" "$pod" "$INTERFACE_FILTER")
        node_name=$(get_pod_node "$NAMESPACE" "$pod")

        echo "    {"
        echo "      \"pod\": \"$pod\","
        echo "      \"node\": \"$node_name\","
        echo "      \"interfaces\": $interfaces"
        echo -n "    }"
    done < <(discover_agent_pods "$NAMESPACE" "$NODE")

    echo ""
    echo "  ]"
    echo "}"
else
    # Single agent mode
    pod=$(discover_single_agent_pod "$NAMESPACE" "$POD" "$NODE")
    node_name=$(get_pod_node "$NAMESPACE" "$pod")

    interfaces=$(get_interfaces "$NAMESPACE" "$pod" "$INTERFACE_FILTER")

    jq -n \
        --arg pod "$pod" \
        --arg node "$node_name" \
        --argjson interfaces "$interfaces" \
        '{
            pod: $pod,
            node: $node,
            interfaces: $interfaces
        }'
fi
