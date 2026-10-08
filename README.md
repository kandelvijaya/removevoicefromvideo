# voice-remove

A compiled Swift command-line tool for **conversation suppression** on macOS.
The tool leaves originals unchanged. It creates `<stem>_voiceremoved.<original extension>` beside each input.
With `--audio-only`, it creates `<stem>_voiceremoved.wav` instead. Existing outputs remain unchanged.

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

The repository does not include sample videos, model downloads, or build products.
Apple supplies the native model through macOS. FFmpeg and ffprobe run locally; the tool does not upload media.

## Use

```sh
"$BIN" inputVideo.MP4
# stdout: /absolute/path/inputVideo_voiceremoved.MP4

"$BIN" /path/to/videos --jobs 2
"$BIN" clip.mov --passes 1 --verify
"$BIN" clip.MP4 --faststart
"$BIN" clip.MP4 --audio-only
# stdout: /absolute/path/clip_voiceremoved.wav
"$BIN" /path/to/videos --audio-only --jobs 1
```

| Option | Behavior |
| --- | --- |
| `--passes 1` | Use one isolation unit. Default: two distinct units in sequence. |
| `--jobs N` | Limit folder concurrency to 1–8 jobs. Default: 2. |
| `--audio-only` | Create aligned 48 kHz, 24-bit PCM WAV. Preserve mono/stereo channels. No AAC or video copy. |
| `--verify` | Compare SHA-256 hashes of copied video and timecode packet payloads, including attached pictures. Not available with `--audio-only`. |
| `--faststart` | Rewrite MP4/MOV/M4V headers for progressive playback. Default: off. Not available with `--audio-only`. |
| `--help` | Show usage. |

Give exactly one file or folder. Use `--` before a path that starts with `-`.
Folders are nonrecursive. The tool selects MP4, MOV, M4V, MKV, AVI, and WebM extensions, without case sensitivity.
It excludes hidden files, symlinks, and stems that end with `_voiceremoved`.
Selection does not guarantee container compatibility. MP4 and MOV are the initial validation targets.

The tool **never overwrites** an output. There is no force option.
Successful output paths go to stdout. Progress, dropped-stream reports, and errors go to stderr.
Folder output order depends on completion order. Folder jobs continue after individual failures.
The exit status is 0 for success, 1 for failures, and 130 for cancellation.

## Audio-only WAV path

`--audio-only` uses the same decoder and native isolation passes. The default remains two distinct passes.
It streams corrected audio directly to a 48 kHz, 24-bit signed little-endian PCM WAV file.
It preserves the source's mono or stereo channels. It creates no AAC intermediate and copies no video.
Original videos and existing video outputs remain unchanged.

WAV time zero corresponds to the first frame of the first non-attached video stream.
The tool requires a finite main video start and a positive finite main video duration before model setup.
It uses the main video stream duration, not the container duration or audio duration.
It rounds duration and relative audio start independently to the nearest 48 kHz sample. Half-sample ties round away from zero.
Audio that starts later receives leading silence. Audio before the video receives an initial trim.
The tool pads or trims the end to exactly the target sample count. No audio coverage produces silence.
All native passes still process and drain the complete decoded audio. Their frame counts remain separate from the aligned WAV count.
Memory stays bounded. A short video target does not leave a blocked decoder or skip source validation.

The tool finalizes a seekable temporary WAV before validation and atomic, no-replace publication.
Validation always checks WAV format, 24-bit PCM, 48 kHz, channel count, zero start, duration, and exact sample count.
FFprobe duration ticks establish the exact count. If ticks are unavailable, a bounded decode counts samples.
WAV normally has no start timestamp field; an absent field represents zero.
`--verify` checks copied video, so the CLI rejects it with `--audio-only`. It does not disable WAV validation.
The CLI also rejects `--faststart` with `--audio-only`.

The WAV path does not copy source metadata, chapters, cover art, subtitles, or timecode tracks.
Video-remux metadata and container restrictions do not apply. Mono/stereo, one-audio-track, and unsupported-stream guards still apply.
Folder processing remains nonrecursive. Same-stem inputs with different extensions would share one WAV destination and fail before processing.
The output naming rule and no-overwrite policy still apply.

