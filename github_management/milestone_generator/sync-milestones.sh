#!/usr/bin/env bash
#
# sync-milestones.sh
#
# Create (or update) an identically-named, identically-dated milestone
# across many GitHub repositories, so it renders as a single labeled
# vertical pin on a cross-repo Project roadmap.
#
# If a milestone with the same title already exists in a repo,
# it is UPDATED (due date / description / state) instead of duplicating so it
# is safe to re-run.
#
# Requirements:
#   - gh CLI installed and authenticated:  gh auth login
#   - The authenticated user needs write access to each repo.
#
# Usage:
#   ./sync-milestones.sh                # apply changes
#   ./sync-milestones.sh --dry-run      # show what would happen, change nothing
#
# ---------------------------------------------------------------------------

set -euo pipefail

# ============================ CONFIGURE ME =================================

# The milestone you want to exist everywhere.
MILESTONE_TITLE="PLACEHOLDER TITLE"
MILESTONE_DUE_DATE="2026-06-03"          # YYYY-MM-DD (interpreted as UTC midnight)
MILESTONE_DESCRIPTION="June 3st: PLACEHOLDER DESCRIPTION"
MILESTONE_STATE="open"                   # open | closed

# The repos to apply it to, as owner/repo. Edit this list.
# Alternatively, set REPOS_FILE to a path with one owner/repo per line
# (lines starting with # are ignored) and leave this array empty.
REPOS=(
  "my-org/service-api"
  "my-org/service-web"
  "my-org/service-worker"
  "my-org/shared-libs"
)
REPOS_FILE="./repos.txt"                            # e.g. "./repos.txt" —> overrides REPOS if set

# ==========================================================================

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

DUE_ON="${MILESTONE_DUE_DATE}T12:00:00Z"

# Load repo list from file if provided.
if [[ -n "$REPOS_FILE" ]]; then
  if [[ ! -f "$REPOS_FILE" ]]; then
    echo "ERROR: REPOS_FILE '$REPOS_FILE' not found." >&2
    exit 1
  fi
  # Portable (works on macOS's built-in bash 3.2 — no mapfile).
  REPOS=()
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    case "$_line" in
      ''|'#'*) continue ;;   # skip blank lines and comments
    esac
    REPOS+=("$_line")
  done < "$REPOS_FILE"
fi

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "ERROR: No repos configured. Edit the REPOS array or set REPOS_FILE." >&2
  exit 1
fi

# Sanity checks.
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not found." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated. Run: gh auth login" >&2; exit 1; }

echo "Milestone : $MILESTONE_TITLE"
echo "Due date  : $MILESTONE_DUE_DATE"
echo "State     : $MILESTONE_STATE"
echo "Repos     : ${#REPOS[@]}"
$DRY_RUN && echo "Mode      : DRY RUN (no changes will be made)"
echo "---------------------------------------------------------------"

created=0; updated=0; skipped=0; failed=0

for repo in "${REPOS[@]}"; do
  repo="$(echo "$repo" | xargs)"   # trim whitespace
  [[ -z "$repo" ]] && continue

  # Find an existing milestone with the same title (search open + closed).
  existing_number=""
  if existing_json=$(gh api --paginate \
        "repos/${repo}/milestones?state=all" 2>/dev/null); then
    existing_number=$(echo "$existing_json" \
      | jq -r --arg t "$MILESTONE_TITLE" \
          'first(.[] | select(.title == $t) | .number) // empty')
  else
    echo "FAIL   $repo  (could not list milestones — check access)"
    failed=$((failed+1)); continue
  fi

  if [[ -n "$existing_number" ]]; then
    # Update the existing milestone so date/description stay in sync.
    if $DRY_RUN; then
      echo "UPDATE $repo  (milestone #$existing_number — dry run)"
      updated=$((updated+1)); continue
    fi
    if gh api --method PATCH \
        "repos/${repo}/milestones/${existing_number}" \
        -f title="$MILESTONE_TITLE" \
        -f state="$MILESTONE_STATE" \
        -f description="$MILESTONE_DESCRIPTION" \
        -f due_on="$DUE_ON" >/dev/null 2>&1; then
      echo "UPDATE $repo  (milestone #$existing_number)"
      updated=$((updated+1))
    else
      echo "FAIL   $repo  (update failed)"
      failed=$((failed+1))
    fi
  else
    # Create a new milestone.
    if $DRY_RUN; then
      echo "CREATE $repo  (dry run)"
      created=$((created+1)); continue
    fi
    if gh api --method POST \
        "repos/${repo}/milestones" \
        -f title="$MILESTONE_TITLE" \
        -f state="$MILESTONE_STATE" \
        -f description="$MILESTONE_DESCRIPTION" \
        -f due_on="$DUE_ON" >/dev/null 2>&1; then
      echo "CREATE $repo"
      created=$((created+1))
    else
      echo "FAIL   $repo  (create failed)"
      failed=$((failed+1))
    fi
  fi
done

echo "---------------------------------------------------------------"
echo "Created: $created  Updated: $updated  Skipped: $skipped  Failed: $failed"
$DRY_RUN && echo "(dry run — nothing was actually changed)"
[[ $failed -gt 0 ]] && exit 1 || exit 0
