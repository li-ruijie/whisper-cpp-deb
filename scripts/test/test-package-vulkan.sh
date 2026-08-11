#!/usr/bin/env bash
# Verify package-vulkan.sh produces a correct whisper-cpp-vulkan package.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

version=1.9.2
fail=0

assert_contains() {  # assert_contains <label> <haystack> <needle>
    if printf '%s\n' "$2" | grep -qF -- "$3"; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n       expected to find: %s\n' "$1" "$3"
        fail=1
    fi
}

# Counts need equality, since a substring test would pass "1" against "10".
assert_equals() {  # assert_equals <label> <actual> <expected>
    if [ "$2" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s (expected %s, got %s)\n' "$1" "$3" "$2"
        fail=1
    fi
}

# A stub standing in for the compiled backend. This script only assembles a
# package and never inspects the library, so a stub is sufficient. Symbol
# resolution is the smoke test's concern.
printf 'not a real library' > "$work/libggml-vulkan.so"

# Capture stdout. The script's documented contract is that it prints the path
# it wrote, so asserting it here verifies that contract and keeps the stray
# path line out of the test output.
deb=$("$here/../package-vulkan.sh" "$work/libggml-vulkan.so" "$version" "$work")

assert_equals "prints the path it wrote" "$deb" "$work/whisper-cpp-vulkan_${version}_amd64.deb"
[ -f "$deb" ] || { echo "FAIL  package-vulkan.sh produced no .deb at $deb"; exit 1; }

control=$(dpkg-deb -f "$deb")
contents=$(dpkg-deb -c "$deb")

assert_contains "package name"  "$control" "Package: whisper-cpp-vulkan"
assert_contains "version"       "$control" "Version: 1.9.2"
assert_contains "architecture"  "$control" "Architecture: amd64"
assert_contains "maintainer"    "$control" \
    "Maintainer: li-ruijie <1547237+li-ruijie@users.noreply.github.com>"
assert_contains "versioned dependency on the base package" \
    "$control" "whisper-cpp (= 1.9.2)"
assert_contains "vulkan loader dependency" "$control" "libvulkan1"
assert_contains "backend lands beside the base payload" \
    "$contents" "./usr/lib/whisper.cpp/libggml-vulkan.so"
assert_contains "root ownership" "$contents" "root/root"

# The ICD is deliberately undeclared, on the same reasoning that leaves the
# NVIDIA driver undeclared for CUDA: its package name varies by vendor, so no
# single name is correct and depending on one would break the others.
depends=$(printf '%s\n' "$control" | grep '^Depends:' || true)
for forbidden in mesa-vulkan-drivers nvidia vulkan-sdk; do
    assert_equals "Depends names no $forbidden" \
        "$(printf '%s\n' "$depends" | grep -ci -- "$forbidden" || true)" "0"
done

# It must ship exactly one file, otherwise it is duplicating the base package.
assert_equals "ships exactly one regular file" \
    "$(printf '%s\n' "$contents" | grep -c '^-' || true)" "1"

# The version must be threaded through rather than hardcoded, since a stale
# pin against the base package would fail only at install time on a user's
# machine. Build a second package at a different version and confirm both the
# filename and the dependency moved with it.
deb2=$("$here/../package-vulkan.sh" "$work/libggml-vulkan.so" "9.9.9" "$work/alt")
assert_equals "version is threaded into the filename" \
    "$deb2" "$work/alt/whisper-cpp-vulkan_9.9.9_amd64.deb"
assert_contains "version is threaded into the dependency" \
    "$(dpkg-deb -f "$deb2")" "whisper-cpp (= 9.9.9)"

# Argument validation.
status=0; "$here/../package-vulkan.sh" "$work/libggml-vulkan.so" "$version" >/dev/null 2>&1 \
    || status=$?
assert_equals "too few arguments exits 2" "$status" "2"

exit "$fail"
