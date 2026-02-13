#!/bin/bash
#
# list-files.sh
# Lists files on Datadog Agent pod filesystem via kubectl exec
#
# Usage: list-files.sh --path <path> [OPTIONS]
# Options:
#   --path <path>         Directory path to list (required)
#   --namespace, -n <ns>  Kubernetes namespace (default: from DD_AGENT_NAMESPACE or "default")
#   --pod, -p <pod>       Specific agent pod (optional, defaults to first available)
#   --node <node>         Target agent on specific node
#   --pattern <pattern>   Glob pattern to filter files (e.g., "*.log")
#   --type <type>         File type filter: f (files), d (directories), l (links)
#   --max-depth <depth>   Maximum directory depth to traverse (default: 1)
#   --recursive, -r       Recursively list files (sets max-depth to unlimited)
#   --long, -l            Long format with permissions, size, timestamps
#
# Output: JSON array of file information
#

set -euo pipefail

# Source common helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/agent-exec.sh"

# Defaults
NAMESPACE="${DD_NAMESPACE}"
POD=""
NODE=""
PATH_ARG=""
PATTERN=""
FILE_TYPE=""
MAX_DEPTH="1"
LONG_FORMAT=false

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
            PATH_ARG="$2"
            shift 2
            ;;
        --pattern)
            PATTERN="$2"
            shift 2
            ;;
        --type)
            FILE_TYPE="$2"
            shift 2
            ;;
        --max-depth)
            MAX_DEPTH="$2"
            shift 2
            ;;
        --recursive|-r)
            MAX_DEPTH=""
            shift
            ;;
        --long|-l)
            LONG_FORMAT=true
            shift
            ;;
        *)
            json_error "Unknown argument: $1"
            ;;
    esac
done

# Validate required arguments
if [[ -z "$PATH_ARG" ]]; then
    json_error "Missing required argument: --path <path>"
fi

# Verify kubectl is available
check_kubectl

# Function to list files on agent pod
list_files() {
    local ns="$1"
    local pod="$2"
    local path="$3"
    local pattern="$4"
    local file_type="$5"
    local max_depth="$6"
    local long="$7"

    # Build find command
    local cmd="find ${path}"

    # Add max depth
    if [[ -n "$max_depth" ]]; then
        cmd+=" -maxdepth ${max_depth}"
    fi

    # Add type filter
    if [[ -n "$file_type" ]]; then
        cmd+=" -type ${file_type}"
    fi

    # Add name pattern
    if [[ -n "$pattern" ]]; then
        cmd+=" -name '${pattern}'"
    fi

    # Choose output format
    if [[ "$long" == true ]]; then
        # Use stat for detailed info, with fallback format
        cmd+=" -exec stat -c '{\"path\":\"%n\",\"size\":%s,\"mode\":\"%a\",\"mtime\":%Y,\"type\":\"%F\"}' {} \\; 2>/dev/null || "
        cmd+="find ${path}"
        [[ -n "$max_depth" ]] && cmd+=" -maxdepth ${max_depth}"
        [[ -n "$file_type" ]] && cmd+=" -type ${file_type}"
        [[ -n "$pattern" ]] && cmd+=" -name '${pattern}'"
        cmd+=" -ls 2>/dev/null"
    fi

    # Execute on agent pod
    local output
    if [[ "$long" == true ]]; then
        # Try JSON stat format first
        output=$(exec_on_agent "$ns" "$pod" sh -c "find ${path} ${max_depth:+-maxdepth $max_depth} ${file_type:+-type $file_type} ${pattern:+-name '$pattern'} -exec stat -c '{\"path\":\"%n\",\"size\":%s,\"mode\":\"%a\",\"mtime\":%Y,\"type\":\"%F\"}' {} \; 2>/dev/null" 2>/dev/null) || {
            # Fallback to ls format
            output=$(exec_on_agent "$ns" "$pod" sh -c "find ${path} ${max_depth:+-maxdepth $max_depth} ${file_type:+-type $file_type} ${pattern:+-name '$pattern'} -ls 2>/dev/null" 2>/dev/null) || {
                echo '[]'
                return 1
            }
            # Convert ls output to JSON
            echo "$output" | awk '
            BEGIN { print "["; first=1 }
            NF > 0 {
                if (!first) print ","
                first=0
                # ls -ls format: inode blocks perms links user group size month day time/year path
                printf "  {\"path\":\"%s\",\"size\":%s,\"mode\":\"%s\",\"user\":\"%s\",\"group\":\"%s\"}", $11, $7, $3, $5, $6
            }
            END { print "\n]" }
            '
            return 0
        }
        # Wrap JSON objects in array
        echo "[$output]" | jq -s 'flatten'
    else
        # Simple path list
        output=$(exec_on_agent "$ns" "$pod" sh -c "find ${path} ${max_depth:+-maxdepth $max_depth} ${file_type:+-type $file_type} ${pattern:+-name '$pattern'} 2>/dev/null" 2>/dev/null) || {
            echo '[]'
            return 1
        }
        # Convert to JSON array
        echo "$output" | jq -R -s 'split("\n") | map(select(length > 0))'
    fi
}

# Discover pod and execute
pod=$(discover_single_agent_pod "$NAMESPACE" "$POD" "$NODE")
node_name=$(get_pod_node "$NAMESPACE" "$pod")

files=$(list_files "$NAMESPACE" "$pod" "$PATH_ARG" "$PATTERN" "$FILE_TYPE" "$MAX_DEPTH" "$LONG_FORMAT")

jq -n \
    --arg pod "$pod" \
    --arg node "$node_name" \
    --arg path "$PATH_ARG" \
    --argjson files "$files" \
    '{
        pod: $pod,
        node: $node,
        path: $path,
        files: $files
    }'
