#!/usr/bin/env bash
# Verify check-backend-deps.sh accepts the declared CUDA set and rejects the rest.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
fail=0

report() {  # report <label> <expected-status> <actual-status>
    if [ "$2" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s (expected exit %s, got %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

check() {  # check <label> <expected-status> <soname-list>
    local status=0
    printf '%s\n' "$3" | "$here/../check-backend-deps.sh" - >/dev/null 2>&1 || status=$?
    report "$1" "$2" "$status"
}

# The declared set, exactly what the real backend links.
check "the declared set passes" 0 \
'libcudart.so.13
libcublas.so.13
libcublasLt.so.13
libcuda.so.1
libggml-base.so.0
libstdc++.so.6
libc.so.6'

# NCCL is the specific fault this guard exists for. It was linked once in
# llama-cpp-cuda because the container ships it and CMake found it, and every
# job stayed green while target machines silently fell back to CPU.
check "NCCL is rejected"      1 "libnccl.so.2"
check "cuFFT is rejected"     1 "libcufft.so.12"
check "cuSOLVER is rejected"  1 "libcusolver.so.12"
check "nvrtc is rejected"     1 "libnvrtc.so.13"
check "cuDNN is rejected"     1 "libcudnn.so.9"

# Non-CUDA libraries are out of scope and must not trip it.
check "ordinary libraries are ignored" 0 \
'libggml-base.so.0
libgomp.so.1
libm.so.6'

# An empty input is not a failure: a backend linking no CUDA library at all is
# odd but not a policy violation, and the guard has nothing to complain about.
check "an empty soname list passes" 0 ''

# A rejection must name the offending library, otherwise the build log leaves
# the next person guessing which one tripped it.
out=$(printf 'libnccl.so.2\n' | "$here/../check-backend-deps.sh" - 2>&1 || true)
if printf '%s\n' "$out" | grep -qF 'libnccl.so.2'; then
    printf 'ok    the rejection names the offending library\n'
else
    printf 'FAIL  the rejection names the offending library\n'
    fail=1
fi

# Argument validation.
status=0; "$here/../check-backend-deps.sh" >/dev/null 2>&1 || status=$?
report "no argument exits 2" 2 "$status"

exit "$fail"
