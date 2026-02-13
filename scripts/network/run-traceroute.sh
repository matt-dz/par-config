#!/bin/bash
#
# run-traceroute.sh
# Runs traceroute from Datadog Agent pod (host network) via kubectl exec
#
# Usage: run-traceroute.sh --target <host> [OPTIONS]
# Options:
#   --target <host>       Target hostname or IP address (required)
#   --namespace, -n <ns>  Kubernetes namespace (default: from DD_AGENT_NAMESPACE or "default")
#   --pod, -p <pod>       Specific agent pod (optional, defaults to first available)
#   --node <node>         Target agent on specific node
#   --max-hops <count>    Maximum number of hops (default: 30)
#   --timeout <seconds>   Timeout per probe in seconds (default: 3)
#   --queries <count>     Number of queries per hop (default: 3)
#   --tcp                 Use TCP instead of UDP/ICMP
#   --port <port>         Target port for TCP traceroute
#   --icmp               Use ICMP ECHO instead of UDP
#   --all                 Run traceroute from all node agents
#
# Output: JSON with traceroute results
#

set -euo pipefail

# Source common helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/agent-exec.sh"

# Defaults
NAMESPACE="${DD_NAMESPACE}"
POD=""
NODE=""
TARGET=""
MAX_HOPS="30"
TIMEOUT="3"
QUERIES="3"
USE_TCP=false
USE_ICMP=false
PORT=""
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
        --target)
            TARGET="$2"
            shift 2
            ;;
        --max-hops)
            MAX_HOPS="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --queries)
            QUERIES="$2"
            shift 2
            ;;
        --tcp)
            USE_TCP=true
            shift
            ;;
        --icmp)
            USE_ICMP=true
            shift
            ;;
        --port)
            PORT="$2"
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

# Validate required arguments
if [[ -z "$TARGET" ]]; then
    json_error "Missing required argument: --target <host>"
fi

# Verify kubectl is available
check_kubectl

# Function to run traceroute from agent pod
run_traceroute() {
    local ns="$1"
    local pod="$2"
    local target="$3"

    # Build traceroute command
    local cmd="traceroute"

    # Add options
    cmd+=" -m $MAX_HOPS"
    cmd+=" -w $TIMEOUT"
    cmd+=" -q $QUERIES"

    if [[ "$USE_TCP" == true ]]; then
        cmd+=" -T"
        [[ -n "$PORT" ]] && cmd+=" -p $PORT"
    elif [[ "$USE_ICMP" == true ]]; then
        cmd+=" -I"
    fi

    cmd+=" $target"

    # Execute traceroute
    local output
    output=$(exec_on_agent "$ns" "$pod" sh -c "$cmd 2>&1" 2>/dev/null) || {
        # Try mtr as fallback
        output=$(exec_on_agent "$ns" "$pod" sh -c "mtr -r -c 1 -n $target 2>&1" 2>/dev/null) || {
            echo '{"error": "traceroute command failed", "target": "'"$target"'"}'
            return 1
        }
    }

    # Parse traceroute output to JSON
    local result
    result=$(echo "$output" | awk '
    BEGIN {
        print "{"
        print "  \"hops\": ["
        first = 1
        target = ""
    }
    NR == 1 {
        # First line contains target info
        # "traceroute to host (ip), 30 hops max, 60 byte packets"
        if (match($0, /to [^ ]+ \([^)]+\)/)) {
            target_info = substr($0, RSTART, RLENGTH)
            gsub(/to /, "", target_info)
            gsub(/[()]/, "", target_info)
            split(target_info, parts, " ")
            target = parts[1]
        }
        next
    }
    /^[ ]*[0-9]+/ {
        hop_num = $1

        # Parse the rest of the line for IP/hostname and RTT values
        hostname = ""
        ip = ""
        rtts = ""
        rtt_count = 0

        for (i = 2; i <= NF; i++) {
            if ($i == "*") {
                # Timeout
                if (rtts != "") rtts = rtts ","
                rtts = rtts "null"
                rtt_count++
            } else if ($i ~ /^[0-9]+\.[0-9]+$/ && $(i+1) == "ms") {
                # RTT value
                if (rtts != "") rtts = rtts ","
                rtts = rtts $i
                rtt_count++
                i++  # Skip "ms"
            } else if ($i ~ /^\(.*\)$/) {
                # IP in parentheses
                ip = $i
                gsub(/[()]/, "", ip)
            } else if ($i !~ /ms/ && $i !~ /^\*$/ && $i != "") {
                # Hostname
                if (hostname == "") hostname = $i
            }
        }

        # If no hostname found, use IP
        if (hostname == "" && ip != "") hostname = ip
        if (hostname == "" && ip == "") hostname = "*"

        if (!first) print ","
        first = 0

        printf "    {\"hop\":%s,\"host\":\"%s\"", hop_num, hostname
        if (ip != "") printf ",\"ip\":\"%s\"", ip
        if (rtts != "") printf ",\"rtt\":[%s]", rtts
        printf "}"
    }
    END {
        print "\n  ]"
        if (target != "") printf ",\"target\":\"%s\"", target
        print "\n}"
    }
    ')

    echo "$result"
}

# Build output based on mode
if [[ "$ALL_AGENTS" == true ]]; then
    # Run traceroute from all node agents
    echo "{"
    echo '  "target": "'"$TARGET"'",'
    echo '  "nodeAgents": ['

    first=true
    while IFS=' ' read -r pod node; do
        [[ -z "$pod" ]] && continue

        if [[ "$first" != true ]]; then
            echo ","
        fi
        first=false

        traceroute=$(run_traceroute "$NAMESPACE" "$pod" "$TARGET")
        node_name=$(get_pod_node "$NAMESPACE" "$pod")

        echo "    {"
        echo "      \"pod\": \"$pod\","
        echo "      \"node\": \"$node_name\","
        echo "      \"traceroute\": $traceroute"
        echo -n "    }"
    done < <(discover_agent_pods "$NAMESPACE" "$NODE")

    echo ""
    echo "  ]"
    echo "}"
else
    # Single agent mode
    pod=$(discover_single_agent_pod "$NAMESPACE" "$POD" "$NODE")
    node_name=$(get_pod_node "$NAMESPACE" "$pod")

    traceroute=$(run_traceroute "$NAMESPACE" "$pod" "$TARGET")

    jq -n \
        --arg target "$TARGET" \
        --arg pod "$pod" \
        --arg node "$node_name" \
        --argjson traceroute "$traceroute" \
        '{
            target: $target,
            pod: $pod,
            node: $node,
            traceroute: $traceroute
        }'
fi
