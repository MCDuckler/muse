#!/usr/bin/env bash
# Build the desktop app — Windows and Linux — from what is actually on master, and
# publish both.
#
# The same shape as deploy/ios.sh, for the same reason: GitHub builds whatever master is
# there, so what is on this machine has to have been pushed before a build is asked for,
# or the download on the box is fresh-looking old code.
#
#   deploy/desktop.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=${MUSE_REPO:-MCDuckler/muse}

command -v gh >/dev/null || { echo "gh is how the build is asked for" >&2; exit 2; }

# What is on this machine has to be what GitHub will build — of the things that end up
# inside a desktop build. An Android signing config left modified in the tree says nothing about
# a desktop build, and a check that refuses to work for reasons that cannot matter is a
# check people learn to skip.
watched=(app/lib app/linux app/windows app/third_party app/pubspec.yaml app/pubspec.lock)
[ -z "$(git status --porcelain -- "${watched[@]}")" ] || {
  echo "uncommitted changes in what the desktop build is made of — commit them first" >&2
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
gh workflow run desktop.yml --repo "$REPO"
sleep 8
run=$(gh run list --repo "$REPO" --workflow desktop.yml --limit 1 \
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

deploy/publish.sh desktop