FFmpeg automatically selects RF64 when the WAV exceeds the ordinary RIFF size limit, approximately 4 GiB.
DaVinci Resolve interoperability with RF64 is **not verified**. Ordinary WAV interoperability also requires the user's editor check.
This mode adds no Broadcast Wave Format metadata or timecode. Align WAV time zero with the video's first frame in the editor.

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
The tool copies `tmcd` timecode data tracks in MOV only. FFprobe can omit their codec name.
The tool maps those tracks explicitly and disables automatic timecode-track generation with `-write_tmcd 0`.
It retains the timecode value, handler, creation time, language, and dispositions.
Timecode tracks require finite start times, positive finite durations, and a nonempty timecode tag before audio processing.
Time bases require two positive ASCII decimal integers separated by `/`. Each component must fit a signed 32-bit integer.
Frame counts require a positive ASCII decimal integer that fits a signed 64-bit integer.
Time bases and frame counts reject signs, whitespace, missing values, and `N/A`.
They also reject zero, negative values, overflow, and malformed numeric fields. Finite negative start times remain valid.
These rules apply to source and output tracks. Identical malformed values also fail validation.
Copied timecode tracks in MP4, M4V, and other containers fail preflight. Ordinary MP4/M4V inputs remain supported.
FFmpeg's MP4/M4V codec tables reject copied `tmcd` tracks; automatic timecode generation uses a separate path.
The tool reports and drops other data streams, such as DJI camera telemetry. The muxer can recreate a chapter data track.
Unknown output data tracks fail validation, except `bin_data` tracks when the source has chapters.
This exception does not check track identity or limit the number of `bin_data` tracks.
An extra or missing timecode track always fails validation, including when the source has chapters.
The tool maps file metadata, rotation, chapters, stream language, and dispositions explicitly.
Validation rejects changed user metadata or unsupported metadata that the output container cannot retain.
Container bookkeeping tags, such as encoder and brand tags, can change.
Creation-time validation compares exact instants, including all fractional digits, rather than timestamp text.
Only valid RFC 3339 timestamps receive semantic comparison. Different instants and lost nonzero fractional precision fail.
FFprobe can join MOV header and `mdta` creation times with `;`. Every value must describe the same instant.
Conflicting or malformed values cannot receive semantic equivalence.
Exact text matches retain historical acceptance, including identical malformed timestamps. The semantic parser rejects malformed alternate representations.
All other user tags require exact values.

MP4/M4V cover art requires FFmpeg's standard iTunes metadata path, which writes the `covr` atom.
The tool disables `use_metadata_tags` when an attached picture exists. `--faststart` remains available.
Standard file tags include title, comment, artist, album, copyright, and creation time.
Unknown file tags with cover art fail preflight. Recognized tags must still pass value validation after remux.
Without cover art, MP4/MOV/M4V use `use_metadata_tags` (`mdta`) to retain custom file tags.
This flag does not add support for arbitrary stream or chapter tags.
MOV inputs with attached pictures fail preflight: FFmpeg's native MOV metadata path does not write `covr`.
The tool does not silently replace the MOV container with MP4.
This policy follows [FFmpeg 9.0.2 movenc.c](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavformat/movenc.c),
including `mov_write_meta_tag`, `mov_write_ilst_tag`, and `mov_write_udta_tag`.

Validation checks stream structure, AAC format, timing, rotation, user metadata, chapters, language, and dispositions.
The timing tolerance is 50 ms for AAC packet rounding and container precision.
Copied timecode timing has a stricter 1 ms tolerance. Its time base and frame count must remain unchanged.
Attached-picture timing is container-derived and does not receive the main-video duration check.
The tool does **not** use `-shortest`. Audio can remain longer than the video.
`--verify` adds whole-file reads and checks the concatenated packet payloads of each video and timecode stream.
It does not compare the entire container file or measure speech attenuation.

## Resource use and failure behavior

PCM memory stays bounded by block size and pass count, not video duration.
Apple's model allocates additional memory. Two concurrent jobs create four model instances.
Use `--jobs 1` if memory pressure is high. More jobs do not guarantee more throughput.
Throughput depends on hardware, runtime, media, and disk speed. Local benchmarks do not establish a general speech-removal rate.

