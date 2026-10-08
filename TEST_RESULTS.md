# Independent final test results: PASS

Tested source commit: `ded89d16a9bc97935afa0b554badff3c33baad0a`.
Tests followed independent review approval. No production or test code changed.
Run date: 2026-10-08 UTC. These results apply to this machine, runtime, and sample.

## Environment and commands

- MacBook Pro Mac15,10; Apple M3 Max; 14 CPU cores (10 performance, 4 efficiency); 36 GB RAM.
- macOS 27.0.1 (26A434); Swift 6.4; FFmpeg and ffprobe 9.0.2.
- Battery power, 75% at start; power mode 0. No power settings changed.
- Release executable: `/Users/vkandel_1/Projects/video_audio/.build/out/Products/Release/voice-remove`.

```sh
swift test
swift build -c release
BIN="$(swift build -c release --show-bin-path)/voice-remove"
python3 Integration/run.py --binary "$BIN" -v
/usr/bin/time -l "$BIN" inputVideo.MP4 --verify
```

| Command | Result | Full command wall time |
| --- | --- | --- |
| `swift test` | 23 XCTest tests; zero failures | 2.575405 s |
| Release build | Exit 0 | 3.291573 s |
| Integration suite | 12 tests; zero failures/errors | 15.525272 s |
| Real-video benchmark | Exit 0; one output | 7.28 s (`time -l`) |

XCTest execution took 0.342 s; integration execution took 15.430 s.
The deterministic streaming test checked 168 channel/frame/latency/pass combinations.
Integration covered stereo, mono, offsets, longer audio, MOV, rotation, chapters, cover art,
metadata, folder concurrency, rejected tracks, collisions, and SIGINT/SIGTERM cleanup.

## Real-video benchmark

Output: `/Users/vkandel_1/Projects/video_audio/inputVideo_voiceremoved.MP4`.

- Settings: default two distinct AUSoundIsolation units; HQ conversation mode 0; wet/dry -100.
- Both units reported 6360 latency frames each (132.5 ms at 48 kHz).
- The pipeline reported 3,546,112 audio frames. Progress reports occurred at 30 and 60 seconds.
- Input: 607,580,126 bytes. Output: 600,384,867 bytes.
- Full elapsed time: 7.28 s; user time: 10.70 s; system time: 0.49 s.
- External monotonic wrapper time: 7.307098 s. The CLI reported 7.27 s internally.
- Speed: `73.877333 / 7.28 = 10.148x` real time; 10.110x with the external wrapper time.
- Maximum resident set size (RSS): 109,101,056 bytes (104.05 MiB), as reported by `time -l`.
- Reported peak memory footprint: 77,071,104 bytes. RSS is not an aggregate simultaneous process-tree measurement.

This measurement includes probe, model setup, audio processing, remux, validation, and `--verify`.
Verification adds reads of the input and output for video packet hashes, including cover art.
Those reads affect performance. Prior source hashing can warm filesystem caches.
No cold-cache or separate no-verification benchmark was run. One run does not establish general throughput.

## Integrity and media validation

Original SHA-256 before and after all checks:

```text
99bc7a1f67e5e1c68c82bb4d88a60ac4deb6b6d5489b70bc54e311c5713b0f67
```

Original size, inode 158907046, device 16777229, mode 0o100700,
mtime_ns 1791107787250000000, and ctime_ns 1791455965824306943 stayed identical.
Access time was not an integrity criterion.

Independent FFmpeg packet-payload SHA-256 checks matched source and output:

| Stream mapping | SHA-256 |
| --- | --- |
| Main HEVC video, 0 → 0 | `7545710c229704a41fed09d973bdf78a8efa6fe830a705450ada8626a2c033ae` |
| Attached MJPEG cover, 4 → 2 | `dc76a481d6e5935ee31c4bcea32496491f57eed7c0f2a9ebf77311352f76962e` |

Main video retained 3840×2160, 50 fps, 3689 frames, start 0, and duration 73.780000 s.
Cover art retained 640×360 dimensions and the attached-picture disposition.
User file and retained-stream metadata, language, dispositions, and side data matched.
Creation time remained `2026-10-04T09:55:11.000000Z`; this sample has no chapters or rotation side data.
Synthetic integration fixtures verified chapters and rotation separately. The container encoder tag changed as permitted.

Both audio streams are AAC LC, 48 kHz, stereo, start 0.000000, duration 73.877333 s.
Full source and output audio decodes passed with `-xerror -err_detect explode`.
Bounded pipe counts measured exactly 3,546,112 stereo frames for each decode.
The output retained audio beyond the video's end. Re-encoding changed AAC packet count from 3463 to 3464.
Reported audio bitrate changed from 317,375 to 225,691 bit/s; the requested encoder target was 320 kb/s.

Main-video decode coverage on both files:

| Window | Time range | Decoded frames per file |
| --- | --- | --- |
| Head | 0–2 s | 100 |
| Middle | 35.89–37.89 s | 99 |
| Tail | 71.78–73.78 s | 100 |

All six window commands exited 0 with strict decode error flags. Both cover pictures decoded successfully.
The complete video received payload hash verification, not full video decode coverage.

Data streams 2 (`djmd`) and 3 (`dbgi`) were explicitly dropped with warnings; neither appears in the output.
FFmpeg also reported a missing stream timescale, a guessed stereo layout, and duplicate codec options.
These diagnostics did not prevent successful processing, independent validation, or decoding.

## Evidence, cleanup, and limitations

Ignored local evidence resides in `.build/test-results/final/`; prior failure evidence remains unchanged.
Key files: `swift-test.log`, `release-build.log`, `integration.log`, `benchmark.stdout`, `benchmark.stderr`,
`*-result.json`, `original-before.json`, `original-after.json`, `sample-validation-summary.json`,
`sample-validation-commands.json`, `audio-decoded-frames.json`, and `cleanup-check.json`.
Probe JSON, decode logs, and environment records are also local. Raw environment records contain system identifiers.

Five-second source/output WAV clips at 0, 35, and 68 seconds are available as
`source-{head,middle,tail}.wav` and `output-{head,middle,tail}.wav` in the evidence folder.
**Human listening was not done.** Speech suppression and unwanted sound changes remain unassessed.
No audible-quality or speech-attenuation claim follows from these tests.

No related CLI, FFmpeg, ffprobe, or test process remained. No private job or integration fixture directory remained.
The valid output and ignored evidence remain intentionally. Git was clean before this documentation addition.
Only this document is committed; media, build products, and logs are not tracked.
