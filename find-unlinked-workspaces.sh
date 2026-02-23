#!/bin/bash
#
# Find workspaces that are not linked to any issue (task_id is null).
# Usage: ./find-unlinked-workspaces.sh [--delete]
#
# Options:
#   --delete    Delete the unlinked workspaces (default: just list them)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.sync-linear.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

DELETE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --delete)
            DELETE=true
            shift
            ;;
        -*)
            echo -e "${RED}Error: unknown option $1${NC}"
            echo "Usage: $0 [--delete]"
            exit 1
            ;;
        *)
            echo -e "${RED}Error: unexpected argument $1${NC}"
            echo "Usage: $0 [--delete]"
            exit 1
            ;;
    esac
done

# Load env for VIBE_KANBAN_PORT
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
fi

VIBE_KANBAN_PORT="${VIBE_KANBAN_PORT:-44744}"
VIBE_KANBAN_URL="http://127.0.0.1:${VIBE_KANBAN_PORT}"

echo -e "${BLUE}Fetching all local workspaces...${NC}"
workspaces_json=$(curl -s "${VIBE_KANBAN_URL}/api/task-attempts")
if ! echo "$workspaces_json" | jq -e '.success == true' > /dev/null 2>&1; then
    echo -e "${RED}Error fetching workspaces:${NC}"
    echo "$workspaces_json"
    exit 1
fi

# Workspaces with task_id == null are not linked to any issue
unlinked_json=$(echo "$workspaces_json" | jq '[.data[] | select(.task_id == null)]')
unlinked_count=$(echo "$unlinked_json" | jq 'length')

if [[ "$unlinked_count" -eq 0 ]]; then
    echo -e "${GREEN}No unlinked workspaces found.${NC}"
    exit 0
fi

echo -e "${YELLOW}Found ${unlinked_count} unlinked workspace(s):${NC}"
echo ""

echo "$unlinked_json" | jq -r '.[] | "  \(.id)  branch=\(.branch)  name=\(.name)"' | while read -r line; do
    echo -e "${CYAN}${line}${NC}"
done

echo ""

if [[ "$DELETE" == "true" ]]; then
    echo -e "${BLUE}Deleting unlinked workspaces...${NC}"
    deleted=0
    failed=0

    while IFS= read -r ws_id; do
        echo -n "  Deleting ${ws_id}... "
        delete_result=$(curl -s -X DELETE "${VIBE_KANBAN_URL}/api/task-attempts/${ws_id}")
        if echo "$delete_result" | jq -e '.success == true' > /dev/null 2>&1; then
            echo -e "${GREEN}deleted${NC}"
            ((deleted++)) || true
        else
            echo -e "${RED}failed: $(echo "$delete_result" | jq -r '.message // .error_data // "unknown error"')${NC}"
            ((failed++)) || true
        fi
    done < <(echo "$unlinked_json" | jq -r '.[].id')

    echo ""
    echo -e "${GREEN}Done!${NC}"
    echo -e "  Deleted: ${deleted}"
    if [[ $failed -gt 0 ]]; then
        echo -e "  ${RED}Failed: ${failed}${NC}"
    fi
else
    echo -e "Run with ${CYAN}--delete${NC} to remove these workspaces."
fi
