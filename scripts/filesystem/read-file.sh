#!/bin/bash
#
# read-file.sh
# Reads file content from Datadog Agent pod filesystem via kubectl exec
#
# Usage: read-file.sh --path <path> [OPTIONS]
# Options:
#   --path <path>         File path to read (required)
#   --namespace, -n <ns>  Kubernetes namespace (default: from DD_AGENT_NAMESPACE or "default")
#   --pod, -p <pod>       Specific agent pod (optional, defaults to first available)
#   --node <node>         Target agent on specific node
#   --mode <mode>         Read mode: full, head, tail (default: tail)
#   --lines <count>       Number of lines to read (default: 100)
#   --grep <pattern>      Filter lines matching pattern
#   --follow, -f          Follow file (for logs) - returns last N lines and exits
#
# Output: JSON with file content and metadata
#

set -euo pipefail

# Source common helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/agent-exec.sh"

# Defaults
NAMESPACE="${DD_NAMESPACE}"
POD=""
NODE=""
FILE_PATH=""
MODE="tail"
LINES="100"
GREP_PATTERN=""

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
        --path)
            FILE_PATH="$2"
            shift 2
            ;;
        --mode)
            MODE="$2"
            shift 2
            ;;
        --lines)
            LINES="$2"
            shift 2
            ;;
        --grep)
            GREP_PATTERN="$2"
            shift 2
            ;;
        --follow|-f)
            # For non-interactive use, --follow just means tail
            MODE="tail"
            shift
            ;;
        *)
            json_error "Unknown argument: $1"
            ;;
    esac
done

# Validate required arguments
if [[ -z "$FILE_PATH" ]]; then
    json_error "Missing required argument: --path <path>"
fi

# Verify kubectl is available
check_kubectl

# Function to read file from agent pod
read_file() {
    local ns="$1"
    local pod="$2"
    local path="$3"
    local mode="$4"
    local lines="$5"
    local grep_pattern="$6"

    # Check if file exists and get metadata
    local file_info
    file_info=$(exec_on_agent "$ns" "$pod" stat -c '{"size":%s,"mtime":%Y,"mode":"%a"}' "$path" 2>/dev/null) || {
        echo '{"error": "File not found or not accessible: '"$path"'"}'
        return 1
    }

    # Build read command based on mode
    local cmd=""
    case "$mode" in
        full)
            cmd="cat '${path}'"
            ;;
        head)
            cmd="head -n ${lines} '${path}'"
            ;;
        tail)
            cmd="tail -n ${lines} '${path}'"
            ;;
        *)
            echo '{"error": "Invalid mode: '"$mode"'. Use: full, head, tail"}'
            return 1
            ;;
    esac

    # Add grep filter if specified
    if [[ -n "$grep_pattern" ]]; then
        cmd+=" | grep -E '${grep_pattern}' || true"
    fi

    # Execute read command
    local content
    content=$(exec_on_agent "$ns" "$pod" sh -c "$cmd" 2>/dev/null) || {
        echo '{"error": "Failed to read file", "path": "'"$path"'"}'
        return 1
    }

    # Count lines in content
    local line_count
    line_count=$(echo "$content" | wc -l | tr -d ' ')

    # Build result JSON
    jq -n \
        --arg content "$content" \
        --argjson fileInfo "$file_info" \
        --arg lineCount "$line_count" \
        --arg mode "$mode" \
        --arg requestedLines "$lines" \
        '{
            content: $content,
            metadata: ($fileInfo + {
                linesReturned: ($lineCount | tonumber),
                readMode: $mode,
                linesRequested: ($requestedLines | tonumber)
            })
        }'
}

# Discover pod and execute
pod=$(discover_single_agent_pod "$NAMESPACE" "$POD" "$NODE")
node_name=$(get_pod_node "$NAMESPACE" "$pod")

result=$(read_file "$NAMESPACE" "$pod" "$FILE_PATH" "$MODE" "$LINES" "$GREP_PATTERN")

# Check if result is an error
if echo "$result" | jq -e '.error' >/dev/null 2>&1; then
    jq -n \
        --arg pod "$pod" \
        --arg node "$node_name" \
        --arg path "$FILE_PATH" \
        --argjson result "$result" \
        '{
            pod: $pod,
            node: $node,
            path: $path,
            error: $result.error
        }'
else
    jq -n \
        --arg pod "$pod" \
        --arg node "$node_name" \
        --arg path "$FILE_PATH" \
        --argjson result "$result" \
        '{
            pod: $pod,
            node: $node,
            path: $path,
            content: $result.content,
            metadata: $result.metadata
        }'
fi