The default path needs a new video-sized output and a compressed AAC temporary file.
The WAV path needs only the new WAV, approximately 144,000 bytes per second per channel, plus its small header.
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
- The WAV path also requires valid main video timing. It does not support a user-selected time range.
- Resamples every source to 48 kHz. The default path encodes AAC; `--audio-only` encodes 24-bit PCM. Native processing changes audio.
- The default path requires AAC-compatible muxers. WebM usually rejects AAC. Some containers reject attached pictures or metadata.
- Arbitrary timestamp discontinuities, changing channel layouts, and unusual edit lists need further validation.
- The native model can change output across macOS versions. Native output is not byte-reproducible.
- File permissions and extended attributes are not copied to the output. Originals remain unchanged.

## Tests

The latest local run passed **44 unit tests and 17 native integration tests**.
See [audio-only results](AUDIO_ONLY_TEST_RESULTS.md), [large MOV results](PRAGUE_TEST_RESULTS.md),
and [initial benchmark results](TEST_RESULTS.md) for tested commits, environments, and limitations.
These local results are not a claim that GitHub-hosted native tests passed.

Run the suites on macOS 15 or later with FFmpeg installed:

```sh
swift test
swift build -c release
BIN="$(swift build -c release --show-bin-path)/voice-remove"
python3 Integration/run.py --binary "$BIN" -v
```

The deterministic tests cover alignment across partial blocks, positive/negative offsets, no audio coverage,
fractional sample boundaries, per-pass drain accounting, WAV metadata mismatches, and incompatible flags.
Native WAV fixtures cover mono/stereo, nonzero video starts, initial silence, start/end trims, end padding,
exact decoded sample counts, folder collisions, no-overwrite behavior, and absence of AAC/video intermediates.

Unit tests use a deterministic delay renderer. They cover initial latency discard, exact lengths, empty audio,
partial byte reads, short blocks, independent stereo samples, and one-pass and two-pass pipelines.
They also cover metadata, mapping, collisions, folder selection, stderr backpressure, and child cancellation.
Native integration tests generate small FFmpeg fixtures in a temporary folder.
They cover mono, distinct stereo, timing offsets, longer audio, MOV, rotation, chapters, custom metadata,
attached pictures, folder concurrency, unsupported tracks, no-overwrite behavior, and SIGINT/SIGTERM cleanup with exit status 130.
The cover fixture asserts exactly one attached picture and a 90-degree rotation before it invokes the tool.
Custom file metadata uses a separate fixture without cover art. A negative fixture checks early `--faststart` rejection.
A separate 50 fps MOV fixture requires a genuine `tmcd` track before it invokes the tool.
It checks copied timecode packet hashes, track count, type, timing, value, metadata, and disposition.
Unit tests also cover MOV-only timecode preflight and invalid numeric fields, including identical malformed source and output values.
Integration tests need FFmpeg's `libx264` encoder. They do not require personal media.

[GitHub Actions](.github/workflows/ci.yml) runs unit tests, a release build, and a CLI help check on macOS 15.
Native integration tests are optional through **Actions → CI → Run workflow**.
Native Apple model availability on GitHub runners remains unverified.
See [CONTRIBUTING.md](CONTRIBUTING.md) for development and publication checks.

After the synthetic suites pass, measure the real video separately:

```sh
/usr/bin/time -l "$BIN" inputVideo.MP4 --verify
```

Record macOS version, hardware, elapsed time, maximum resident memory, input size, and settings.
Hash the original before and after the run. Listen to the output for residual conversation and unwanted sound changes.
The command fails if `inputVideo_voiceremoved.MP4` already exists. Archive that output before a repeat benchmark.

## Source layout

- `Sources/VoiceRemovedCore/Isolation.swift`: native unit setup and fixed-size rendering.
- `Sources/VoiceRemovedCore/PCM.swift`: bounded stream assembly, per-pass latency correction, and video alignment.
- `Sources/VoiceRemovedCore/AudioOnly.swift`: main video timing preflight and exact WAV validation.
- `Sources/VoiceRemovedCore/Media.swift`: probing, remux arguments, timing and stream validation.
- `Sources/VoiceRemovedCore/Metadata.swift`: user metadata validation.
- `Sources/VoiceRemovedCore/Support.swift`: child lifetime, cancellation, tools, and atomic publication.
- `Sources/VoiceRemovedCore/Pipeline.swift`: streaming jobs and folder selection.
- `Sources/voice-remove/main.swift`: argument parsing and bounded folder concurrency.
- `Tests/VoiceRemovedCoreTests/`: deterministic and process-level unit tests.
- `Integration/run.py`: reproducible native fixtures and integration checks.
