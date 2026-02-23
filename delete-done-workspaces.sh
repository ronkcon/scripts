#!/bin/bash
#
# Delete workspaces for Done/Cancelled issues in a vibe-kanban project
# Usage: ./delete-done-workspaces.sh [--simulation] [--include-backlog] <project_id>
#
# For each issue in Done or Cancelled status, finds its linked workspace,
# unlinks it from the issue, and deletes it.
#
# Options:
#   --simulation      Dry run: show what would be deleted without doing it
#   --include-backlog Also delete workspaces for Backlog issues
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

SIMULATION=false
INCLUDE_BACKLOG=false
PROJECT_ID=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --simulation)
            SIMULATION=true
            shift
            ;;
        --include-backlog)
            INCLUDE_BACKLOG=true
            shift
            ;;
        -*)
            echo -e "${RED}Error: unknown option $1${NC}"
            echo "Usage: $0 [--simulation] [--include-backlog] <project_id>"
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
    echo "Usage: $0 [--simulation] [--include-backlog] <project_id>"
    exit 1
fi

if [[ "$SIMULATION" == "true" ]]; then
    echo -e "${CYAN}[SIMULATION MODE] No changes will be made${NC}"
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

echo -e "${BLUE}Fetching project statuses for project ${PROJECT_ID}...${NC}"
statuses_json=$(remote_api GET "/v1/fallback/project_statuses?project_id=${PROJECT_ID}")
if ! echo "$statuses_json" | jq -e '.project_statuses' > /dev/null 2>&1; then
    echo -e "${RED}Error fetching project statuses:${NC}"
    echo "$statuses_json"
    exit 1
fi

# Get Done and Cancelled (and optionally Backlog) status IDs
if [[ "$INCLUDE_BACKLOG" == "true" ]]; then
    target_statuses_filter='.name == "Done" or .name == "Cancelled" or .name == "Backlog"'
    target_statuses_label="Done/Cancelled/Backlog"
else
    target_statuses_filter='.name == "Done" or .name == "Cancelled"'
    target_statuses_label="Done/Cancelled"
fi

done_cancelled_ids=$(echo "$statuses_json" | jq -r \
    ".project_statuses[] | select(${target_statuses_filter}) | .id")

if [[ -z "$done_cancelled_ids" ]]; then
    echo -e "${YELLOW}No ${target_statuses_label} statuses found in this project.${NC}"
    exit 0
fi

echo -e "${BLUE}Fetching issues in ${target_statuses_label} status...${NC}"
issues_json=$(remote_api GET "/v1/fallback/issues?project_id=${PROJECT_ID}&limit=500")
if ! echo "$issues_json" | jq -e '.issues' > /dev/null 2>&1; then
    echo -e "${RED}Error fetching issues:${NC}"
    echo "$issues_json"
    exit 1
fi

# Filter issues to Done/Cancelled
done_issue_ids=$(echo "$issues_json" | jq -r --argjson status_ids "$(echo "$done_cancelled_ids" | jq -R . | jq -s .)" '
    .issues[]
    | select(.status_id as $s | $status_ids | index($s) != null)
    | .id
')

issue_count=$(echo "$done_issue_ids" | grep -c . 2>/dev/null || echo 0)
echo -e "${GREEN}Found ${issue_count} issues in ${target_statuses_label} status${NC}"

if [[ -z "$done_issue_ids" ]]; then
    echo "Nothing to do."
    exit 0
fi

echo -e "${BLUE}Fetching project workspaces...${NC}"
workspaces_json=$(remote_api GET "/v1/fallback/project_workspaces?project_id=${PROJECT_ID}")
if ! echo "$workspaces_json" | jq -e '.workspaces' > /dev/null 2>&1; then
    echo -e "${RED}Error fetching project workspaces:${NC}"
    echo "$workspaces_json"
    exit 1
fi

deleted=0
skipped=0

for issue_id in $done_issue_ids; do
    issue_title=$(echo "$issues_json" | jq -r --arg id "$issue_id" '.issues[] | select(.id == $id) | .title')
    simple_id=$(echo "$issues_json" | jq -r --arg id "$issue_id" '.issues[] | select(.id == $id) | .simple_id')

    # Find workspace linked to this issue
    local_ws_id=$(echo "$workspaces_json" | jq -r --arg issue_id "$issue_id" '
        .workspaces[]
        | select(.issue_id == $issue_id)
        | .local_workspace_id
    ')

    if [[ -z "$local_ws_id" || "$local_ws_id" == "null" ]]; then
        echo -e "  ${YELLOW}No workspace${NC} for ${simple_id}: ${issue_title}"
        ((skipped++)) || true
        continue
    fi

    if [[ "$SIMULATION" == "true" ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would unlink and delete workspace for ${simple_id}: ${issue_title} (workspace: ${local_ws_id})"
        ((deleted++)) || true
        continue
    fi

    echo -e "  ${BLUE}Processing${NC} ${simple_id}: ${issue_title} (workspace: ${local_ws_id})"

    # Unlink the workspace from the issue
    unlink_result=$(curl -s -X POST "${VIBE_KANBAN_URL}/api/task-attempts/${local_ws_id}/unlink" \
        -H "Content-Type: application/json")
    if echo "$unlink_result" | jq -e '.success == true' > /dev/null 2>&1; then
        echo -e "    ${GREEN}Unlinked${NC} from issue"
    else
        echo -e "    ${YELLOW}Unlink failed (may already be unlinked):${NC} $(echo "$unlink_result" | jq -r '.message // .error_data // "unknown error"')"
    fi

    # Delete the workspace
    delete_result=$(curl -s -X DELETE "${VIBE_KANBAN_URL}/api/task-attempts/${local_ws_id}")
    if echo "$delete_result" | jq -e '.success == true' > /dev/null 2>&1; then
        echo -e "    ${GREEN}Deleted${NC} workspace"
        ((deleted++)) || true
    else
        echo -e "    ${RED}Delete failed:${NC} $(echo "$delete_result" | jq -r '.message // .error_data // "unknown error"')"
    fi
done

echo ""
if [[ "$SIMULATION" == "true" ]]; then
    echo -e "${CYAN}[SIMULATION] Would have deleted: ${deleted}${NC}"
    echo -e "${CYAN}[SIMULATION] Would have skipped (no workspace): ${skipped}${NC}"
else
    echo -e "${GREEN}Done!${NC}"
    echo -e "  Deleted: ${deleted}"
    echo -e "  Skipped (no workspace): ${skipped}"
fi
