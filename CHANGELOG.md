# Changelog

┌────────────┬────────────────────────────────────────────────────────────────────────────────────┐
│ Date       │ Summary                                                                            │
├────────────┼────────────────────────────────────────────────────────────────────────────────────┤
│ 2026-08-11 │ Acted on a whole-branch review. The test suites now run in CI, 186 assertions      │
│            │ across seven of them, where they had been local-only and run by hand, which is     │
│            │ why a missing mkdir in package-base.sh reached CI at all. Two things believed to   │
│            │ work did not. Resume never survived a network failure, since the download-failure  │
│            │ path deleted the one partial worth keeping, and the Vulkan job never exercised     │
│            │ Vulkan, which an added EXPECT_BACKEND assertion proved on its first run. The       │
│            │ latter is a capability gap rather than a fault: ggml gates on                      │
│            │ storageBuffer16BitAccess, which this llvmpipe lacks, so the assertion was removed  │
│            │ and the spec corrected. Also fixed a batch download aborting at the first failure, │
│            │ fetch ignoring head_meta's return, an unsatisfiable Range from an oversized        │
│            │ partial, the sidecar written after rather than before the rename, a Vulkan         │
│            │ linkage guard that did not exist, a smoke test that passed on a package shipping   │
│            │ no backend, an EXIT trap that leaked stub servers into the next run, and the base  │
│            │ package being built three times                                                    │
│ 2026-08-11 │ First release, v1.9.2. whisper-cpp for amd64 and arm64 repackages the upstream     │
│            │ archive, whisper-cpp-cuda and whisper-cpp-vulkan carry compiled backends for       │
│            │ amd64, and all four reach li-ruijie/apt over repository_dispatch. Measured at      │
│            │ 2.6, 1.6, 54.3, and 7.0 MB against estimates of 10, 5, 52, and 18                  │
│ 2026-08-11 │ Added whisper-audio, an ffmpeg wrapper producing the 16 kHz mono PCM signed        │
│            │ 16-bit WAV whisper.cpp uses internally. whisper-cli reads only flac, mp3, ogg,     │
│            │ and wav, and the release build links no libavformat, so m4a, opus, and every       │
│            │ video container need converting first. ffmpeg is a Recommends, not a Depends       │
│ 2026-08-11 │ Added whisper-model, which fetches its model list from Hugging Face at run time    │
│            │ across four repositories rather than carrying one that goes stale, verifies every  │
│            │ download against the SHA-256 the hub returns, and updates for one request per      │
│            │ model and no payload. It refuses to install what the hub gives it no way to check  │
│ 2026-08-11 │ Initial scaffold                                                                   │
└────────────┴────────────────────────────────────────────────────────────────────────────────────┘
