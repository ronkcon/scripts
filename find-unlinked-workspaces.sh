#!/bin/bash
#
# Find local workspaces that are not linked to any issue across all projects.
#
# Strategy:
#   1. Fetch all local workspace IDs from the local API
#   2. Fetch all organizations, then all projects per org
#   3. For each project, fetch remote project_workspaces and collect
#      local_workspace_ids that have an issue_id (i.e. are linked)
#   4. Any local workspace not in the linked set is unlinked
#
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

# Step 1: all local workspaces
echo -e "${BLUE}Fetching all local workspaces...${NC}"
local_json=$(curl -s "${VIBE_KANBAN_URL}/api/task-attempts")
if ! echo "$local_json" | jq -e '.success == true' > /dev/null 2>&1; then
    echo -e "${RED}Error fetching local workspaces:${NC}"
    echo "$local_json"
    exit 1
fi
local_count=$(echo "$local_json" | jq '.data | length')
echo -e "  Found ${local_count} local workspace(s)"

# Step 2: get all organizations from local API
echo -e "${BLUE}Fetching organizations...${NC}"
orgs_json=$(curl -s "${VIBE_KANBAN_URL}/api/organizations")
if ! echo "$orgs_json" | jq -e '.success == true' > /dev/null 2>&1; then
    echo -e "${RED}Error fetching organizations:${NC}"
    echo "$orgs_json"
    exit 1
fi
org_ids=$(echo "$orgs_json" | jq -r '.data.organizations[].id')

# Step 3: for each org, fetch projects; for each project, collect linked local_workspace_ids
echo -e "${BLUE}Fetching projects and their remote workspace links...${NC}"
linked_ids=""

for org_id in $org_ids; do
    projects_json=$(remote_api GET "/v1/fallback/projects?organization_id=${org_id}")
    if ! echo "$projects_json" | jq -e '.projects' > /dev/null 2>&1; then
        echo -e "${YELLOW}  Warning: could not fetch projects for org ${org_id}${NC}"
        continue
    fi

    while IFS=$'\t' read -r project_id project_name; do
        echo -e "  Checking project: ${project_name} (${project_id})"
        pw_json=$(remote_api GET "/v1/fallback/project_workspaces?project_id=${project_id}")
        if echo "$pw_json" | jq -e '.workspaces' > /dev/null 2>&1; then
            ids=$(echo "$pw_json" | jq -r '.workspaces[] | select(.issue_id != null and .issue_id != "") | .local_workspace_id')
            linked_ids="${linked_ids}${ids}"$'\n'
        fi
    done < <(echo "$projects_json" | jq -r '.projects[] | [.id, .name] | @tsv')
done

# Step 4: find local workspaces not in the linked set
echo ""
linked_array=$(echo "$linked_ids" | grep -v '^$' | jq -R . | jq -s .)
unlinked_json=$(echo "$local_json" | jq --argjson linked "$linked_array" \
    '[.data[] | select(.id as $id | $linked | index($id) == null)]')

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
