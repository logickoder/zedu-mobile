#!/usr/bin/env bash
# Build an upstream batch branch: zeduchat's base + every ticket commit since, minus review-org changes.
#
#   BASE_REF       upstream base, e.g. upstream/central-staging (zeduchat)
#   SOURCE_REF     review-org branch to send, e.g. origin/central-staging (zedu-hng)
#   REVIEW_REPO    review-org repo for PR label lookups, e.g. zedu-hng/zedu-mobile
#   OUT_BRANCH     batch branch to create locally
#   EXCLUDE_FILE   path list (default .github/upstream-exclude), read from the current checkout
#   SKIP_LABEL     PR label whose commits are skipped (default review-org-only)
#
# Replays each non-merge commit in BASE_REF..SOURCE_REF in order, keeping author and message.
# Commits from PRs with SKIP_LABEL are skipped; excluded paths are reset to the base version;
# commits left empty are dropped. Fails on a real conflict, or if any excluded path differs from base.
# Writes a Markdown summary to batch-summary.md.
set -euo pipefail

: "${BASE_REF:?}" "${SOURCE_REF:?}" "${REVIEW_REPO:?}" "${OUT_BRANCH:?}"
EXCLUDE_FILE=${EXCLUDE_FILE:-.github/upstream-exclude}
SKIP_LABEL=${SKIP_LABEL-review-org-only}

base_sha=$(git rev-parse "$BASE_REF^{commit}")
excludes=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$EXCLUDE_FILE" | grep -v '^$')

is_excluded() {
  local path=$1 entry
  while IFS= read -r entry; do
    case "$entry" in
      */) [[ "$path" == "$entry"* ]] && return 0 ;;
      *)  [[ "$path" == "$entry" ]] && return 0 ;;
    esac
  done <<< "$excludes"
  return 1
}

# Reset an excluded path to the base version, or remove it if the base doesn't have it.
reset_path() {
  if git cat-file -e "$base_sha:$1" 2>/dev/null; then
    git checkout -q "$base_sha" -- "$1"
  else
    git rm -q -f --cached -- "$1" 2>/dev/null || true
    rm -f -- "$1"
  fi
}

git switch -q -C "$OUT_BRANCH" "$base_sha"

sent=() skipped=() empty=()
for sha in $(git rev-list --reverse --no-merges "$base_sha..$SOURCE_REF"); do
  short=${sha:0:7}
  subject=$(git log -1 --format=%s "$sha")
  author=$(git log -1 --format=%an "$sha")

  if [ -n "$SKIP_LABEL" ]; then
    labels=$(gh api "repos/$REVIEW_REPO/commits/$sha/pulls" --jq '[.[].labels[].name] | join(",")')
    if [[ ",$labels," == *",$SKIP_LABEL,"* ]]; then
      skipped+=("$short $subject")
      continue
    fi
  fi

  if ! git cherry-pick -n "$sha" >/dev/null 2>&1; then
    conflicted=$(git diff --name-only --diff-filter=U)
    real=""
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      is_excluded "$f" || real+="$f "
    done <<< "$conflicted"
    if [ -n "$real" ]; then
      git reset -q --hard
      echo "::error::Conflict replaying $short ($subject) by $author in: $real. Resolve by hand." >&2
      exit 1
    fi
  fi

  while IFS= read -r f; do
    [ -n "$f" ] && is_excluded "$f" && reset_path "$f"
  done <<< "$(git diff --cached --name-only; git diff --name-only --diff-filter=U)"

  if git diff --cached --quiet; then
    git reset -q --hard
    empty+=("$short $subject")
    continue
  fi
  git commit -q --no-verify -C "$sha"
  sent+=("$short $subject ($author)")
done

# Safety gate: no excluded path may differ from the base.
leaked=""
while IFS= read -r f; do
  [ -n "$f" ] && is_excluded "$f" && leaked+="$f "
done <<< "$(git diff --name-only "$base_sha" HEAD)"
if [ -n "$leaked" ]; then
  echo "::error::Excluded paths would reach upstream: $leaked" >&2
  exit 1
fi

{
  echo "### Upstream batch \`$OUT_BRANCH\`"
  echo
  echo "Base: \`$BASE_REF\` (${base_sha:0:7}). Source: \`$SOURCE_REF\`."
  echo
  echo "**Sent (${#sent[@]}):**"
  for s in "${sent[@]+"${sent[@]}"}"; do echo "- $s"; done
  echo
  echo "**Skipped, \`$SKIP_LABEL\` (${#skipped[@]}):**"
  for s in "${skipped[@]+"${skipped[@]}"}"; do echo "- $s"; done
  echo
  echo "**Dropped, review-org changes only (${#empty[@]}):**"
  for s in "${empty[@]+"${empty[@]}"}"; do echo "- $s"; done
} > batch-summary.md
echo "sent=${#sent[@]}"
