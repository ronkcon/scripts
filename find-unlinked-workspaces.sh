#!/bin/bash
#
# Find workspaces that are not linked to any issue (project_id in workspace but issue_id is null/empty)
# Usage: ./find-unlinked-workspaces.sh [--delete] <project_id>
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
PROJECT_ID=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --delete)
            DELETE=true
            shift
            ;;
        -*)
            echo -e "${RED}Error: unknown option $1${NC}"
            echo "Usage: $0 [--delete] <project_id>"
            exit 1
            ;;
        *)
            PROJECT_ID="$1"
            shift
            ;;
    esac
done

if [[ -z "$PROJECT_ID" ]]; then
    echo -e "${RED}Error: project_id is required${NC}"
    echo "Usage: $0 [--delete] <project_id>"
    exit 1
fi

# Load env for VIBE_KANBAN_PORT
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
fi

VIBE_KANBAN_PORT="${VIBE_KANBAN_PORT:-44744}"
VIBE_KANBAN_URL="http://127.0.0.1:${VIBE_KANBAN_PORT}"
VIBE_REMOTE_URL="https://api.vibekanban.com"

# Fetch a fresh auth token
vibe_token() {
    local token
    token=$(curl -s "${VIBE_KANBAN_URL}/api/auth/token" | jq -r '.data.access_token // empty')
    if [[ -z "$token" ]]; then
        echo -e "${RED}Error: Could not fetch auth token from vibe-kanban.${NC}" >&2
        echo "  Make sure vibe-kanban is running and you are logged in." >&2
        exit 1
    fi
    echo "$token"
}

remote_api() {
    local method="$1"
    local path="$2"
    shift 2
    curl -s -X "$method" "${VIBE_REMOTE_URL}${path}" \
        -H "Authorization: Bearer $(vibe_token)" \
        -H "X-Client-Version: 0.1.18" \
        -H "X-Client-Type: frontend" \
        "$@"
}

echo -e "${BLUE}Fetching project workspaces for project ${PROJECT_ID}...${NC}"
workspaces_json=$(remote_api GET "/v1/fallback/project_workspaces?project_id=${PROJECT_ID}")
if ! echo "$workspaces_json" | jq -e '.workspaces' > /dev/null 2>&1; then
    echo -e "${RED}Error fetching project workspaces:${NC}"
    echo "$workspaces_json"
    exit 1
fi

# Find workspaces with null/empty issue_id
unlinked=$(echo "$workspaces_json" | jq -r '
    .workspaces[]
    | select(.issue_id == null or .issue_id == "")
    | .local_workspace_id
')

unlinked_count=$(echo "$unlinked" | grep -c . 2>/dev/null || echo 0)

if [[ -z "$unlinked" ]]; then
    echo -e "${GREEN}No unlinked workspaces found.${NC}"
    exit 0
fi

echo -e "${YELLOW}Found ${unlinked_count} unlinked workspace(s):${NC}"
echo ""

for ws_id in $unlinked; do
    ws_info=$(echo "$workspaces_json" | jq -r --arg id "$ws_id" '
        .workspaces[] | select(.local_workspace_id == $id)
        | "  ID: \(.local_workspace_id)  Branch: \(.branch // "unknown")  Created: \(.created_at // "unknown")"
    ')
    echo -e "${CYAN}${ws_info}${NC}"
done

echo ""

if [[ "$DELETE" == "true" ]]; then
    echo -e "${BLUE}Deleting unlinked workspaces...${NC}"
    deleted=0
    failed=0

    for ws_id in $unlinked; do
        echo -n "  Deleting ${ws_id}... "
        delete_result=$(curl -s -X DELETE "${VIBE_KANBAN_URL}/api/task-attempts/${ws_id}")
        if echo "$delete_result" | jq -e '.success == true' > /dev/null 2>&1; then
            echo -e "${GREEN}deleted${NC}"
            ((deleted++)) || true
        else
            echo -e "${RED}failed: $(echo "$delete_result" | jq -r '.message // .error_data // "unknown error"')${NC}"
            ((failed++)) || true
        fi
    done

    echo ""
    echo -e "${GREEN}Done!${NC}"
    echo -e "  Deleted: ${deleted}"
    if [[ $failed -gt 0 ]]; then
        echo -e "  ${RED}Failed: ${failed}${NC}"
    fi
else
    echo -e "Run with ${CYAN}--delete${NC} to remove these workspaces."
fi
