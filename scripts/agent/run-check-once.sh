#!/bin/bash
#
# run-check-once.sh
# Runs a Datadog Agent check once and returns results via kubectl exec
#
# Usage: run-check-once.sh --check <name> [OPTIONS]
# Options:
#   --check <name>        Check name to run (required)
#   --namespace, -n <ns>  Kubernetes namespace (default: from DD_AGENT_NAMESPACE or "default")
#   --pod, -p <pod>       Specific agent pod (optional, defaults to first available)
#   --node <node>         Target agent on specific node
#   --log-level <level>   Log level: trace, debug, info, warn, error (default: info)
#   --delay <seconds>     Delay between check runs when running multiple times
#   --times <count>       Number of times to run the check (default: 1)
#   --pause              Pause for breakpoint (debugging)
#   --all                 Run check on all node agents
#
# Output: JSON with check results including metrics, events, and service checks
#

set -euo pipefail

# Source common helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/agent-exec.sh"

# Defaults
NAMESPACE="${DD_NAMESPACE}"
POD=""
NODE=""
CHECK_NAME=""
LOG_LEVEL=""
DELAY=""
TIMES=""
PAUSE=false
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
            CHECK_NAME="$2"
            shift 2
            ;;
        --log-level)
            LOG_LEVEL="$2"
            shift 2
            ;;
        --delay)
            DELAY="$2"
            shift 2
            ;;
        --times)
            TIMES="$2"
            shift 2
            ;;
        --pause)
            PAUSE=true
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

# Validate required arguments
if [[ -z "$CHECK_NAME" ]]; then
    json_error "Missing required argument: --check <name>"
fi

# Verify kubectl is available
check_kubectl

# Build check command arguments
build_check_args() {
    local args="check ${CHECK_NAME} --json"

    if [[ -n "$LOG_LEVEL" ]]; then
        args+=" --log-level $LOG_LEVEL"
    fi

    if [[ -n "$DELAY" ]]; then
        args+=" --delay $DELAY"
    fi

    if [[ -n "$TIMES" ]]; then
        args+=" --check-times $TIMES"
    fi

    if [[ "$PAUSE" == true ]]; then
        args+=" --pause"
    fi

    echo "$args"
}

# Function to run check on a single agent pod
run_check() {
    local ns="$1"
    local pod="$2"

    local args
    args=$(build_check_args)

    # shellcheck disable=SC2086
    agent_command "$ns" "$pod" $args 2>/dev/null || echo '{"error": "Failed to run check '"$CHECK_NAME"'"}'
}

# Build output based on mode
if [[ "$ALL_AGENTS" == true ]]; then
    # Run check on all node agents
    echo "{"
    echo '  "check": "'"$CHECK_NAME"'",'
    echo '  "nodeAgents": ['

    first=true
    while IFS=' ' read -r pod node; do
        [[ -z "$pod" ]] && continue

        if [[ "$first" != true ]]; then
            echo ","
        fi
        first=false

        result=$(run_check "$NAMESPACE" "$pod")
        node_name=$(get_pod_node "$NAMESPACE" "$pod")

        echo "    {"
        echo "      \"pod\": \"$pod\","
        echo "      \"node\": \"$node_name\","
        echo "      \"result\": $result"
        echo -n "    }"
    done < <(discover_agent_pods "$NAMESPACE" "$NODE")

    echo ""
    echo "  ]"
    echo "}"
else
    # Single agent mode
    pod=$(discover_single_agent_pod "$NAMESPACE" "$POD" "$NODE")
    node_name=$(get_pod_node "$NAMESPACE" "$pod")

    result=$(run_check "$NAMESPACE" "$pod")

    jq -n \
        --arg check "$CHECK_NAME" \
        --arg pod "$pod" \
        --arg node "$node_name" \
        --argjson result "$result" \
        '{
            check: $check,
            pod: $pod,
            node: $node,
            result: $result
        }'
fi
