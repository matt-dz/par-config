#!/bin/bash
#
# get-configured-checks.sh
# Lists all configured checks on the Datadog Agent via kubectl exec
#
# Usage: get-configured-checks.sh [OPTIONS]
# Options:
#   --namespace, -n <ns>  Kubernetes namespace (default: from DD_AGENT_NAMESPACE or "default")
#   --pod, -p <pod>       Specific agent pod (optional, defaults to first available)
#   --node <node>         Target agent on specific node
#   --check <name>        Filter to specific check
#   --all                 Get checks from all node agents
#
# Output: JSON with configured checks, config sources, and providers
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

# AWK script for parsing configcheck output
AWK_PARSER='
BEGIN {
    print "{"
    print "  \"checks\": ["
    first = 1
    check_name = ""
    provider = ""
    source = ""
}

/^=== .* ===/ {
    # Print previous check if exists
    if (check_name != "" && (filter == "" || index(check_name, filter) > 0)) {
        if (!first) print ","
        printf "    {\"name\": \"%s\", \"provider\": \"%s\", \"source\": \"%s\"}", check_name, provider, source
        first = 0
    }
    # Extract check name
    gsub(/^=== /, "")
    gsub(/ ===$/, "")
    gsub(/ check$/, "")
    check_name = $0
    provider = ""
    source = ""
    next
}

/^Configuration provider:/ {
    gsub(/^Configuration provider: /, "")
    provider = $0
    next
}

/^Configuration source:/ {
    gsub(/^Configuration source: /, "")
    source = $0
    next
}

END {
    # Print last check
    if (check_name != "" && (filter == "" || index(check_name, filter) > 0)) {
        if (!first) print ","
        printf "    {\"name\": \"%s\", \"provider\": \"%s\", \"source\": \"%s\"}", check_name, provider, source
    }
    print ""
    print "  ]"
    print "}"
}
'

# Function to get configured checks from a single agent pod
get_configured_checks() {
    local ns="$1"
    local pod="$2"
    local filter="$3"

    agent_command "$ns" "$pod" configcheck 2>/dev/null | awk -v filter="$filter" "$AWK_PARSER"
}

# Build output based on mode
if [[ "$ALL_AGENTS" == true ]]; then
    # Get checks from all node agents
    echo "{"
    echo '  "nodeAgents": ['

    first=true
    while IFS=' ' read -r pod node; do
        [[ -z "$pod" ]] && continue

        if [[ "$first" != true ]]; then
            echo ","
        fi
        first=false

        checks=$(get_configured_checks "$NAMESPACE" "$pod" "$CHECK_FILTER")
        node_name=$(get_pod_node "$NAMESPACE" "$pod")

        echo "    {"
        echo "      \"pod\": \"$pod\","
        echo "      \"node\": \"$node_name\","
        echo "      \"config\": $checks"
        echo -n "    }"
    done < <(discover_agent_pods "$NAMESPACE" "$NODE")

    echo ""
    echo "  ]"
    echo "}"
else
    # Single agent mode
    pod=$(discover_single_agent_pod "$NAMESPACE" "$POD" "$NODE")
    node_name=$(get_pod_node "$NAMESPACE" "$pod")

    checks=$(get_configured_checks "$NAMESPACE" "$pod" "$CHECK_FILTER")

    jq -n \
        --arg pod "$pod" \
        --arg node "$node_name" \
        --argjson checks "$checks" \
        '{
            pod: $pod,
            node: $node,
            config: $checks
        }'
fi
