#!/usr/bin/env bash
# =============================================================================
# UMSAE Bulk GitHub Issue Creator
# Creates issues from tasks.csv and populates a GitHub Project board.
# Requirements: gh CLI (≥2.40) + jq  — run `gh auth login` first
#
# CSV columns (leave any field blank to skip it):
#   title, description, label, milestone,
#   assignee, status, priority, start_date, end_date, repo, template
# =============================================================================

set -uo pipefail

# =============================================================================
# ✏️  CONFIGURE THESE FOR YOUR TEAM
# =============================================================================
OWNER="UMSAE-Formula-Electric"   # Your GitHub org or username
DEFAULT_REPO=""                  # Fallback repo if a CSV row has no repo column
PROJECT_NUMBER=17                # The number in the URL: /orgs/.../projects/1
CSV_FILE="issues.csv"

# Project field names, must match your board EXACTLY (capitalization matters)
STATUS_FIELD_NAME="Status"
PRIORITY_FIELD_NAME="Priority"
START_DATE_FIELD_NAME="Start Date"
END_DATE_FIELD_NAME="End Date"
# =============================================================================

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────────
command -v gh  &>/dev/null || error "gh CLI not installed — https://cli.github.com"
command -v jq  &>/dev/null || error "jq not installed — brew install jq / apt install jq"
[[ -f "$CSV_FILE" ]]       || error "CSV not found: $CSV_FILE"
gh auth status &>/dev/null || error "Not authenticated — run: gh auth login"

echo -e "\n${BOLD}UMSAE Bulk Issue Creator${RESET}"
echo "Owner   : ${OWNER}"
echo "Project : #${PROJECT_NUMBER}"
echo "CSV     : ${CSV_FILE}"
[[ -n "$DEFAULT_REPO" ]] && echo "Fallback: ${OWNER}/${DEFAULT_REPO}"
echo "──────────────────────────────────────────────────────"

# ── Fetch all project fields in one GraphQL call ─────────────────────────────
log "Fetching project metadata..."

GQL_FIELDS='
  id
  fields(first: 50) {
    nodes {
      ... on ProjectV2SingleSelectField { id name dataType options { id name } }
      ... on ProjectV2Field             { id name dataType }
    }
  }'

