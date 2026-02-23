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
    echo "  VIBE_REPO_ID=...       # UUID of the repo in vibe-kanban (from /api/repos)"
    echo "  VIBE_TARGET_BRANCH=... # Optional: target branch (default: main)"
    echo "  VIBE_EXECUTOR=...      # Optional: executor (default: CLAUDE_CODE)"
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

    if [[ -z "$VIBE_REPO_ID" ]]; then
        echo -e "${RED}Error: VIBE_REPO_ID is not set${NC}"
        echo "  Set the vibe-kanban repo UUID (run: curl http://127.0.0.1:\$VIBE_KANBAN_PORT/api/repos)"
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
VIBE_TARGET_BRANCH="${VIBE_TARGET_BRANCH:-main}"
VIBE_EXECUTOR="${VIBE_EXECUTOR:-CLAUDE_CODE}"

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
        --data-binary "$(jq -n --arg query "$query" --arg email "$LINEAR_EMAIL" '{query: $query, variables: {filter: {assignee: {email: {eq: $email}}}}}')"
}

# Fetch existing workspaces from vibe-kanban
fetch_kanban_workspaces() {
    curl -s "${VIBE_KANBAN_URL}/api/task-attempts"
}

# Create a workspace in vibe-kanban for a Linear issue
create_kanban_workspace() {
    local name="$1"
    local prompt="$2"

    curl -s -X POST "${VIBE_KANBAN_URL}/api/task-attempts/create-and-start" \
        -H "Content-Type: application/json" \
        --data-binary "$(jq -n \
            --arg name "$name" \
            --arg prompt "$prompt" \
            --arg repo_id "$VIBE_REPO_ID" \
            --arg branch "$VIBE_TARGET_BRANCH" \
            --arg executor "$VIBE_EXECUTOR" \
            '{
                name: $name,
                prompt: $prompt,
                executor_config: {executor: $executor, variant: "DEFAULT"},
                repos: [{repo_id: $repo_id, target_branch: $branch}],
                linked_issue: null
            }')"
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

    echo -e "${YELLOW}Fetching vibe-kanban workspaces...${NC}"
    local kanban_response
    kanban_response=$(fetch_kanban_workspaces)
    local kanban_workspaces
    kanban_workspaces=$(echo "$kanban_response" | jq -r '.data // []')

    local created=0
    local skipped=0

    # Process each Linear issue
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

        # Build workspace name and prompt
        local workspace_name="[${identifier}] ${title}"
        local workspace_prompt
        workspace_prompt="$(printf '%s\n\nStatus: %s\nLinear: %s\n\n%s' "$title" "$status_name" "$url" "$description")"

        # Check if workspace already exists (match by [IDENTIFIER] prefix in name)
        local existing
        existing=$(echo "$kanban_workspaces" | jq -r --arg id "[$identifier]" '.[] | select(.name | startswith($id))')

        if [[ -n "$existing" ]]; then
            echo -e "  ${YELLOW}Skipping${NC} ${identifier}: workspace already exists"
            ((skipped++)) || true
        else
            echo -e "  ${GREEN}Creating${NC} ${identifier}: ${title}"
            local result
            result=$(create_kanban_workspace "$workspace_name" "$workspace_prompt")
            if echo "$result" | jq -e '.success == true' > /dev/null 2>&1; then
                ((created++)) || true
            else
                echo -e "  ${RED}Failed${NC} to create workspace for ${identifier}:"
                echo "$result" | jq -r '.message // .error_data // .'
            fi
        fi
    done

    echo ""
    echo -e "${GREEN}Sync complete!${NC}"
    echo -e "  Created: ${created}"
    echo -e "  Skipped: ${skipped}"
}

main
