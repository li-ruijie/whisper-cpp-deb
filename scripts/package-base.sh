#!/usr/bin/env bash
# Assemble whisper-cpp_<version>_<arch>.deb from an upstream whisper.cpp Ubuntu archive.
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <tarball> <version> <arch> <outdir>" >&2
    exit 2
fi

tarball=$1
version=$2
arch=$3
outdir=$4

here=$(cd "$(dirname "$0")" && pwd)

# Reached through /usr/bin. Everything else in the archive stays inside
# /usr/lib/whisper.cpp: main and bench are deprecation stubs built from
# examples/deprecation-warning, and the test-* binaries need fixture data that
# is not packaged. Both archives ship the same 16 executables, measured on
# 2026-08-11 against v1.9.2 for x64 and arm64.
tools="whisper-cli whisper-server whisper-bench whisper-quantize
whisper-vad-speech-segments parakeet-cli parakeet-quantize"
known_other="main bench"

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

root="$staging/root"
libdir="$root/usr/lib/whisper.cpp"
mkdir -p "$root/DEBIAN" "$libdir" "$root/usr/bin"

# dpkg-deb rejects a control directory outside 0755 to 0775, and a restrictive
# umask on the build host would otherwise produce one.
chmod 0755 "$root/DEBIAN"

# The archive holds every file under a single whisper-bin-ubuntu-<arch>/ directory.
tar xzf "$tarball" -C "$libdir" --strip-components=1

install -Dm644 "$libdir/LICENSE" "$root/usr/share/doc/whisper-cpp/copyright"
rm -f "$libdir/LICENSE"

# Fail on a binary this script has never seen. Upstream renaming or adding a
# tool would otherwise drop it from /usr/bin with no signal at all.
for path in "$libdir"/*; do
    [ -f "$path" ] || continue
    name=$(basename "$path")
    case "$name" in
        *.so | *.so.* | test-*) continue ;;
    esac
    case " $(echo $tools) $known_other " in
        *" $name "*) ;;
        *)
            echo "$0: unrecognised binary in the archive: $name" >&2
            echo "Add it to the tools allowlist or to known_other, then update" >&2
            echo "the symlink count in test-package-base.sh." >&2
            exit 1
            ;;
    esac
done

# Symlink the allowlist, failing if upstream dropped one of them.
for name in $tools; do
    if [ ! -f "$libdir/$name" ]; then
        echo "$0: expected tool missing from the archive: $name" >&2
        exit 1
    fi
    chmod 755 "$libdir/$name"
    ln -s "../lib/whisper.cpp/$name" "$root/usr/bin/$name"
done

# The excluded binaries stay in place and stay executable.
for name in $known_other; do
    [ -f "$libdir/$name" ] && chmod 755 "$libdir/$name"
done
for path in "$libdir"/test-*; do
    [ -f "$path" ] && chmod 755 "$path"
done

# -type f leaves the soname symlinks alone, which is what we want.
find "$libdir" -name '*.so*' -type f -exec chmod 644 {} +

# The model wrapper is a real file rather than a symlink, since it is ours
# rather than upstream's.
if [ ! -f "$here/whisper-model.sh" ]; then
    echo "$0: whisper-model.sh is missing from $here" >&2
    exit 1
fi
install -Dm755 "$here/whisper-model.sh" "$root/usr/bin/whisper-model"

cat > "$root/DEBIAN/control" <<EOF
Package: whisper-cpp
Version: ${version}
Architecture: ${arch}
Maintainer: li-ruijie <1547237+li-ruijie@users.noreply.github.com>
Homepage: https://github.com/ggml-org/whisper.cpp
Depends: libc6 (>= 2.34), libgcc-s1, libgomp1, libstdc++6 (>= 12), curl, jq
Conflicts: whisper.cpp-tools
Section: misc
Priority: optional
Description: whisper.cpp, speech recognition in C/C++
 Command line tools and an HTTP server for transcribing audio with Whisper and
 Parakeet models on CPU, repackaged from the upstream release archive. Includes
 voice activity detection and model quantisation tools.
 .
 whisper-model downloads and updates the ggml model files these tools need,
 covering the whisper, parakeet, VAD, and tinydiarize model families.
 .
 Install whisper-cpp-cuda or whisper-cpp-vulkan alongside this package to add
 GPU acceleration. Both may be installed together, in which case CUDA is
 selected.
EOF

deb="$outdir/whisper-cpp_${version}_${arch}.deb"
dpkg-deb --root-owner-group --build "$root" "$deb" >/dev/null
echo "$deb"
