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
    echo "  VIBE_PROJECT_ID=...    # UUID of the vibe-kanban remote project"
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

    if [[ -z "$VIBE_PROJECT_ID" ]]; then
        echo -e "${RED}Error: VIBE_PROJECT_ID is not set${NC}"
        echo "  Set the vibe-kanban remote project UUID"
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
VIBE_REMOTE_URL="https://api.vibekanban.com"
LINEAR_API_URL="https://api.linear.app/graphql"
VIBE_TARGET_BRANCH="${VIBE_TARGET_BRANCH:-main}"
VIBE_EXECUTOR="${VIBE_EXECUTOR:-CLAUDE_CODE}"

echo -e "${BLUE}Syncing Linear tasks for ${LINEAR_EMAIL}...${NC}"

# Fetch a fresh auth token from the local vibe-kanban server (called per-request, token TTL is ~2 min)
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

# Wrapper: call the remote API with a fresh token each time
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

# Fetch project statuses from vibe-kanban remote
fetch_project_statuses() {
    remote_api GET "/v1/fallback/project_statuses?project_id=${VIBE_PROJECT_ID}"
}

# Fetch existing issues from vibe-kanban project
fetch_project_issues() {
    remote_api GET "/v1/fallback/issues?project_id=${VIBE_PROJECT_ID}&limit=200"
}

# Create a vibe-kanban issue in the project
create_project_issue() {
    local issue_id="$1"
    local title="$2"
    local description="$3"
    local status_id="$4"

    remote_api POST "/v1/issues" \
        -H "Content-Type: application/json" \
        --data-binary "$(jq -n \
            --arg id "$issue_id" \
            --arg project_id "$VIBE_PROJECT_ID" \
            --arg title "$title" \
            --arg desc "$description" \
            --arg status_id "$status_id" \
            '{id: $id, project_id: $project_id, title: $title, description: $desc,
              status_id: $status_id, sort_order: 0, extension_metadata: {}}')"
}

# Create a workspace in vibe-kanban linked to a project issue
create_linked_workspace() {
    local name="$1"
    local prompt="$2"
    local issue_id="$3"

    curl -s -X POST "${VIBE_KANBAN_URL}/api/task-attempts/create-and-start" \
        -H "Content-Type: application/json" \
        --data-binary "$(jq -n \
            --arg name "$name" \
            --arg prompt "$prompt" \
            --arg repo_id "$VIBE_REPO_ID" \
            --arg branch "$VIBE_TARGET_BRANCH" \
            --arg executor "$VIBE_EXECUTOR" \
            --arg issue_id "$issue_id" \
            --arg project_id "$VIBE_PROJECT_ID" \
            '{
                name: $name,
                prompt: $prompt,
                executor_config: {executor: $executor, variant: "DEFAULT"},
                repos: [{repo_id: $repo_id, target_branch: $branch}],
                linked_issue: {remote_project_id: $project_id, issue_id: $issue_id}
            }')"
}

# Map Linear status type/name to vibe-kanban status name
map_status_name() {
    local status_name="$1"
    local status_type="$2"

    case "$status_type" in
        "started")    echo "In progress" ;;
        "completed")  echo "Done" ;;
        "canceled"|"cancelled") echo "Cancelled" ;;
        *)
            case "$status_name" in
                "In Progress")  echo "In progress" ;;
                "In Review")    echo "In review" ;;
                "Done")         echo "Done" ;;
                "Duplicate"|"Canceled"|"Cancelled") echo "Cancelled" ;;
                *)              echo "To do" ;;
            esac
            ;;
    esac
}

# Generate a UUID (compatible with both Linux and macOS)
new_uuid() {
    python3 -c "import uuid; print(str(uuid.uuid4()))"
}

# Main sync logic
main() {
    echo -e "${YELLOW}Verifying vibe-kanban auth...${NC}"
    vibe_token > /dev/null  # fail fast if not authenticated

    echo -e "${YELLOW}Fetching project statuses...${NC}"
    local statuses_json
    statuses_json=$(fetch_project_statuses)
    if ! echo "$statuses_json" | jq -e '.project_statuses' > /dev/null 2>&1; then
        echo -e "${RED}Error fetching project statuses:${NC}"
        echo "$statuses_json"
        exit 1
    fi

    echo -e "${YELLOW}Fetching existing project issues...${NC}"
    local issues_json
    issues_json=$(fetch_project_issues)
    local existing_issues
    existing_issues=$(echo "$issues_json" | jq -r '.issues // []')

    echo -e "${YELLOW}Fetching Linear issues...${NC}"
    local linear_response
    linear_response=$(fetch_linear_issues)

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

    local created=0
    local skipped=0

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

        # Map to vibe-kanban status name, then look up its ID
        local vibe_status_name
        vibe_status_name=$(map_status_name "$status_name" "$status_type")
        local status_id
        status_id=$(echo "$statuses_json" | jq -r --arg name "$vibe_status_name" \
            '.project_statuses[] | select(.name == $name) | .id')
        # Fallback to "To do" if status not found
        if [[ -z "$status_id" ]]; then
            status_id=$(echo "$statuses_json" | jq -r \
                '.project_statuses[] | select(.name == "To do") | .id')
        fi

        # Build issue title and description
        local issue_title="[${identifier}] ${title}"
        local issue_desc
        issue_desc="$(printf '%s\n\nLinear: %s' "$description" "$url")"

        # Check if issue already exists in the project
        local existing
        existing=$(echo "$existing_issues" | jq -r --arg id "[$identifier]" \
            '.[] | select(.title | startswith($id))')

        if [[ -n "$existing" ]]; then
            echo -e "  ${YELLOW}Skipping${NC} ${identifier}: already in project"
            ((skipped++)) || true
        else
            echo -e "  ${GREEN}Creating${NC} ${identifier}: ${title}"

            # Create the vibe-kanban project issue
            local new_issue_id
            new_issue_id=$(new_uuid)
            local create_result
            create_result=$(create_project_issue "$new_issue_id" "$issue_title" "$issue_desc" "$status_id")

            if ! echo "$create_result" | jq -e '.data.id' > /dev/null 2>&1; then
                echo -e "  ${RED}Failed${NC} to create issue for ${identifier}: $create_result"
                continue
            fi

            local vibe_issue_id
            vibe_issue_id=$(echo "$create_result" | jq -r '.data.id')

            # Create a workspace linked to the issue
            local workspace_prompt
            workspace_prompt="$(printf '%s\n\nStatus: %s\nLinear: %s\n\n%s' "$title" "$status_name" "$url" "$description")"
            local ws_result
            ws_result=$(create_linked_workspace "$issue_title" "$workspace_prompt" "$vibe_issue_id")

            if echo "$ws_result" | jq -e '.success == true' > /dev/null 2>&1; then
                ((created++)) || true
            else
                echo -e "  ${RED}Failed${NC} to create workspace for ${identifier}:"
                echo "$ws_result" | jq -r '.message // .error_data // .'
            fi
        fi
    done

    echo ""
    echo -e "${GREEN}Sync complete!${NC}"
    echo -e "  Created: ${created}"
    echo -e "  Skipped: ${skipped}"
}

main
