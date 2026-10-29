#!/usr/bin/env bash
# Check that a tag on GitHub still points at the commit the release gate approved.
#
#   GH_TOKEN=... app/Scripts/verify-tag.sh <tag> <sha> [owner/repo]     (repo defaults to $GITHUB_REPOSITORY)
#
# The gate resolves the tag to a commit once; every later job checks out that commit and calls this before it
# builds or publishes, so a tag that was deleted and recreated (or force-moved) in between is caught. A tag
# ruleset that forbids updating and deleting v* tags (RELEASING.md) makes that impossible in the first place;
# this is the belt to its braces. Annotated tags are peeled through to the commit. Needs the gh CLI.
set -euo pipefail
TAG="${1:?usage: verify-tag.sh TAG SHA [OWNER/REPO]}"; SHA="${2:?usage: verify-tag.sh TAG SHA [OWNER/REPO]}"
REPO="${3:-${GITHUB_REPOSITORY:?no repository given}}"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "verify-tag: '$SHA' is not a full commit SHA" >&2; exit 2; }
ref() { gh api "repos/$REPO/$1" --jq '.object.type + " " + .object.sha'; }
out="$(ref "git/ref/tags/$TAG")" || { echo "verify-tag: tag $TAG does not exist in $REPO (or the GitHub API failed)" >&2; exit 1; }
type="${out% *}"; obj="${out#* }"
for _ in 1 2 3 4; do   # annotated (and nested annotated) tags point at tag objects first
  [ "$type" = tag ] || break
  out="$(ref "git/tags/$obj")" || { echo "verify-tag: could not read tag object $obj" >&2; exit 1; }
  type="${out% *}"; obj="${out#* }"
done
[ "$type" = commit ] || { echo "verify-tag: $TAG does not point at a commit ($type)" >&2; exit 1; }
if [ "$obj" != "$SHA" ]; then
  echo "verify-tag: REFUSED: tag $TAG now points at ${obj:0:12}, but this release was approved at ${SHA:0:12}. The tag moved while the release ran." >&2
  exit 1
fi
echo "verify-tag: $TAG still points at ${SHA:0:12}"