PROJECT_DATA=$(gh api graphql -f query="
  query(\$owner: String!, \$number: Int!) {
    organization(login: \$owner) {
      projectV2(number: \$number) { $GQL_FIELDS }
    }
  }" -f owner="$OWNER" -F number="$PROJECT_NUMBER" 2>/dev/null) || \
PROJECT_DATA=$(gh api graphql -f query="
  query(\$owner: String!, \$number: Int!) {
    user(login: \$owner) {
      projectV2(number: \$number) { $GQL_FIELDS }
    }
  }" -f owner="$OWNER" -F number="$PROJECT_NUMBER")

PROJECT_ID=$(echo "$PROJECT_DATA" | jq -r '
  .data.organization.projectV2.id // .data.user.projectV2.id')
FIELDS_JSON=$(echo "$PROJECT_DATA" | jq '
  (.data.organization.projectV2.fields.nodes // .data.user.projectV2.fields.nodes)')

[[ "$PROJECT_ID" == "null" || -z "$PROJECT_ID" ]] && \
  error "Project #${PROJECT_NUMBER} not found under '${OWNER}'. Check OWNER and PROJECT_NUMBER."

success "Project ID: $PROJECT_ID"

# ── Field lookup helpers ──────────────────────────────────────────────────────
get_field_id() {
  echo "$FIELDS_JSON" | jq -r --arg n "$1" '.[] | select(.name==$n) | .id // empty'
}
get_option_id() {
  echo "$FIELDS_JSON" | jq -r \
    --arg f "$1" --arg o "$2" \
    '.[] | select(.name==$f) | .options[]? | select(.name==$o) | .id // empty'
}

STATUS_FIELD_ID=$(get_field_id "$STATUS_FIELD_NAME")
PRIORITY_FIELD_ID=$(get_field_id "$PRIORITY_FIELD_NAME")
START_DATE_FIELD_ID=$(get_field_id "$START_DATE_FIELD_NAME")
END_DATE_FIELD_ID=$(get_field_id "$END_DATE_FIELD_NAME")

[[ -z "$STATUS_FIELD_ID"     ]] && warn "Field '${STATUS_FIELD_NAME}' not found on board — will skip"
[[ -z "$PRIORITY_FIELD_ID"   ]] && warn "Field '${PRIORITY_FIELD_NAME}' not found on board — will skip"
[[ -z "$START_DATE_FIELD_ID" ]] && warn "Field '${START_DATE_FIELD_NAME}' not found on board — will skip"
[[ -z "$END_DATE_FIELD_ID"   ]] && warn "Field '${END_DATE_FIELD_NAME}' not found on board — will skip"

# ── Project field setters ─────────────────────────────────────────────────────

# Single-select field (Status, Priority…)
set_select_field() {
  local item_id="$1" field_id="$2" option_id="$3" label="$4"
  [[ -z "$field_id" || -z "$option_id" ]] && return 0
  gh api graphql -f query='
    mutation($proj:ID!, $item:ID!, $field:ID!, $opt:String!) {
      updateProjectV2ItemFieldValue(input:{
        projectId:$proj itemId:$item fieldId:$field
        value:{singleSelectOptionId:$opt}
      }){ projectV2Item{id} }
    }' \
    -f proj="$PROJECT_ID" -f item="$item_id" \
    -f field="$field_id"  -f opt="$option_id" &>/dev/null \
    && success "  Set ${label}" \
    || warn    "  Could not set ${label} — check value matches board exactly"
}

# Date field (Start Date, End Date) — expects YYYY-MM-DD
set_date_field() {
  local item_id="$1" field_id="$2" date_val="$3" label="$4"
  [[ -z "$field_id" || -z "$date_val" ]] && return 0
  if ! [[ "$date_val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    warn "  Skipping ${label}: '${date_val}' must be YYYY-MM-DD"
    return 0
  fi
  gh api graphql -f query='
    mutation($proj:ID!, $item:ID!, $field:ID!, $date:Date!) {
      updateProjectV2ItemFieldValue(input:{
        projectId:$proj itemId:$item fieldId:$field
        value:{date:$date}
      }){ projectV2Item{id} }
    }' \
    -f proj="$PROJECT_ID" -f item="$item_id" \
    -f field="$field_id"  -f date="$date_val" &>/dev/null \
    && success "  Set ${label}" \
    || warn    "  Could not set ${label}"
}

# ── Main loop ─────────────────────────────────────────────────────────────────
CREATED=0; SKIPPED=0; FAILED=0; ROW=0

# Use Python to parse CSV properly (handles quoted fields containing commas).
_csv_rows() {
  python3 - "$CSV_FILE" <<'PYEOF'
import csv, sys
with open(sys.argv[1], newline='') as f:
    for row in csv.DictReader(f):
        fields = [
            row.get('title',''), row.get('description',''),
            row.get('label',''), row.get('milestone',''),
            row.get('assignee',''), row.get('status',''),
            row.get('priority',''), row.get('start_date',''),
            row.get('end_date',''), row.get('repo',''),
            row.get('template',''),
        ]
        print('\x1f'.join(fields))
PYEOF
}

while IFS=$'\x1f' read -r \
  TITLE DESC LABEL MILESTONE \
  ASSIGNEE STATUS PRIORITY START_DATE END_DATE \
  REPO TEMPLATE
do
  ROW=$((ROW + 1))

  # ── Repo resolution ──────────────────────────────────────────────────────────
  [[ -z "$REPO" && -n "$DEFAULT_REPO" ]] && REPO="$DEFAULT_REPO"
  if [[ -z "$REPO" ]]; then
    warn "Row $ROW: no repo specified and DEFAULT_REPO is not set — skipping"
    FAILED=$((FAILED + 1)); continue
  fi

  [[ -z "$TITLE" ]] && { warn "Row $ROW: empty title — skipping"; continue; }

  echo -e "\n${BOLD}[${ROW}] ${TITLE}${RESET}  ${CYAN}→ ${OWNER}/${REPO}${RESET}"

  # ── Duplicate check ───────────────────────────────────────────────────────────
  EXISTING=$(gh issue list --repo "${OWNER}/${REPO}" \
    --search "\"${TITLE}\" in:title" \
    --state all --json title,number --limit 20 \
    --jq ".[] | select(.title == \"${TITLE}\") | .number" 2>/dev/null | head -1)
  if [[ -n "$EXISTING" ]]; then
    warn "Skipping — already exists as #${EXISTING}: ${TITLE}"
    SKIPPED=$((SKIPPED + 1)); continue
  fi

  # ── Build issue body ──────────────────────────────────────────────────────────
  # When a template is specified with a description, wrap under the template header.
  # When only a template and no description, gh will use the template's own body.
  # Blank description with no template = no body (GitHub default).
  if [[ -n "$TEMPLATE" && -n "$DESC" ]]; then
    BODY="## Task Description"$'\n'"${DESC}"
  elif [[ -n "$DESC" ]]; then
    BODY="$DESC"
  else
    BODY=""
  fi

  # ── Build gh args ─────────────────────────────────────────────────────────────
  GH_ARGS=(--repo "${OWNER}/${REPO}" --title "$TITLE")

  if [[ -n "$BODY" ]]; then
    GH_ARGS+=(--body "$BODY")
  elif [[ -n "$TEMPLATE" ]]; then
    GH_ARGS+=(--template "$TEMPLATE")   # template filename e.g. mech_issue_template.md
  fi

  [[ -n "$LABEL"      ]] && GH_ARGS+=(--label      "$LABEL")
  [[ -n "$MILESTONE"  ]] && GH_ARGS+=(--milestone  "$MILESTONE")
  [[ -n "$ASSIGNEE"   ]] && GH_ARGS+=(--assignee   "$ASSIGNEE")

  # ── Create issue ──────────────────────────────────────────────────────────────
  ISSUE_URL=$(gh issue create "${GH_ARGS[@]}" 2>/tmp/gh_err) || {
    warn "Failed to create issue — $(head -1 /tmp/gh_err)"
    warn "  Tip: verify label / milestone / issue-type exist in ${OWNER}/${REPO}"
    FAILED=$((FAILED + 1)); continue
  }

  ISSUE_NUMBER=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
  success "Created #${ISSUE_NUMBER}: ${ISSUE_URL}"

  # ── Add to project board ──────────────────────────────────────────────────────
  ISSUE_NODE_ID=$(gh api "repos/${OWNER}/${REPO}/issues/${ISSUE_NUMBER}" \
    --jq '.node_id' 2>/dev/null)

  ITEM_ID=$(gh api graphql -f query='
    mutation($proj:ID!, $content:ID!) {
      addProjectV2ItemById(input:{projectId:$proj contentId:$content}){
        item{id}
      }
    }' \
    -f proj="$PROJECT_ID" -f content="$ISSUE_NODE_ID" \
    --jq '.data.addProjectV2ItemById.item.id' 2>/dev/null) || {
      warn "  Could not add to project board — issue was still created"
      CREATED=$((CREATED + 1)); continue
  }
  success "  Added to project board"

  # ── Set project fields (blank = skip) ─────────────────────────────────────────
  if [[ -n "$STATUS" && -n "$STATUS_FIELD_ID" ]]; then
    OPT=$(get_option_id "$STATUS_FIELD_NAME" "$STATUS")
    set_select_field "$ITEM_ID" "$STATUS_FIELD_ID" "$OPT" "Status → ${STATUS}"
  fi

  if [[ -n "$PRIORITY" && -n "$PRIORITY_FIELD_ID" ]]; then
    OPT=$(get_option_id "$PRIORITY_FIELD_NAME" "$PRIORITY")
    set_select_field "$ITEM_ID" "$PRIORITY_FIELD_ID" "$OPT" "Priority → ${PRIORITY}"
  fi

  set_date_field "$ITEM_ID" "$START_DATE_FIELD_ID" "$START_DATE" "Start Date → ${START_DATE}"
  set_date_field "$ITEM_ID" "$END_DATE_FIELD_ID"   "$END_DATE"   "End Date → ${END_DATE}"

  CREATED=$((CREATED + 1))

done < <(_csv_rows)

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n──────────────────────────────────────────────────────"
echo -e "${BOLD}Done.${RESET}  Created: ${GREEN}${CREATED}${RESET}   Skipped: ${YELLOW}${SKIPPED}${RESET}   Failed: ${RED}${FAILED}${RESET}"