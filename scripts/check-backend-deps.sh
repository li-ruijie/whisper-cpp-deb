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
# Takes a path to the shared object, or "-" to read sonames from stdin, plus the
# backend kind. Vulkan needs the same guard for the same reason: the LunarG SDK
# is installed on that build runner, so a backend that picked up a shaderc or
# SPIRV-Tools link resolves there and during ldd -r in the smoke test, then
# fails to dlopen on a user's machine and falls back to CPU without saying why.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: $0 <backend.so | -> [cuda|vulkan]" >&2
    exit 2
fi

kind=${2:-cuda}

case "$kind" in
    cuda)
        # Declared in package-cuda.sh as cuda-cudart-<suffix> and
        # libcublas-<suffix>. libcublasLt ships inside libcublas, so it needs no
        # separate package. libcuda is the driver, deliberately undeclared: its
        # package name varies by distribution and the GPU is unusable without
        # one regardless.
        declared='libcudart\.so|libcublas\.so|libcublasLt\.so|libcuda\.so'
        # Only CUDA and NVIDIA sonames are in scope. Everything else is the base
        # package or the C and C++ runtimes, which whisper-cpp already depends on.
        scope='^(libcu|libnv|libnccl)'
        label='CUDA'
        ;;
    vulkan)
        # package-vulkan.sh declares libvulkan1 and nothing else. The shader
        # toolchain is a build-time dependency whose output is embedded in the
        # backend, so any runtime link to it is a packaging fault.
        declared='libvulkan\.so'
        scope='^(libvulkan|libshaderc|libSPIRV|libspirv|libglslang|libVk|libMoltenVK)'
        label='Vulkan'
        ;;
    *)
        echo "$0: unknown backend kind '$kind', expected cuda or vulkan" >&2
        exit 2
        ;;
esac

if [ "$1" = "-" ]; then
    needed=$(cat)
else
    needed=$(readelf -d "$1" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p')
fi

in_scope=$(printf '%s\n' "$needed" | grep -E "$scope" || true)
unexpected=$(printf '%s\n' "$in_scope" | grep -vE "^($declared)" || true)

if [ -n "$unexpected" ]; then
    echo "$0: the backend links $label libraries the package does not declare:" >&2
    printf '%s\n' "$unexpected" | sed 's/^/  /' >&2
    echo >&2
    echo "Add the matching package to Depends in package-$kind.sh, then add the" >&2
    echo "soname to the declared list here. Shipping as-is would fail silently" >&2
    echo "on any machine that lacks the library." >&2
    exit 1
fi

echo "$label libraries linked, all declared:"
printf '%s\n' "$in_scope" | sed 's/^/  /'
