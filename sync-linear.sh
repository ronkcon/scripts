#!/bin/bash
#
# Sync Linear tasks to vibe-kanban
# Usage: ./sync-linear.sh
#

set -e

# Script directory (for finding .env file)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.sync-linear.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load environment variables from .sync-linear.env
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
else
    echo -e "${RED}Error: $ENV_FILE not found${NC}"
    echo "Create it with the following variables:"
    echo "  LINEAR_API_KEY=..."
    echo "  LINEAR_EMAIL=..."
    echo "  VIBE_KANBAN_PORT=..."
    echo "  VIBE_PROJECT_ID=..."
    exit 1
fi

# Validate required environment variables
validate_env() {
    local missing=0

    if [[ -z "$LINEAR_API_KEY" ]]; then
        echo -e "${RED}Error: LINEAR_API_KEY is not set${NC}"
        echo "  Get your API key from: https://linear.app/settings/api"
        missing=1
    fi

    if [[ -z "$LINEAR_EMAIL" ]]; then
        echo -e "${RED}Error: LINEAR_EMAIL is not set${NC}"
        echo "  Set your Linear email address"
        missing=1
    fi

    if [[ -z "$VIBE_KANBAN_PORT" ]]; then
        echo -e "${RED}Error: VIBE_KANBAN_PORT is not set${NC}"
        echo "  Set the vibe-kanban server port"
        missing=1
    fi

    if [[ -z "$VIBE_PROJECT_ID" ]]; then
        echo -e "${RED}Error: VIBE_PROJECT_ID is not set${NC}"
        echo "  Set your vibe-kanban project ID"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        echo "Add missing variables to: $ENV_FILE"
        exit 1
    fi
}

validate_env

# Configuration
VIBE_KANBAN_URL="http://127.0.0.1:${VIBE_KANBAN_PORT}"
LINEAR_API_URL="https://api.linear.app/graphql"

echo -e "${BLUE}Syncing Linear tasks for ${LINEAR_EMAIL}...${NC}"

# Fetch issues from Linear assigned to the user
fetch_linear_issues() {
    local query='
    query($filter: IssueFilter!) {
      issues(filter: $filter, first: 100) {
        nodes {
          identifier
          title
          description
          state {
            name
            type
          }
          url
        }
      }
    }'

    curl -s -X POST "$LINEAR_API_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: $LINEAR_API_KEY" \
        -d "$(jq -n --arg query "$query" --arg email "$LINEAR_EMAIL" '{query: $query, variables: {filter: {assignee: {email: {eq: $email}}}}}')"
}

# Fetch existing tasks from vibe-kanban
fetch_kanban_tasks() {
    curl -s "${VIBE_KANBAN_URL}/api/tasks?project_id=${VIBE_PROJECT_ID}&limit=200"
}

# Create a task in vibe-kanban
create_kanban_task() {
    local title="$1"
    local description="$2"

    curl -s -X POST "${VIBE_KANBAN_URL}/api/tasks" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg title "$title" --arg desc "$description" --arg pid "$VIBE_PROJECT_ID" '{title: $title, description: $desc, project_id: $pid}')"
}

# Update a task in vibe-kanban
update_kanban_task() {
    local task_id="$1"
    local status="$2"

    curl -s -X PUT "${VIBE_KANBAN_URL}/api/tasks/${task_id}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg status "$status" '{status: $status}')"
}

# Map Linear status to kanban status
map_status() {
    local linear_status="$1"
    local status_type="$2"

    case "$status_type" in
        "started")
            echo "inprogress"
            ;;
        "completed")
            echo "done"
            ;;
        "canceled"|"cancelled")
            echo "cancelled"
            ;;
        *)
            case "$linear_status" in
                "In Progress")
                    echo "inprogress"
                    ;;
                "In Review")
                    echo "inreview"
                    ;;
                "Done")
                    echo "done"
                    ;;
                "Duplicate"|"Canceled"|"Cancelled")
                    echo "cancelled"
                    ;;
                *)
                    echo "todo"
                    ;;
            esac
            ;;
    esac
}

