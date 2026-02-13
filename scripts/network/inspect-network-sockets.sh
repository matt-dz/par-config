#!/bin/bash
#
# inspect-network-sockets.sh
# Inspects network sockets on Datadog Agent pod (host network) via kubectl exec
#
# Usage: inspect-network-sockets.sh [OPTIONS]
# Options:
#   --namespace, -n <ns>  Kubernetes namespace (default: from DD_AGENT_NAMESPACE or "default")
#   --pod, -p <pod>       Specific agent pod (optional, defaults to first available)
#   --node <node>         Target agent on specific node
#   --tcp                 Show TCP sockets only
#   --udp                 Show UDP sockets only
#   --listening           Show only listening sockets
#   --all                 Get sockets from all node agents
#   --state <state>       Filter by socket state (e.g., established, listen, time-wait)
#   --port <port>         Filter by local or remote port
#
# Output: JSON with socket information including state, addresses, and processes
#

set -euo pipefail

# Source common helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/agent-exec.sh"

# Defaults
NAMESPACE="${DD_NAMESPACE}"
POD=""
NODE=""
TCP_ONLY=false
UDP_ONLY=false
LISTENING_ONLY=false
ALL_AGENTS=false
STATE_FILTER=""
PORT_FILTER=""

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
        --tcp)
            TCP_ONLY=true
            shift
            ;;
        --udp)
            UDP_ONLY=true
            shift
            ;;
        --listening)
            LISTENING_ONLY=true
            shift
            ;;
        --all)
            ALL_AGENTS=true
            shift
            ;;
        --state)
            STATE_FILTER="$2"
            shift 2
            ;;
        --port)
            PORT_FILTER="$2"
            shift 2
            ;;
        *)
            json_error "Unknown argument: $1"
            ;;
    esac
done

# Verify kubectl is available
check_kubectl

# Function to get socket info from agent pod
get_sockets() {
    local ns="$1"
    local pod="$2"

    # Build ss command options
    local ss_opts="-a -n -p"

    if [[ "$TCP_ONLY" == true ]]; then
        ss_opts+=" -t"
    elif [[ "$UDP_ONLY" == true ]]; then
        ss_opts+=" -u"
    else
        ss_opts+=" -t -u"
    fi

    if [[ "$LISTENING_ONLY" == true ]]; then
        ss_opts+=" -l"
    fi

    # Execute ss command and parse output
    local output
    output=$(exec_on_agent "$ns" "$pod" sh -c "ss $ss_opts 2>/dev/null || netstat -tunap 2>/dev/null" 2>/dev/null) || {
        echo '[]'
        return 1
    }

    # Parse ss output to JSON
    echo "$output" | awk -v state_filter="$STATE_FILTER" -v port_filter="$PORT_FILTER" '
    BEGIN {
        print "["
        first = 1
    }
    NR > 1 && NF >= 5 {
        proto = $1
        state = $2
        recv_q = $3
        send_q = $4
        local = $5
        remote = $6
        process = ""
        if (NF >= 7) process = $7

        # Skip header variations
        if (proto == "Netid" || proto == "State" || proto == "Proto") next

        # Apply state filter
        if (state_filter != "" && tolower(state) !~ tolower(state_filter)) next

        # Apply port filter
        if (port_filter != "") {
            if (local !~ port_filter && remote !~ port_filter) next
        }

        # Clean up process info
        gsub(/users:\(\(/, "", process)
        gsub(/\)\)/, "", process)
        gsub(/"/, "\\\"", process)

        if (!first) print ","
        first = 0

        printf "  {\"protocol\":\"%s\",\"state\":\"%s\",\"recvQ\":\"%s\",\"sendQ\":\"%s\",\"local\":\"%s\",\"remote\":\"%s\",\"process\":\"%s\"}", proto, state, recv_q, send_q, local, remote, process
    }
    END {
        print "\n]"
    }
    '
}

# Build output based on mode
if [[ "$ALL_AGENTS" == true ]]; then
    # Get sockets from all node agents
    echo "{"
    echo '  "nodeAgents": ['

    first=true
    while IFS=' ' read -r pod node; do
        [[ -z "$pod" ]] && continue

        if [[ "$first" != true ]]; then
            echo ","
        fi
        first=false

        sockets=$(get_sockets "$NAMESPACE" "$pod")
        node_name=$(get_pod_node "$NAMESPACE" "$pod")

        echo "    {"
        echo "      \"pod\": \"$pod\","
        echo "      \"node\": \"$node_name\","
        echo "      \"sockets\": $sockets"
        echo -n "    }"
    done < <(discover_agent_pods "$NAMESPACE" "$NODE")

    echo ""
    echo "  ]"
    echo "}"
else
    # Single agent mode
    pod=$(discover_single_agent_pod "$NAMESPACE" "$POD" "$NODE")
    node_name=$(get_pod_node "$NAMESPACE" "$pod")

    sockets=$(get_sockets "$NAMESPACE" "$pod")

    jq -n \
        --arg pod "$pod" \
        --arg node "$node_name" \
        --argjson sockets "$sockets" \
        '{
            pod: $pod,
            node: $node,
            sockets: $sockets
        }'
fi
