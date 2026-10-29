#!/usr/bin/env bash
# Refuse a release tag that breaks the rules in RELEASING.md. Run inside a full clone (tags and
# origin/main fetched) with the tag present.
#
#   release-gate.sh vX.Y.Z[-beta.N] [--allow-unsoaked] [--main-ref origin/main]
#
#   - the tag must be well-formed (version.py)
#   - stable: its commit must be reachable from main, or from the hotfix branch release/X.Y of its own
#     minor version (a hotfix is cut there and may not be merged back yet)
#   - stable: a beta tag of the same X.Y.Z must already exist (the promotion rule), unless
#     --allow-unsoaked; if the stable's commit is not the newest beta's commit it says so
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${1:?usage: release-gate.sh TAG [--allow-unsoaked] [--main-ref REF]}"; shift
ALLOW=0; MAIN_REF="origin/main"
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-unsoaked) ALLOW=1; shift ;;
    --main-ref) MAIN_REF="${2:?}"; shift 2 ;;
    *) echo "release-gate: unknown option $1" >&2; exit 64 ;;
  esac
done
refuse() { echo "release-gate: REFUSED: $*" >&2; exit 1; }

FIELDS="$(python3 -I "$HERE/version.py" "$TAG" --env)" || exit 2
eval "$FIELDS"
COMMIT="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}")" || refuse "tag $TAG is not in this clone"
echo "release-gate: $TAG -> $SHORT ($CHANNEL), build $BUILD, commit ${COMMIT:0:12}"

[ "$CHANNEL" = stable ] || { echo "release-gate: beta: OK"; exit 0; }

minor="${BASE%.*}"
on_main=0; git merge-base --is-ancestor "$COMMIT" "$MAIN_REF" 2>/dev/null && on_main=1
on_branch=0
if [ "$on_main" = 0 ]; then
  rb="${MAIN_REF%/*}/release/$minor"
  git rev-parse -q --verify "$rb" >/dev/null 2>&1 && git merge-base --is-ancestor "$COMMIT" "$rb" 2>/dev/null && on_branch=1
fi
[ "$on_main" = 1 ] || [ "$on_branch" = 1 ] || refuse "stable $TAG is on neither $MAIN_REF nor release/$minor; stable releases come from main or a hotfix branch"

latest_beta=""
while IFS= read -r t; do
  if python3 -I "$HERE/version.py" has-beta "$TAG" <<<"$t"; then latest_beta="$t"; fi
done < <(git tag -l 'v*' | sort -V)
if [ -z "$latest_beta" ]; then
  [ "$ALLOW" = 1 ] || refuse "no beta of ${BASE} exists. Cut v${BASE}-beta.1 first and let it soak (or set allow_unsoaked_stable to override)"
  echo "release-gate: WARNING: promotion rule overridden: no beta of ${BASE}"
else
  beta_commit="$(git rev-parse "refs/tags/$latest_beta^{commit}")"
  if [ "$beta_commit" != "$COMMIT" ]; then
    echo "release-gate: note: $TAG is not the commit of $latest_beta (${beta_commit:0:12}); it ships changes the beta did not soak"
  fi
fi
echo "release-gate: OK"
