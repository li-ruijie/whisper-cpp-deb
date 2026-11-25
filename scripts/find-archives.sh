#!/usr/bin/env bash
# Print the tag of the upstream release carrying the Linux archives for a
# semantic tag, or nothing when no release carries them.
#
# Every release up to v1.9.2 carried its own archives, and from v1.9.3 they sit
# on the nightly cut from the same commit, so prefer the semantic release and
# fall back to that nightly. Matching on the commit rather than on publication
# order, since a nightly for an entirely different commit is worse than no
# build at all. v1.9.6 got neither, upstream skipping its Linux build.
#
# Every API call is captured before it is used, so a failure exits non-zero
# under set -e. Read as no release carrying the archives, an outage would let
# the scheduled run skip quietly instead of failing.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <tag>" >&2
    exit 2
fi
tag=$1
repo=repos/ggml-org/whisper.cpp

assets=$(gh api "$repo/releases/tags/$tag" --jq '.assets[].name')
if printf '%s\n' "$assets" | grep -qx 'whisper-bin-ubuntu-x64.tar.gz'; then
    printf '%s\n' "$tag"
    exit 0
fi

sha=$(gh api "$repo/commits/$tag" --jq '.sha')
# One page suffices, upstream keeping only a handful of nightlies at a time.
nightlies=$(gh api "$repo/releases?per_page=100" \
    --jq '.[] | select(.tag_name | test("^b[0-9]+$")) | .tag_name')
for cand in $nightlies; do
    cand_sha=$(gh api "$repo/commits/$cand" --jq '.sha')
    if [ "$cand_sha" = "$sha" ]; then
        printf '%s\n' "$cand"
        exit 0
    fi
done
