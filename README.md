# voice-remove

A compiled Swift command-line tool for **conversation suppression** on macOS.
The tool leaves originals unchanged. It creates `<stem>_voiceremoved.<original extension>` beside each input.

Suppression is not guaranteed removal. Speech can remain audible. Other sounds can change.
This release does not target singing. Listen to the result before use.

## Requirements and build

- macOS 15 or later. The tool requires Apple's HQ AUSoundIsolation (`vois`) mode.
- Swift 5.9 or later, with a macOS SDK that supports macOS 15.
- FFmpeg and ffprobe: `brew install ffmpeg`.

```sh
swift build -c release
BIN="$(swift build -c release --show-bin-path)/voice-remove"
"$BIN" --help
```

Swift Package Manager chooses the build directory. Do not assume `.build/release` exists.
Copy the compiled executable to a directory in `PATH` if needed. No helper executable or shell wrapper is required.

## Use

```sh
"$BIN" inputVideo.MP4
# stdout: /absolute/path/inputVideo_voiceremoved.MP4

"$BIN" /path/to/videos --jobs 2
"$BIN" clip.mov --passes 1 --verify
"$BIN" clip.MP4 --faststart
```

| Option | Behavior |
| --- | --- |
| `--passes 1` | Use one isolation unit. Default: two distinct units in sequence. |
| `--jobs N` | Limit folder concurrency to 1–8 jobs. Default: 2. |
| `--verify` | Compare SHA-256 hashes of copied video packet payloads, including attached pictures. |
| `--faststart` | Rewrite MP4/MOV/M4V headers for progressive playback. Default: off. |
| `--help` | Show usage. |

Give exactly one file or folder. Use `--` before a path that starts with `-`.
Folders are nonrecursive. The tool selects MP4, MOV, M4V, MKV, AVI, and WebM extensions, without case sensitivity.
It excludes hidden files, symlinks, and stems that end with `_voiceremoved`.
Selection does not guarantee container compatibility. MP4 and MOV are the initial validation targets.

The tool **never overwrites** an output. There is no force option.
Successful output paths go to stdout. Progress, dropped-stream reports, and errors go to stderr.
Folder output order depends on completion order. Folder jobs continue after individual failures.
The exit status is 0 for success, 1 for failures, and 130 for cancellation.

## Audio and video path

1. Parse ffprobe JSON. Require one mono or stereo audio track and a main video stream.
   Reject known metadata conflicts and incompatible `--faststart` requests before audio processing.
2. Decode the audio through FFmpeg into bounded Float32 buffers at 48 kHz.
3. Process two distinct Apple `vois` units in memory. Use non-interleaved Float32 inside each unit.
4. Set HQ conversation mode to 0. Set wet/dry to **-100**, which selects the background output on the validated runtime.
5. Query channel capability, parameter ranges, format acceptance, and latency. Fail if the runtime rejects the configuration.
6. Render exactly **4096 frames** each time. Discard each unit's initial latency output.
7. Flush each pass with zeros. Emit exactly the decoded source frame count, including short final blocks.
8. Stream the processed audio to an AAC `.m4a` temporary file. Use 160 kb/s for mono and 320 kb/s for stereo.
9. Remux with `-c:v copy` and stream-copy the AAC track. Restore the original audio start timestamp.
10. Validate the temporary output. Publish it with an atomic, no-replace hard link on the same filesystem.

There are no full-size PCM files and no complete audio arrays in memory.
The second unit reads the first unit's corrected stream, not a disk intermediate.
The tool retains stereo channels. It does not assume dual-mono content or fall back to mono.

The tool preserves all video streams, including attached pictures, when the container supports them.
It copies subtitle streams when the container supports them. Unsupported combinations fail without publication.
The tool reports and drops data streams, such as camera telemetry. The muxer can recreate a chapter data track.
The tool maps file metadata, rotation, chapters, stream language, and dispositions explicitly.
Validation rejects changed user metadata or unsupported metadata that the output container cannot retain.
Container bookkeeping tags, such as encoder and brand tags, can change.

MP4/M4V cover art requires FFmpeg's standard iTunes metadata path, which writes the `covr` atom.
The tool disables `use_metadata_tags` when an attached picture exists. `--faststart` remains available.
Standard file tags include title, comment, artist, album, copyright, and creation time.
Unknown file tags with cover art fail preflight. Recognized tags must still pass exact value validation after remux.
Without cover art, MP4/MOV/M4V use `use_metadata_tags` (`mdta`) to retain custom file tags.
This flag does not add support for arbitrary stream or chapter tags.
MOV inputs with attached pictures fail preflight: FFmpeg's native MOV metadata path does not write `covr`.
The tool does not silently replace the MOV container with MP4.
This policy follows [FFmpeg 9.0.2 movenc.c](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavformat/movenc.c),
including `mov_write_meta_tag`, `mov_write_ilst_tag`, and `mov_write_udta_tag`.

