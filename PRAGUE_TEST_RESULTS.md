# Large MOV test results

**PASS** for reviewed source commit `efb2c52289c3cce2d235d133de2ce371ed97dbea`.
Independent review passed before these tests. Run date: 2026-10-08 UTC.
No production code or tests changed during execution.
These results supersede the pending-test status for this fix in `TEST_RESULTS.md`.

## Environment and formal tests

- MacBook Pro Mac15,10; Apple M3 Max; 14 CPU cores; 36 GB RAM.
- macOS 27.0.1 (26A434); Swift 6.4; FFmpeg and ffprobe 9.0.2.
- Battery power; 57% before the benchmark. No power settings changed.
- Release executable: `.build/out/Products/Release/voice-remove`.

| Command | Result | Command wall time |
| --- | --- | --- |
| `swift test` | 36 XCTest tests; zero failures | 2.878037 s |
| `swift build -c release` | Exit 0 | 3.662644 s |
| `python3 Integration/run.py --binary "$BIN" -v` | 13 tests; zero failures/errors | 16.857271 s |

XCTest execution took 0.358 s. Integration execution took 16.788 s.
The genuine MOV timecode fixture passed, including copied packet hashes and redundant creation-time values.
The integration suite also passed cancellation, cleanup, collisions, metadata, chapters, rotation, and cover-art checks.

## Large-video benchmark

Input basename: `Day 2 Prague.mov`.
Output basename: `Day 2 Prague_voiceremoved.mov`, beside the input.
The output did not exist before this run. The command published one output and exited 0.

```sh
/usr/bin/time -l "$BIN" "$INPUT"
```

Settings: default two distinct Apple AUSoundIsolation units; HQ conversation mode 0; wet/dry -100.
Neither `--verify` nor `--faststart` was used.
Each unit reported 6360 latency frames, or 132.5 ms at 48 kHz.
The pipeline processed exactly 408,295,360 stereo audio frames.
Progress logs reached 8490 seconds before remux and successful publication.

| Measurement | Value |
| --- | --- |
| Input size | 53,508,955,021 bytes |
| Output size | 53,471,947,897 bytes |
| Available disk space before run | 201,486,528,512 bytes |
| Required preflight allowance | Input size plus 400,000,000 bytes for AAC |
| Available disk space after validation | 147,994,177,536 bytes |
| Full elapsed time, `time -l` | 523.80 s (8 min 43.80 s) |
| External monotonic wrapper time | 523.816563 s |
| CLI elapsed time | 523.69 s |
| User / system time | 710.17 / 33.39 s |
| Maximum resident set size (RSS), `time -l` | 3,352,330,240 bytes (3.122 GiB) |
| Reported peak memory footprint | 3,333,475,376 bytes |
| Processing speed | 16.239 times real time, using processed audio duration |

The benchmark includes probing, model setup, audio processing, remux, validation, and publication.
It excludes later independent sample checks. It includes no full-file hash reads.
RSS is not an aggregate simultaneous measurement of the complete process tree.
The large run reported much higher RSS than the earlier short-video benchmark.
This run does not identify the allocation source or prove a duration-independent total memory bound.
No cold-cache benchmark or memory profile was performed. One run does not establish general throughput.

## Original integrity scope

These original stat fields matched before processing and after all independent validation:

```text
device:   16777229
inode:    158638165
size:     53508955021
mode:     33206 (0o100666)
mtime_ns: 1791399657506762878
ctime_ns: 1791401979399579198
```

No full SHA-256 of the 53 GB original was computed. Access time was not an integrity criterion.
Unchanged stat fields support original preservation; they are not proof of byte-for-byte identity.

## Media validation

Independent ffprobe checks found exactly three streams in both files, in unchanged order:
H.264 video, AAC stereo audio, and one `tmcd` timecode track. Neither file contains chapters.
Stream dispositions matched. User metadata and creation instants matched.
Permitted container bookkeeping changed, including the encoder and video vendor identifier.
The file creation tag contains two identical timestamps after remux:
`2026-10-07T17:48:35.000000Z;2026-10-07T17:48:35.000000Z`.
Each value describes the original exact instant. Stream creation tags remain unchanged.

| Property | Source | Output |
| --- | --- | --- |
| Video dimensions | 3840 × 2160 | Same |
| Video rate | 50 fps | Same |
| Video start / duration | 0 / 8506.120000 s | Same |
| Video frame count, container metadata | 425306 | Same |
| Video time base | 1/12800 | Same |
| Audio format | AAC, 48 kHz, stereo | Same |
| Audio start | 0.000000 s | Same |
| Audio duration | 8506.197333 s | 8506.153333 s |
| Audio packet count, container metadata | 398728 | 398727 |
| Audio initial padding | 2112 frames | 1024 frames |
| Timecode value | 01:00:00:00 | Same |
| Timecode start / duration | 0 / 8506.120000 s | Same |
| Timecode time base / frame count | 1/12800 / 1 | Same |

The output audio duration equals `408295360 / 48000`, within ffprobe decimal precision.
The source-to-output difference is 44 ms, within the documented 50 ms tolerance.
The output retains audio beyond the video's end. AAC packet count and padding changed after re-encoding.

The timecode track retained its type, handler, creation time, language `eng`, and default disposition 1.
A bounded first-second packet probe found its single four-byte packet in both files.
The payload SHA-256 matched:

```text
50cfb2adf816e81cb884576597fe3a6a8e46f9103e964a194cdad34e91686363
```

This checks the complete reported timecode payload without scanning all video packets.

## Independent sample decodes

Strict FFmpeg decodes used `-xerror -err_detect explode` and input seeking.
Each window covers two seconds in both source and output:

| Window | Time range | Video frames per file | Audio frames per file |
| --- | --- | --- | --- |
| Head | 0–2 s | 100 | 96000 |
| Middle | 4252.06–4254.06 s | 100 | 96000 |
| Tail | 8504.12–8506.12 s | 100 | 96000 |

All 12 commands exited 0. Decoded video frame MD5 values matched at every sampled frame.
Audio decoded successfully; its PCM hashes differ after processing, as expected.
The tail window ends at the video's end, before the final audio-only fraction of a second.
Full video packet hashes and full independent video/audio decodes were not performed.
Container frame counts are metadata checks, not independent full-stream counts.

## Evidence, cleanup, and open limits

Ignored evidence resides in `.build/test-results/prague-final/`:

- `swift-test.log`, `release-build.log`, `integration.log`, and their result JSON files.
- `benchmark.stdout`, `benchmark.stderr`, and `benchmark-result.json`.
- `original-before.json`, `original-after.json`, `preflight.json`, and `cleanup-check.json`.
- `source-probe.json`, `output-probe.json`, and bounded timecode packet probes.
- `sample-validation-summary.json`, `sample-validation-commands.json`, decoded video frame hashes, and decode logs.
- `validate_samples.py` and environment records. Raw environment records remain local and include system identifiers.

No `voice-remove`, FFmpeg, or ffprobe process remained after validation.
No private job directory or integration fixture directory remained.
The valid output and ignored evidence remain intentionally. Media and logs are not tracked.

**Human listening was not performed.** Residual conversation and unwanted sound changes remain unassessed.
These tests establish execution and the stated preservation checks, not audible suppression quality.
Full original integrity and full copied-video identity remain outside this run's verification scope.
The high RSS measurement needs separate profiling before a general total-memory claim.
The only additional documentation change clarifies exact-match acceptance of historically accepted malformed creation timestamps.
