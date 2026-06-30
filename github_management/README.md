# How to generate milestones and issues:
## milestone_generator
- Note: This should be run first in the automation pipeline (maybe combine with the second script somehow?)
1. Run the following command to get a list of repos on your organization:
```sh
gh repo list UMSAE-Formula-Electric --limit 500 --json nameWithOwner --jq '.[].nameWithOwner' > repos.txt
```
2. Output list will be in `repos.txt` so edit the list of repos as needed
3. Add a milestone that you want to add to each repo at the top of `sync-milestones.sh`
```sh
# The milestone you want to exist everywhere.
MILESTONE_TITLE="May 26th: Mock tech day"
MILESTONE_DUE_DATE="2026-05-26"          # YYYY-MM-DD (interpreted as UTC midnight)
MILESTONE_DESCRIPTION="May 26th: Mock tech day"
MILESTONE_STATE="open"                   # open | closed
```
4. Do a dry run of the command this command first to see which ones fail (if any):
```sh
./sync-milestones.sh --dry-run
```
5. Drop the `--dry-run` flag once you agree with the output

## issue_generator
6. Fill out `issues.csv` with the issue following the column types
```csv
title, description, label, milestone, assignee, status, priority, start_date, end_date, repo, template
```

