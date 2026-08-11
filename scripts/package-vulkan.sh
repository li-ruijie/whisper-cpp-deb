#!/usr/bin/env bash
# Assemble whisper-cpp-vulkan_<version>_amd64.deb from a compiled libggml-vulkan.so.
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <libggml-vulkan.so> <version> <outdir>" >&2
    exit 2
fi

backend=$1
version=$2
outdir=$3

# Validated for shape, matching package-cuda.sh. A version that is quietly
# wrong produces a package whose dependency on whisper-cpp can never be met.
case "$version" in
    [0-9]*) ;;
    *) echo "$0: version must begin with a digit, got '$version'" >&2; exit 2 ;;
esac

[ -f "$backend" ] || { echo "$0: no such file: $backend" >&2; exit 2; }

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

root="$staging/root"
mkdir -p "$root/DEBIAN" "$root/usr/lib/whisper.cpp" "$outdir"

# dpkg-deb rejects a control directory outside 0755 to 0775.
chmod 0755 "$root/DEBIAN"

install -m 644 "$backend" "$root/usr/lib/whisper.cpp/libggml-vulkan.so"

cat > "$root/DEBIAN/control" <<EOF
Package: whisper-cpp-vulkan
Version: ${version}
Architecture: amd64
Maintainer: li-ruijie <1547237+li-ruijie@users.noreply.github.com>
Homepage: https://github.com/ggml-org/whisper.cpp
Depends: whisper-cpp (= ${version}), libvulkan1, libc6 (>= 2.34), libgcc-s1, libstdc++6 (>= 12)
Section: misc
Priority: optional
Description: whisper.cpp, Vulkan backend
 Vulkan compute backend for whisper-cpp, giving GPU acceleration on AMD, Intel,
 and NVIDIA hardware without requiring CUDA.
 .
 libvulkan1 is the loader and is depended on. The driver-specific ICD is not,
 since it comes from mesa-vulkan-drivers on AMD and Intel and from the
 proprietary driver on NVIDIA, so no single package name is correct. Where no
 ICD is installed, Vulkan enumerates no device and whisper-cpp runs on CPU.
 .
 This package may be installed alongside whisper-cpp-cuda. When both are
 present ggml registers CUDA first and whisper selects it, so Vulkan is loaded
 but unused. Pass --gpu-device to choose another device.
EOF

deb="$outdir/whisper-cpp-vulkan_${version}_amd64.deb"
dpkg-deb --root-owner-group --build "$root" "$deb" >/dev/null
echo "$deb"
