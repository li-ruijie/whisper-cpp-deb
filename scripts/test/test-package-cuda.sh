#!/usr/bin/env bash
# Verify package-cuda.sh produces a correct whisper-cpp-cuda package.
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

# No CUDA toolkit exists locally, so a stub stands in for the compiled backend.
# That is sufficient: this script only assembles a package and never inspects
# the library. Symbol resolution is the smoke test's concern.
printf 'not a real library' > "$work/libggml-cuda.so"

deb=$("$here/../package-cuda.sh" "$work/libggml-cuda.so" "$version" 13-3 "$work")

assert_equals "prints the path it wrote" "$deb" "$work/whisper-cpp-cuda_${version}_amd64.deb"
[ -f "$deb" ] || { echo "FAIL  package-cuda.sh produced no .deb at $deb"; exit 1; }

control=$(dpkg-deb -f "$deb")
contents=$(dpkg-deb -c "$deb")

assert_contains "package name"  "$control" "Package: whisper-cpp-cuda"
assert_contains "version"       "$control" "Version: 1.9.2"
assert_contains "architecture"  "$control" "Architecture: amd64"
assert_contains "maintainer"    "$control" \
    "Maintainer: li-ruijie <1547237+li-ruijie@users.noreply.github.com>"
assert_contains "versioned dependency on the base package" \
    "$control" "whisper-cpp (= 1.9.2)"
assert_contains "cudart pinned" "$control" "cuda-cudart-13-3"
assert_contains "cublas pinned" "$control" "libcublas-13-3"
assert_contains "backend lands beside the base payload" \
    "$contents" "./usr/lib/whisper.cpp/libggml-cuda.so"
assert_contains "root ownership" "$contents" "root/root"

depends=$(printf '%s\n' "$control" | grep '^Depends:' || true)

# The bare cuda metapackage depends on nvidia-open, which would pull a competing
# driver onto a machine using a distribution-packaged one. It must never appear.
assert_equals "Depends never names the bare cuda metapackage" \
    "$(printf '%s\n' "$depends" | grep -c '[ ,]cuda[ ,]' || true)" "0"

# Nor any of NVIDIA's version-suffixed metapackages, the cheapest of which is
# 13 packages and 1.2 GB to satisfy a backend that links two of them.
assert_equals "Depends names no metapackage" \
    "$(printf '%s\n' "$depends" | grep -c 'cuda-libraries\|cuda-runtime\|cuda-toolkit' || true)" "0"

# The driver is deliberately undeclared: its package name varies by distribution
# and the GPU is unusable without one regardless.
assert_equals "Depends does not name a driver package" \
    "$(printf '%s\n' "$depends" | grep -ci 'nvidia-driver\|nvidia-open' || true)" "0"

# It must ship exactly one file, otherwise it is duplicating the base package.
assert_equals "ships exactly one regular file" \
    "$(printf '%s\n' "$contents" | grep -c '^-' || true)" "1"

# The suffix must be threaded through rather than hardcoded. A stale suffix
# would fail silently on a container bump, so build a second package with a
# different one and confirm the control file changed with it.
deb2=$("$here/../package-cuda.sh" "$work/libggml-cuda.so" "$version" 14-0 "$work/alt")
control2=$(dpkg-deb -f "$deb2")
assert_contains "suffix is threaded into cudart" "$control2" "cuda-cudart-14-0"
assert_contains "suffix is threaded into cublas" "$control2" "libcublas-14-0"
assert_equals "the old suffix is gone from the second package" \
    "$(printf '%s\n' "$control2" | grep -c '13-3' || true)" "0"

# A malformed suffix must be refused rather than producing a broken dependency
# that only fails on a user's machine at install time.
for bad in "13.3" "13" "" "abc"; do
    status=0
    "$here/../package-cuda.sh" "$work/libggml-cuda.so" "$version" "$bad" "$work" \
        >/dev/null 2>&1 || status=$?
    assert_equals "a malformed suffix '$bad' is refused" "$status" "2"
done

exit "$fail"
