#!/usr/bin/env bash
# Decide the Debian version, the release tag, and whether to build, from the
# upstream tag, an optional packaging revision, and the version already in
# li-ruijie/apt. Prints version=, release_tag=, and skip= lines for
# $GITHUB_OUTPUT on success, and the reason on stderr.
#
# A revision ships a packaging change against an unchanged upstream version,
# 1.9.5-1 sorting above 1.9.5 for apt. Without one, the version is the upstream
# version alone, as every release before revisions existed was.
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <tag> <revision> <deployed> <force>" >&2
    exit 2
fi
tag=$1 revision=$2 deployed=$3 force=$4
upstream=${tag#v}

# Without dpkg the ordering check below would fail as a condition and let a
# version apt never installs through, so its absence stops the run instead.
command -v dpkg >/dev/null 2>&1 || { echo "$0: dpkg is required" >&2; exit 2; }

# A b<N> tag would otherwise reach package-base.sh a job later and be rejected
# there, having already downloaded 65 MB.
case "$upstream" in
    [0-9]*) ;;
    *) echo "$tag is not a semantic tag, so $upstream is not a Debian version" >&2; exit 1 ;;
esac

case "$revision" in
    '') ;;
    *[!0-9]* | 0*) echo "a revision is a positive integer, got '$revision'" >&2; exit 1 ;;
esac

version="$upstream${revision:+-$revision}"
release_tag="$tag${revision:+-$revision}"

# The scheduled run passes no revision, so it compares the upstream part of
# the deployed version. Comparing the whole of it would rebuild 1.9.5 over a
# deployed 1.9.5-1 every week.
if [ -z "$revision" ] && [ -n "$deployed" ] && [ "$upstream" = "${deployed%-*}" ] \
    && [ "$force" != true ]; then
    echo "upstream $upstream is already deployed as $deployed, skipping" >&2
    skip=true
elif [ "$version" = "$deployed" ] && [ "$force" != true ]; then
    echo "version $version is already deployed, skipping" >&2
    skip=true
elif [ -n "$deployed" ] && dpkg --compare-versions "$version" lt "$deployed"; then
    echo "$version sorts below the deployed $deployed, so apt would never install it" >&2
    exit 1
else
    echo "building $version (deployed: ${deployed:-none})" >&2
    skip=false
fi

printf 'version=%s\nrelease_tag=%s\nskip=%s\n' "$version" "$release_tag" "$skip"
