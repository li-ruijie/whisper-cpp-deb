#!/usr/bin/env bash
# Fail if the compiled backend links a CUDA library the package does not declare.
#
# whisper-cpp-cuda pins the exact runtime packages it needs rather than pulling
# NVIDIA's cuda-libraries metapackage, which would add about 1.2 GB of unused
# libraries. That pin is only correct while the backend links nothing else, and
# nothing else would notice a change: the build container has every CUDA library
# present, so a newly linked one resolves there and the smoke test stays green.
# It would surface only on a user's machine, as a backend that fails to dlopen
# and a silent fall back to CPU. That is the failure NCCL already caused once in
# the sibling llama-cpp-deb repository.
#
# Takes a path to the shared object, or "-" to read sonames from stdin.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <libggml-cuda.so | ->" >&2
    exit 2
fi

if [ "$1" = "-" ]; then
    needed=$(cat)
else
    needed=$(readelf -d "$1" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p')
fi

# Declared in package-cuda.sh as cuda-cudart-<suffix> and libcublas-<suffix>.
# libcublasLt ships inside libcublas, so it needs no separate package.
# libcuda is the driver, deliberately undeclared: its package name varies by
# distribution and the GPU is unusable without one regardless.
declared='libcudart\.so|libcublas\.so|libcublasLt\.so|libcuda\.so'

# Only CUDA and NVIDIA sonames are in scope. Everything else is either the base
# package or the C and C++ runtimes, which whisper-cpp already depends on.
cuda_needed=$(printf '%s\n' "$needed" | grep -E '^(libcu|libnv|libnccl)' || true)
unexpected=$(printf '%s\n' "$cuda_needed" | grep -vE "^($declared)" || true)

if [ -n "$unexpected" ]; then
    echo "$0: the backend links CUDA libraries the package does not declare:" >&2
    printf '%s\n' "$unexpected" | sed 's/^/  /' >&2
    echo >&2
    echo "Add the matching package to Depends in package-cuda.sh, then add the" >&2
    echo "soname to the declared list here. Shipping as-is would fail silently" >&2
    echo "on any machine that lacks the library." >&2
    exit 1
fi

echo "CUDA libraries linked, all declared:"
printf '%s\n' "$cuda_needed" | sed 's/^/  /'