# Main sync logic
main() {
    echo -e "${YELLOW}Fetching Linear issues...${NC}"
    local linear_response
    linear_response=$(fetch_linear_issues)

    # Check for errors
    if echo "$linear_response" | jq -e '.errors' > /dev/null 2>&1; then
        echo -e "${RED}Error fetching Linear issues:${NC}"
        echo "$linear_response" | jq '.errors'
        exit 1
    fi

    local issues
    issues=$(echo "$linear_response" | jq -r '.data.issues.nodes // []')
    local issue_count
    issue_count=$(echo "$issues" | jq 'length')

    echo -e "${GREEN}Found ${issue_count} Linear issues${NC}"

    echo -e "${YELLOW}Fetching kanban tasks...${NC}"
    local kanban_response
    kanban_response=$(fetch_kanban_tasks)
    local kanban_tasks
    kanban_tasks=$(echo "$kanban_response" | jq -r '.data // []')

    local created=0
    local updated=0
    local skipped=0

    # Process each Linear issue using a for loop to avoid subshell
    local issue_ids
    issue_ids=$(echo "$issues" | jq -r '.[].identifier')

    for identifier in $issue_ids; do
        local issue
        issue=$(echo "$issues" | jq -c --arg id "$identifier" '.[] | select(.identifier == $id)')
        local title
        title=$(echo "$issue" | jq -r '.title')
        local description
        description=$(echo "$issue" | jq -r '.description // ""')
        local url
        url=$(echo "$issue" | jq -r '.url')
        local status_name
        status_name=$(echo "$issue" | jq -r '.state.name')
        local status_type
        status_type=$(echo "$issue" | jq -r '.state.type')
        local kanban_status
        kanban_status=$(map_status "$status_name" "$status_type")

        # Build task title and description
        local task_title="[${identifier}] ${title}"
        local task_desc="${description}"
        task_desc="${task_desc}\n\nLinear: ${url}"

        # Check if task already exists in kanban
        local existing_task
        existing_task=$(echo "$kanban_tasks" | jq -r --arg id "[$identifier]" '.[] | select(.title | startswith($id))')

        if [[ -n "$existing_task" ]]; then
            local existing_id
            existing_id=$(echo "$existing_task" | jq -r '.id')
            local existing_status
            existing_status=$(echo "$existing_task" | jq -r '.status')

            if [[ "$existing_status" != "$kanban_status" ]]; then
                echo -e "  ${YELLOW}Updating${NC} ${identifier}: ${existing_status} -> ${kanban_status}"
                update_kanban_task "$existing_id" "$kanban_status" > /dev/null
                ((updated++)) || true
            else
                ((skipped++)) || true
            fi
        else
            echo -e "  ${GREEN}Creating${NC} ${identifier}: ${title}"
            create_kanban_task "$task_title" "$(echo -e "$task_desc")" > /dev/null

            # Get the newly created task and update its status if not todo
            if [[ "$kanban_status" != "todo" ]]; then
                sleep 0.2  # Brief delay to ensure task is created
                local new_tasks
                new_tasks=$(fetch_kanban_tasks)
                local new_task_id
                new_task_id=$(echo "$new_tasks" | jq -r --arg id "[$identifier]" '.data[] | select(.title | startswith($id)) | .id')
                if [[ -n "$new_task_id" ]]; then
                    update_kanban_task "$new_task_id" "$kanban_status" > /dev/null
                fi
            fi
            ((created++)) || true
        fi
    done

    echo ""
    echo -e "${GREEN}Sync complete!${NC}"
    echo -e "  Created: ${created}"
    echo -e "  Updated: ${updated}"
    echo -e "  Skipped: ${skipped}"
}

main
