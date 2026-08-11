# whisper.cpp Debian packages

Builds `whisper-cpp`, `whisper-cpp-cuda`, and `whisper-cpp-vulkan` for the APT repository at
https://li-ruijie.github.io/apt/. Upstream publishes Linux CPU binaries only, so both GPU
backends are compiled here.

## Packages

┌────────────────────┬───────────────┬────────────────────────────────────────────────────┐
│ Package            │ Architectures │ Contents                                           │
├────────────────────┼───────────────┼────────────────────────────────────────────────────┤
│ whisper-cpp        │ amd64, arm64  │ repackaged upstream archive, CPU backends, and the │
│                    │               │ whisper-model wrapper                              │
│ whisper-cpp-cuda   │ amd64         │ libggml-cuda.so for NVIDIA acceleration            │
│ whisper-cpp-vulkan │ amd64         │ libggml-vulkan.so for AMD, Intel, and NVIDIA       │
└────────────────────┴───────────────┴────────────────────────────────────────────────────┘

Everything installs under `/usr/lib/whisper.cpp/`, with tools reached through symlinks in
`/usr/bin`. The two backend packages may be installed together. When both are present CUDA
is selected, since ggml registers it first, and `--gpu-device N` picks another.

## Models

`whisper-model` downloads and updates the ggml model files the tools need. It covers four
model families, and fetches the model list from Hugging Face at run time rather than
carrying a list that goes stale.

```sh
whisper-model list
whisper-model download base.en
whisper-model update
whisper-cli -m "$(whisper-model path base.en)" -f audio.wav
```

Models are stored under `$XDG_DATA_HOME/whisper.cpp/models`, overridable with
`WHISPER_MODEL_DIR`. Set that system-wide to share one read-only model store across users.

## GPU requirements

`whisper-cpp-cuda` needs `cuda-cudart-13-3` and `libcublas-13-3` from NVIDIA's own CUDA apt
repository, which must be configured on the target. Debian's `nvidia-cuda-toolkit` is 12.4
and is both too old for compute capability 12.0 and the wrong soname for a CUDA 13 build. A
580 series or newer driver is required.

`whisper-cpp-vulkan` needs `libvulkan1`, which it depends on, plus an ICD, which it does not.
The ICD comes from `mesa-vulkan-drivers` on AMD and Intel and from the proprietary driver on
NVIDIA, so no single package name is correct.

Where either is missing, ggml skips the backend and whisper runs on CPU.

## Building

The workflow runs weekly and can be dispatched manually with a `version` override and a
`force` flag. The scripts run standalone:

```sh
scripts/package-base.sh   <tarball> <version> <arch> <outdir>
scripts/package-cuda.sh   <libggml-cuda.so> <version> <cuda-suffix> <outdir>
scripts/package-vulkan.sh <libggml-vulkan.so> <version> <outdir>
scripts/smoke-test.sh     <base.deb> [backend.deb]
```

Upstream whisper.cpp is MIT licensed. Its `LICENSE` ships in the base package at
`/usr/share/doc/whisper-cpp/copyright`.
