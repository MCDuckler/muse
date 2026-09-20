#!/usr/bin/env bash
# Build the iPhone app from what is actually on master, and publish it.
#
# The mistake this exists to prevent, made once: dispatching the workflow and pushing
# the commit in the same breath. The dispatch went first, GitHub built the previous
# master, and the ipa on the box — with a fresh build number, looking every bit like a
# new release — was the old code. SideStore was right to say there was nothing new.
#
#   deploy/ios.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=${MUSE_REPO:-MCDuckler/muse}

command -v gh >/dev/null || { echo "gh is how the build is asked for" >&2; exit 2; }

# What is on this machine has to be what GitHub will build — of the things that end up
# inside an ipa. An Android signing config left modified in the tree says nothing about
# an iPhone build, and a check that refuses to work for reasons that cannot matter is a
# check people learn to skip.
watched=(app/lib app/ios app/pubspec.yaml app/pubspec.lock)
[ -z "$(git status --porcelain -- "${watched[@]}")" ] || {
  echo "uncommitted changes in what the iPhone build is made of — commit them first" >&2
  git status --short -- "${watched[@]}" >&2
  exit 1
}
git fetch -q origin
local_head=$(git rev-parse HEAD)
remote_head=$(git rev-parse origin/master)
[ "$local_head" = "$remote_head" ] || {
  echo "master here is $(git rev-parse --short HEAD), on GitHub it is $(git rev-parse --short origin/master)" >&2
  echo "push first: the build takes whatever GitHub has, not what is on this disk" >&2
  exit 1
}

echo "== asking for a build of ${local_head:0:8}"
gh workflow run ios.yml --repo "$REPO"
sleep 8
run=$(gh run list --repo "$REPO" --workflow ios.yml --limit 1 \
        --json databaseId,headSha --jq '.[0] | "\(.databaseId) \(.headSha)"')
id=${run%% *}
built=${run##* }
[ "$built" = "$local_head" ] || {
  echo "the run that started is building $built, not $local_head" >&2
  exit 1
}

echo "   run $id, watching"
until [ "$(gh run view "$id" --repo "$REPO" --json status --jq .status)" = "completed" ]; do
  sleep 20
done
[ "$(gh run view "$id" --repo "$REPO" --json conclusion --jq .conclusion)" = "success" ] || {
  echo "the build failed: gh run view $id --repo $REPO --log-failed" >&2
  exit 1
}

deploy/publish.sh ios
