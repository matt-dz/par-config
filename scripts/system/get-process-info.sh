#!/bin/bash
#
# get-process-info.sh
# Gets process information from Datadog Agent pod (host PID namespace) via kubectl exec
#
# Usage: get-process-info.sh [OPTIONS]
# Options:
#   --namespace, -n <ns>  Kubernetes namespace (default: from DD_AGENT_NAMESPACE or "default")
#   --pod, -p <pod>       Specific agent pod (optional, defaults to first available)
#   --node <node>         Target agent on specific node
#   --filter <pattern>    Filter processes by command pattern
#   --pid <pid>           Get info for specific PID
#   --user <user>         Filter by user
#   --sort <field>        Sort by: cpu, mem, pid, time (default: cpu)
#   --limit <count>       Limit number of results (default: 50)
#   --all                 Get processes from all node agents
#
# Output: JSON with process information
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
PID_FILTER=""
USER_FILTER=""
SORT_BY="cpu"
LIMIT="50"
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
        --pid)
            PID_FILTER="$2"
            shift 2
            ;;
        --user)
            USER_FILTER="$2"
            shift 2
            ;;
        --sort)
            SORT_BY="$2"
            shift 2
            ;;
        --limit)
            LIMIT="$2"
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

# Function to get process info from agent pod
get_processes() {
    local ns="$1"
    local pod="$2"
    local filter="$3"
    local pid="$4"
    local user="$5"
    local sort="$6"
    local limit="$7"

    # Build ps command
    # Using specific format for easier parsing
    local ps_format="pid,ppid,user,%cpu,%mem,vsz,rss,tty,stat,start,time,comm,args"

    local cmd="ps -eo $ps_format --no-headers"

    # Add sort option
    case "$sort" in
        cpu)
            cmd+=" --sort=-%cpu"
            ;;
        mem)
            cmd+=" --sort=-%mem"
            ;;
        pid)
            cmd+=" --sort=pid"
            ;;
        time)
            cmd+=" --sort=-time"
            ;;
    esac

    # Execute ps command
    local output
    output=$(exec_on_agent "$ns" "$pod" sh -c "$cmd 2>/dev/null" 2>/dev/null) || {
        echo '[]'
        return 1
    }

    # Apply filters and convert to JSON
    echo "$output" | awk -v filter="$filter" -v pid_filter="$pid" -v user_filter="$user" -v limit="$limit" '
    BEGIN {
        print "["
        count = 0
        first = 1
    }
    NF >= 12 {
        # Parse fields
        proc_pid = $1
        ppid = $2
        user = $3
        cpu = $4
        mem = $5
        vsz = $6
        rss = $7
        tty = $8
        stat = $9
        start = $10
        time = $11
        comm = $12

        # Args is everything after comm (field 13+)
        args = ""
        for (i = 13; i <= NF; i++) {
            if (i > 13) args = args " "
            args = args $i
        }

        # Apply PID filter
        if (pid_filter != "" && proc_pid != pid_filter) next

        # Apply user filter
        if (user_filter != "" && user !~ user_filter) next

        # Apply command filter
        if (filter != "") {
            combined = comm " " args
            if (tolower(combined) !~ tolower(filter)) next
        }

        # Check limit
        if (limit > 0 && count >= limit) next

        if (!first) print ","
        first = 0
        count++

        # Escape special characters
        gsub(/\\/, "\\\\", args)
        gsub(/"/, "\\\"", args)
        gsub(/\t/, " ", args)

        printf "  {\"pid\":%s,\"ppid\":%s,\"user\":\"%s\",\"cpu\":%.1f,\"mem\":%.1f,\"vsz\":%s,\"rss\":%s,\"tty\":\"%s\",\"stat\":\"%s\",\"start\":\"%s\",\"time\":\"%s\",\"command\":\"%s\",\"args\":\"%s\"}", proc_pid, ppid, user, cpu, mem, vsz, rss, tty, stat, start, time, comm, args
    }
    END {
        print "\n]"
    }
    '
}

# Build output based on mode
if [[ "$ALL_AGENTS" == true ]]; then
    # Get processes from all node agents
    echo "{"
    echo '  "nodeAgents": ['

    first=true
    while IFS=' ' read -r pod node; do
        [[ -z "$pod" ]] && continue

        if [[ "$first" != true ]]; then
            echo ","
        fi
        first=false

        processes=$(get_processes "$NAMESPACE" "$pod" "$FILTER_PATTERN" "$PID_FILTER" "$USER_FILTER" "$SORT_BY" "$LIMIT")
        node_name=$(get_pod_node "$NAMESPACE" "$pod")

        echo "    {"
        echo "      \"pod\": \"$pod\","
        echo "      \"node\": \"$node_name\","
        echo "      \"processes\": $processes"
        echo -n "    }"
    done < <(discover_agent_pods "$NAMESPACE" "$NODE")

    echo ""
    echo "  ]"
    echo "}"
else
    # Single agent mode
    pod=$(discover_single_agent_pod "$NAMESPACE" "$POD" "$NODE")
    node_name=$(get_pod_node "$NAMESPACE" "$pod")

    processes=$(get_processes "$NAMESPACE" "$pod" "$FILTER_PATTERN" "$PID_FILTER" "$USER_FILTER" "$SORT_BY" "$LIMIT")

    jq -n \
        --arg pod "$pod" \
        --arg node "$node_name" \
        --argjson processes "$processes" \
        '{
            pod: $pod,
            node: $node,
            processes: $processes
        }'
fi