Validation checks stream structure, AAC format, timing, rotation, user metadata, chapters, language, and dispositions.
The timing tolerance is 50 ms for AAC packet rounding and container precision.
Attached-picture timing is container-derived and does not receive the main-video duration check.
The tool does **not** use `-shortest`. Audio can remain longer than the video.
`--verify` adds whole-file reads and checks the concatenated packet payloads of each video stream.
It does not compare the entire container file or measure speech attenuation.

## Resource use and failure behavior

PCM memory stays bounded by block size and pass count, not video duration.
Apple's model allocates additional memory. Two concurrent jobs create four model instances.
Use `--jobs 1` if memory pressure is high. More jobs do not guarantee more throughput.
No throughput or speech-removal rate is claimed before independent tests and measurement.

Disk use includes the new video-sized output and the compressed AAC temporary file.
The tool does not enable faststart by default because faststart adds disk work.
A hidden, private `.voiceremoved-<UUID>` directory holds temporary files beside the final output.
The final publication never replaces an existing file, including a symlink or a concurrent job's result.
The filesystem must support hard links. A publication failure leaves no new final output.

FFmpeg and ffprobe run directly through Swift `Process`, without a shell.
The tool drains child stderr concurrently and retains its last 64 KiB for errors.
It caps captured metadata at 8 MiB. Decoder and encoder pipes apply backpressure.
SIGINT and SIGTERM cancel jobs, stop children, and remove temporary files.
A child that does not stop receives SIGKILL after one second.
SIGKILL, power loss, or a filesystem cleanup failure can leave a temporary directory.
The tool cannot undo a valid output that completed before cancellation.

## Initial limitations

- Rejects no-audio inputs, multiple audio tracks, surround audio, and unknown stream types.
- Requires a readable audio start timestamp. Output duration must be available from ffprobe or a Matroska duration tag.
- Resamples every source to 48 kHz and re-encodes audio as AAC. Audio is not lossless.
- AAC-compatible muxers are required. WebM usually rejects AAC. Some containers reject attached pictures or metadata.
- Arbitrary timestamp discontinuities, changing channel layouts, and unusual edit lists need further validation.
- The native model can change output across macOS versions. Native output is not byte-reproducible.
- File permissions and extended attributes are not copied to the output. Originals remain unchanged.

## Review and test sequence

**Do not run formal tests until independent review passes.**
Release compilation, test-target compilation, and CLI help received development checks during implementation.
The test targets compiled without execution.
The suites below are code for the test stage; their presence does not mean they passed.

After review:

```sh
swift test
swift build -c release
BIN="$(swift build -c release --show-bin-path)/voice-remove"
python3 Integration/run.py --binary "$BIN" -v
```

Unit tests use a deterministic delay renderer. They cover initial latency discard, exact lengths, empty audio,
partial byte reads, short blocks, independent stereo samples, and one-pass and two-pass pipelines.
They also cover metadata, mapping, collisions, folder selection, stderr backpressure, and child cancellation.
Native integration tests generate small FFmpeg fixtures in a temporary folder.
They cover mono, distinct stereo, timing offsets, longer audio, MOV, rotation, chapters, custom metadata,
attached pictures, folder concurrency, unsupported tracks, no-overwrite behavior, and SIGINT/SIGTERM cleanup with exit status 130.
The cover fixture asserts exactly one attached picture and a 90-degree rotation before it invokes the tool.
Custom file metadata uses a separate fixture without cover art. A negative fixture checks early `--faststart` rejection.
Integration tests need FFmpeg's `libx264` encoder. They do not touch `inputVideo.MP4`.

After the synthetic suites pass, measure the real video separately:

```sh
/usr/bin/time -l "$BIN" inputVideo.MP4 --verify
```

Record macOS version, hardware, elapsed time, maximum resident memory, input size, and settings.
Hash the original before and after the run. Listen to the output for residual conversation and unwanted sound changes.
The command fails if `inputVideo_voiceremoved.MP4` already exists. Archive that output before a repeat benchmark.

## Source layout

- `Sources/VoiceRemovedCore/Isolation.swift`: native unit setup and fixed-size rendering.
- `Sources/VoiceRemovedCore/PCM.swift`: bounded stream assembly and per-pass latency correction.
- `Sources/VoiceRemovedCore/Media.swift`: probing, remux arguments, timing and stream validation.
- `Sources/VoiceRemovedCore/Metadata.swift`: user metadata validation.
- `Sources/VoiceRemovedCore/Support.swift`: child lifetime, cancellation, tools, and atomic publication.
- `Sources/VoiceRemovedCore/Pipeline.swift`: streaming jobs and folder selection.
- `Sources/voice-remove/main.swift`: argument parsing and bounded folder concurrency.
- `Tests/VoiceRemovedCoreTests/`: deterministic and process-level unit tests.
- `Integration/run.py`: reproducible native fixtures and integration checks.
