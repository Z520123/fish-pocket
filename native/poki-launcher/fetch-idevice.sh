#!/usr/bin/env bash
# Prepares the idevice checkout the launcher builds against: one pinned revision with
# native/patches/*.patch applied, in .deps/idevice-launcher. Safe to run again.
#
# The revision is pinned here rather than read from a setup script: this fork vendors only
# the launcher, and the patches are what let it mount developer images and open an XCTest
# session over RSD on iOS 26 and later.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
revision="89702099f4d7552f704f93b4526756abda319ceb"
dir="$root/.deps/idevice-launcher"
patches=("$root"/native/patches/*.patch)

if [ -e "$dir" ]; then
  echo "idevice for the launcher is already in $dir"
  exit 0
fi

mkdir -p "$root/.deps"
git init -q "$dir"
git -C "$dir" fetch -q --depth 1 https://github.com/jkcoxson/idevice.git "$revision"
git -C "$dir" checkout -q --detach FETCH_HEAD
for patch in "${patches[@]}"; do git -C "$dir" apply "$patch"; done
echo "idevice $revision with the patches is ready in $dir"
