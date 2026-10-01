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
# Replays each non-merge commit in BASE_REF..SOURCE_REF in order, keeping author, date and message,
# and adds an "Upstream-Source: <sha>" trailer. Commits whose trailer already appears in BASE_REF's
# history were delivered by an earlier batch and are skipped, as are commits from PRs with SKIP_LABEL.
# Excluded paths are reset to the base version; commits left empty are dropped. Fails on a real
# conflict, or if any excluded path differs from base.
# Writes a Markdown summary to batch-summary.md.
set -euo pipefail

: "${BASE_REF:?}" "${SOURCE_REF:?}" "${REVIEW_REPO:?}" "${OUT_BRANCH:?}"
EXCLUDE_FILE=${EXCLUDE_FILE:-.github/upstream-exclude}
SKIP_LABEL=${SKIP_LABEL-review-org-only}

base_sha=$(git rev-parse "$BASE_REF^{commit}")
# Replayed commits get new IDs, so earlier deliveries are tracked by trailer, not by ancestry.
delivered=$(git log --format=%B "$base_sha" | sed -n 's/^Upstream-Source: \([0-9a-f]\{40\}\)$/\1/p' | sort -u)
# NUL-delimited raw paths (git quotes names with quotes, backslashes or control characters even with
# core.quotePath=off) and no rename detection (a rename shows its deleted source).
changed() { git diff --no-renames --name-only -z "$@"; }
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
msg_file=$(mktemp)
trap 'rm -f "$msg_file"' EXIT

sent=() skipped=() empty=() already=()
for sha in $(git rev-list --reverse --no-merges "$base_sha..$SOURCE_REF"); do
  short=${sha:0:7}
  subject=$(git log -1 --format=%s "$sha")
  author=$(git log -1 --format=%an "$sha")

  if grep -qx "$sha" <<< "$delivered"; then
    already+=("$short $subject")
    continue
  fi

  if [ -n "$SKIP_LABEL" ]; then
    labels=$(gh api "repos/$REVIEW_REPO/commits/$sha/pulls" --jq '[.[].labels[].name] | join(",")')
    if [[ ",$labels," == *",$SKIP_LABEL,"* ]]; then
      skipped+=("$short $subject")
      continue
    fi
  fi

  if ! git cherry-pick -n "$sha" >/dev/null 2>&1; then
    real=""
    while IFS= read -r -d '' f; do
      is_excluded "$f" || real+="$f "
    done < <(changed --diff-filter=U)
    if [ -n "$real" ]; then
      git reset -q --hard
      echo "::error::Conflict replaying $short ($subject) by $author in: $real. Resolve by hand." >&2
      exit 1
    fi
  fi

  while IFS= read -r -d '' f; do
    if is_excluded "$f"; then reset_path "$f"; fi
  done < <(changed --cached; changed --diff-filter=U)

  if git diff --cached --quiet; then
    git reset -q --hard
    empty+=("$short $subject")
    continue
  fi
  git log -1 --format=%B "$sha" | git interpret-trailers --trailer "Upstream-Source: $sha" > "$msg_file"
  git commit -q --no-verify -F "$msg_file" \
    --author="$(git log -1 --format='%an <%ae>' "$sha")" --date="$(git log -1 --format=%aD "$sha")"
  sent+=("$short $subject ($author)")
done

# Safety gate: no excluded path may differ from the base.
leaked=""
while IFS= read -r -d '' f; do
  if is_excluded "$f"; then leaked+="$f "; fi
done < <(changed "$base_sha" HEAD)
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
  echo
  echo "**Already delivered in an earlier batch (${#already[@]}):**"
  for s in "${already[@]+"${already[@]}"}"; do echo "- $s"; done
} > batch-summary.md
echo "sent=${#sent[@]}"
