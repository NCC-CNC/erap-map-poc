#!/usr/bin/env bash
# Applies repo settings that a GitHub template does not carry over:
# branch protection on main, auto-merge, and a starter label set.
#
# Run once, from the repo root of a freshly created repo, after "Use this
# template". Requires the GitHub CLI (gh) authenticated with repo admin
# access.
#
# Usage: scripts/bootstrap-repo-settings.sh [owner/repo [check ...]]
# If owner/repo is omitted, it is inferred from the current git remote.
# Each check is the name of a CI job that must pass before a PR can merge.
# The default is "checks", the job in ci.yml that gathers all the others, so
# adding a stack job needs no re-run; list other names only if you want
# protection on them directly.

set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
shift || true
CHECKS=("$@")
[ ${#CHECKS[@]} -gt 0 ] || CHECKS=(checks)
CONTEXTS=$(printf '"%s",' "${CHECKS[@]}")
CONTEXTS="[${CONTEXTS%,}]"
echo "Bootstrapping settings for $REPO"

echo "Enabling auto-merge..."
gh api "repos/$REPO" -X PATCH -f allow_auto_merge=true >/dev/null

echo "Setting branch protection on main..."
# Sent as a JSON body (--input): `gh api -f` sends every value as a string,
# which the API rejects for these nested objects.
gh api "repos/$REPO/branches/main/protection" -X PUT --input - >/dev/null <<JSON
{
  "required_status_checks": {"strict": true, "contexts": $CONTEXTS},
  "enforce_admins": false,
  "required_pull_request_reviews": {"required_approving_review_count": 0},
  "restrictions": null
}
JSON

echo "Creating labels..."
declare -A LABELS=(
  ["enhancement"]="a2eeef"
  ["bug"]="d73a4a"
  ["chore"]="cfd3d7"
  ["docs"]="0075ca"
  ["question"]="d876e3"
)
for name in "${!LABELS[@]}"; do
  gh label create "$name" --color "${LABELS[$name]}" --force >/dev/null
done

echo "Done. Review branch protection and labels in the repo settings to confirm they fit."
