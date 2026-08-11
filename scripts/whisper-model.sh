#!/usr/bin/env bash
# Download, update, verify, and remove ggml model files for whisper.cpp.
#
# Upstream's models/download-ggml-model.sh cannot update an installed model,
# verifies nothing, writes into $PWD when it lives in a bin directory, and
# carries a model list that goes stale. This replaces it.
#
# The model list is fetched from the Hugging Face API on every call, so a model
# added upstream needs no change here. Only the four source repositories are
# hardcoded, since each has its own consuming binary in this package.
set -euo pipefail

self=${0##*/}
HF=${WHISPER_HF_ENDPOINT:-https://huggingface.co}

# family:repository. parakeet is a separate architecture rather than a whisper
# model, read by parakeet-cli, and the vad family feeds whisper-cli --vad and
# whisper-vad-speech-segments.
SOURCES='whisper:ggerganov/whisper.cpp
parakeet:ggml-org/parakeet-GGUF
vad:ggml-org/whisper-vad
tdrz:akashmjn/tinydiarize-whisper.cpp'

die() { printf '%s: %s\n' "$self" "$1" >&2; exit "${2:-1}"; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but is not installed"
}

model_dir() {
    printf '%s' "${WHISPER_MODEL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/whisper.cpp/models}"
}

auth=()
if [ -n "${HF_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer $HF_TOKEN")
fi

# Every model the hub currently serves, as "<family> <id> <url>" lines. A
# here-document rather than a pipeline keeps the per-repository success count
# below out of a subshell, so it survives past the loop. A repository that
# fails to answer, whether dormant, renamed, or offline, is warned about on
# stderr and skipped rather than aborting the whole call. Only failure across
# every repository is treated as fatal.
hub_index() {
    need curl
    need jq
    local family repo ok=0
    while IFS=: read -r family repo; do
        [ -n "$family" ] || continue
        if curl -fsSL "${auth[@]}" "$HF/api/models/$repo" \
            | jq -r --arg fam "$family" --arg base "$HF/$repo/resolve/main" '
                .siblings[].rfilename
                | select(test("^ggml-.*\\.bin$"))
                | . as $file
                | "\($fam) \($file | sub("^ggml-";"") | sub("\\.bin$";"")) \($base)/\($file)"
              '
        then
            ok=$((ok + 1))
        else
            printf 'warning: could not read the model list for %s, skipping\n' "$repo" >&2
        fi
    done <<EOF
$SOURCES
EOF
    [ "$ok" -gt 0 ] || die "could not reach any of the model repositories"
}

resolve_url() {  # resolve_url <id>
    local id=$1 hits
    hits=$(hub_index | awk -v want="$id" '$2 == want {print $3}')
    [ -n "$hits" ] || die "unknown model: $id (try '$self list')"
    if [ "$(printf '%s\n' "$hits" | wc -l)" -ne 1 ]; then
        die "ambiguous model id '$id', served by more than one repository"
    fi
    printf '%s' "$hits"
}

installed_ids() {
    local dir f name
    dir=$(model_dir)
    [ -d "$dir" ] || return 0
    for f in "$dir"/ggml-*.bin; do
        [ -f "$f" ] || continue
        name=${f##*/}
        name=${name#ggml-}
        name=${name%.bin}
        printf '%s\n' "$name"
    done | sort
}

# Prints "<sha256> <size>". Either field may be empty if the hub stops sending
# the header, which the callers degrade on rather than fail.
head_meta() {  # head_meta <url>
    local hdrs sha size
    hdrs=$(curl -fsSIL "${auth[@]}" "$1") || {
        printf '%s: %s\n' "$self" "could not reach $1" >&2
        return 1
    }
    hdrs=$(printf '%s\n' "$hdrs" | tr -d '\r')
    sha=$(printf '%s\n' "$hdrs" \
        | sed -n 's/^[Xx]-[Ll]inked-[Ee][Tt][Aa][Gg]: *"\(.*\)"$/\1/p' | head -1)
    size=$(printf '%s\n' "$hdrs" \
        | sed -n 's/^[Xx]-[Ll]inked-[Ss]ize: *\([0-9][0-9]*\)$/\1/p' | head -1)
    printf '%s %s' "$sha" "$size"
}

local_sha() {  # local_sha <file>
    sha256sum "$1" | cut -d' ' -f1
}

sidecar_field() {  # sidecar_field <sidecar> <key>
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | head -1
}

# Its three failure paths (download, checksum mismatch, size mismatch) report
# with a plain return 1 rather than die, since die calls exit, which would
# terminate the whole shell from inside this function regardless of any ||
# guard on the caller. cmd_update relies on that to keep going past one
# model's failure and reach the rest of a bare update.
fetch() {  # fetch <id> <url>
    local id=$1 url=$2 dir file part meta sha size actual resume=()
    dir=$(model_dir)
    mkdir -p "$dir"
    file="$dir/ggml-$id.bin"
    part="$file.part"

    meta=$(head_meta "$url")
    sha=${meta%% *}
    size=${meta##* }

    if [ -f "$part" ] && [ -n "$size" ] && [ "$(stat -c%s "$part")" = "$size" ]; then
        printf '%s: a complete partial file is already present, verifying\n' "$id"
    else
        [ -s "$part" ] && resume=(-C -)
        printf 'downloading %s (%s bytes)\n' "$id" "${size:-size unknown}"
        curl -fL "${auth[@]}" "${resume[@]}" \
            --retry 5 --retry-delay 5 --retry-all-errors --retry-connrefused \
            -o "$part" "$url" \
            || { rm -f "$part"; printf '%s: %s\n' "$self" "download failed for $id" >&2; return 1; }
    fi

    actual=$(local_sha "$part")

    if [ -n "$sha" ]; then
        if [ "$actual" != "$sha" ]; then
            rm -f "$part"
            printf '%s: %s\n' "$self" "checksum mismatch for $id (expected $sha, got $actual)" >&2
            return 1
        fi
    elif [ -n "$size" ]; then
        # The hub sent no checksum but did send a length, so this is the one
        # case where a weaker check is acceptable rather than an outright
        # refusal. The warning only fires here, where a check actually runs.
        printf 'warning: the hub sent no X-Linked-ETag for %s, checking size only\n' "$id" >&2
        if [ "$(stat -c%s "$part")" != "$size" ]; then
            rm -f "$part"
            printf '%s: %s\n' "$self" "size mismatch for $id" >&2
            return 1
        fi
    else
        # Neither header came back, so nothing verifies this download at all.
        # Installing it anyway would record a sidecar hash computed from the
        # file itself, which a later verify would then always agree with.
        # Refuse instead of accepting an unverifiable file.
        rm -f "$part"
        printf '%s: %s\n' "$self" \
            "no verification possible for $id (the hub sent neither X-Linked-ETag nor X-Linked-Size)" >&2
        return 1
    fi

    mv -f "$part" "$file"
    printf 'sha256=%s\nurl=%s\n' "$actual" "$url" > "$file.sha256"
    printf 'installed %s\n' "$file"
}

cmd_list() {
    local dir installed line family id
    dir=$(model_dir)
    installed=$(installed_ids || true)

    printf 'Model directory: %s\n\n' "$dir"

    if ! index=$(hub_index 2>/dev/null); then
        printf 'The hub is unreachable, so only installed models are listed.\n\n'
        printf '%s\n' "$installed" | sed 's/^/  installed  /'
        return 0
    fi

    printf '%s\n' "$index" | sort -k1,1 -k2,2 | while read -r family id _; do
        if printf '%s\n' "$installed" | grep -qx -- "$id"; then
            printf '  %-9s %-34s installed\n' "$family" "$id"
        else
            printf '  %-9s %-34s\n' "$family" "$id"
        fi
    done
}

cmd_download() {
    [ "$#" -ge 1 ] || die "usage: $self download <model>..." 2
    local id url
    for id in "$@"; do
        url=$(resolve_url "$id")
        fetch "$id" "$url"
    done
}

cmd_update() {
    local ids id dir file side url want want_size have status=0
    dir=$(model_dir)
    if [ "$#" -ge 1 ]; then
        ids=$(printf '%s\n' "$@")
    else
        ids=$(installed_ids || true)
        [ -n "$ids" ] || { printf 'no models are installed\n'; return 0; }
    fi

    for id in $ids; do
        file="$dir/ggml-$id.bin"
        side="$file.sha256"
        if [ ! -f "$file" ]; then
            printf '%s: not installed, skipping\n' "$id" >&2
            status=1
            continue
        fi

        url=$(sidecar_field "$side" url)
        [ -n "$url" ] || url=$(resolve_url "$id")
        have=$(sidecar_field "$side" sha256)
        [ -n "$have" ] || have=$(local_sha "$file")

        want=$(head_meta "$url") || {
            printf '%s: could not reach the hub, skipping\n' "$id" >&2
            status=1
            continue
        }
        want_size=${want##* }
        want=${want%% *}

        if [ -n "$want" ] && [ "$want" = "$have" ]; then
            printf '%s: up to date\n' "$id"
            # Rewrite a sidecar that was missing, so the next check is cheap.
            [ -f "$side" ] || printf 'sha256=%s\nurl=%s\n' "$have" "$url" > "$side"
        elif [ -n "$want" ]; then
            printf '%s: updating\n' "$id"
            fetch "$id" "$url" || { status=1; continue; }
        elif [ -n "$want_size" ] && [ "$want_size" = "$(stat -c%s "$file")" ]; then
            # The hub stopped sending the checksum header. Fall back to the size
            # rather than refetching, since a needless refetch of large-v3 is
            # 3.1 GB. A weaker check beats an expensive one that is always wrong.
            printf '%s: up to date (size only, the hub sent no X-Linked-ETag)\n' "$id" >&2
        else
            printf 'warning: no X-Linked-ETag for %s and the size differs, refetching\n' "$id" >&2
            fetch "$id" "$url" || { status=1; continue; }
        fi
    done
    return "$status"
}

cmd_remove() {
    [ "$#" -ge 1 ] || die "usage: $self remove <model>..." 2
    local dir id file
    dir=$(model_dir)
    for id in "$@"; do
        file="$dir/ggml-$id.bin"
        [ -f "$file" ] || { printf '%s: not installed\n' "$id" >&2; continue; }
        rm -f "$file" "$file.sha256" "$file.part"
        printf 'removed %s\n' "$id"
    done
}

cmd_path() {
    [ "$#" -eq 1 ] || die "usage: $self path <model>" 2
    local file
    file="$(model_dir)/ggml-$1.bin"
    [ -f "$file" ] || die "$1 is not installed (try '$self download $1')"
    printf '%s\n' "$file"
}

cmd_verify() {
    local ids id dir file want have status=0
    dir=$(model_dir)
    if [ "$#" -ge 1 ]; then
        ids=$(printf '%s\n' "$@")
    else
        ids=$(installed_ids || true)
        [ -n "$ids" ] || { printf 'no models are installed\n'; return 0; }
    fi

    for id in $ids; do
        file="$dir/ggml-$id.bin"
        if [ ! -f "$file" ]; then
            printf '%s: not installed\n' "$id" >&2
            status=1
            continue
        fi
        want=$(sidecar_field "$file.sha256" sha256)
        if [ -z "$want" ]; then
            printf '%s: no sidecar to check against\n' "$id" >&2
            status=1
            continue
        fi
        have=$(local_sha "$file")
        if [ "$want" = "$have" ]; then
            printf '%s: ok\n' "$id"
        else
            printf '%s: CORRUPT (expected %s, got %s)\n' "$id" "$want" "$have" >&2
            status=1
        fi
    done
    return "$status"
}

usage() {
    cat <<USAGE
usage: $self <command> [arguments]

  list                    every model the hub serves, marking those installed
  download <model>...     fetch, resume, verify, and record the checksum
  update [<model>...]     refetch models whose remote checksum has changed,
                          covering every installed model when given no argument
  remove <model>...       delete the model and its checksum sidecar
  path <model>            print the absolute path, for command substitution
  verify [<model>...]     recheck installed models against their sidecars

Models are stored in $(model_dir).
Set WHISPER_MODEL_DIR to override, or HF_TOKEN for authenticated downloads.

  whisper-cli -m "\$($self path base.en)" -f audio.wav
USAGE
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }

command=$1
shift
case "$command" in
    list)     cmd_list "$@" ;;
    download) cmd_download "$@" ;;
    update)   cmd_update "$@" ;;
    remove)   cmd_remove "$@" ;;
    path)     cmd_path "$@" ;;
    verify)   cmd_verify "$@" ;;
    -h | --help | help) usage ;;
    *)        printf '%s: unknown command: %s\n\n' "$self" "$command" >&2; usage >&2; exit 2 ;;
esac
