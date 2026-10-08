# Implementation details

This reference preserves the technical details from the original README.
See the [README](../README.md) for commands and requirements.

## Native isolation

The tool uses Apple's AUSoundIsolation (`vois`) high-quality conversation mode.
The runtime must accept mode `0` and wet/dry `-100`. Negative wet/dry selects the background output on the tested runtime.
The tool checks channel capability, parameter ranges, audio formats, and latency before it starts child processes.
A rejected native configuration causes an error.

FFmpeg decodes audio to interleaved Float32 buffers at 48 kHz.
Each isolation unit uses non-interleaved Float32 internally.
The default pipeline uses two distinct units in sequence. The second unit reads the first unit's corrected output.
The tool preserves stereo channels. It does not assume dual-mono audio or fall back to mono.

Each native render contains exactly 4096 frames.
Each pass discards its initial latency output, then flushes with zeros at the end.
Each pass emits exactly the decoded source frame count, including short final blocks.
No complete audio arrays or full-size raw audio files are required.

## Video output

The video path encodes processed audio to a temporary Advanced Audio Coding (AAC) file.
The requested bitrate is 160 kb/s for mono or 320 kb/s for stereo.
FFmpeg copies the video and encoded audio streams into the destination container.
The tool restores the original audio start timestamp. It does not use `-shortest`.
Audio can extend beyond the video's end.

The tool checks known metadata conflicts and incompatible `--faststart` requests before audio processing.
It preserves supported video streams, including attached pictures.
It copies subtitle streams when the container supports them.
Unsupported combinations cause errors without a final output.

## Audio-only alignment

The audio-only path uses the same decoder and native passes.
It sends corrected audio directly to a Waveform Audio File Format (WAV) file.
The file uses 48 kHz, 24-bit signed little-endian pulse-code modulation (PCM).
It creates no AAC intermediate and copies no video.

Time zero is the first frame of the first video stream that is not an attached picture.
The main video start must be finite. The main video duration must be finite and positive.
The tool uses that duration, not the container duration or source audio duration.

Duration and relative audio start are rounded independently to the nearest sample.
Half-sample ties round away from zero.
A later audio start adds leading silence. An earlier audio start removes initial samples.
The tool adds silence or removes samples at the end to match the target count.
Intervals without audio contain silence.

Every native pass processes and drains the complete decoded source audio.
Decoded counts remain separate from the aligned WAV count.
A short target does not leave the decoder blocked or bypass source validation.

The WAV path copies no source metadata, chapters, cover art, subtitles, or timecode.
It adds no Broadcast Wave Format metadata.
Video-remux restrictions do not apply, but the source must still pass basic stream validation.
Source inputs require one mono or stereo audio track and no unknown stream types.

Folder input remains nonrecursive.
Same-stem inputs with different extensions share one WAV destination.
The command rejects these folder collisions before processing.

FFmpeg uses a seekable temporary file to finalize WAV headers.
It selects RF64 automatically above the ordinary WAV size limit, approximately 4 gibibytes (GiB).
Import into DaVinci Resolve remains unverified for ordinary WAV and RF64.

## Timecode and data tracks

The tool copies `tmcd` data tracks in MOV only. ffprobe can omit their codec name.
The tool maps these tracks explicitly and disables automatic generation with `-write_tmcd 0`.
It retains the timecode value, handler, creation time, language, and dispositions.

Each timecode track requires a finite start, a positive finite duration, and a nonempty timecode tag.
Finite negative starts remain valid.
Time bases require two positive decimal integers separated by `/`.
Each component must fit a signed 32-bit integer.
Frame counts require a positive decimal integer that fits a signed 64-bit integer.

Numeric fields accept American Standard Code for Information Interchange (ASCII) digits only.
They reject signs, whitespace, missing values, `N/A`, zero, overflow, and malformed values.
These checks apply to source and output. Identical malformed values also fail.

MP4, M4V, and other containers reject copied timecode tracks during preflight.
Ordinary MP4 and M4V inputs remain supported.
FFmpeg's codec tables reject copied `tmcd` tracks in those containers. Automatic timecode generation uses a separate path.

The tool reports and drops other data tracks, such as DJI telemetry.
The muxer can recreate a chapter data track.
Unknown output data tracks fail validation, except `bin_data` tracks when the source has chapters.
This exception does not check track identity or limit track count.
Extra or missing timecode tracks always fail, including when chapters exist.

## Metadata and cover art

The tool maps file metadata, rotation, chapters, stream language, and dispositions explicitly.
Changed user metadata causes a validation error.
Unsupported metadata that the output container cannot retain also causes an error.
Bookkeeping tags, such as encoder and brand tags, can change.

Creation-time validation compares exact instants, including all fractional digits.
Only valid Request for Comments (RFC) 3339 timestamps receive semantic comparison.
Different instants and lost nonzero fractional precision fail validation.
ffprobe can join MOV header and `mdta` creation times with `;`.
Every value must describe the same instant.

Conflicting or malformed values cannot receive semantic equivalence.
Exact text matches retain historical acceptance, including identical malformed timestamps.
Other user tags require exact values.

MP4 and M4V cover art require FFmpeg's standard iTunes metadata path and its `covr` atom.
The tool disables `use_metadata_tags` when an attached picture exists.
`--faststart` remains available.
Standard file tags include title, comment, artist, album, copyright, and creation time.
Unknown file tags with cover art cause a preflight error.
Recognized tags must still pass validation after remux.

Without cover art, MP4, MOV, and M4V use `use_metadata_tags` (`mdta`) for custom file tags.
This option does not support arbitrary stream or chapter tags.
MOV inputs with attached pictures cause a preflight error because FFmpeg's MOV path does not write `covr`.
The tool does not replace MOV with MP4.

This policy follows [FFmpeg 9.0.2 movenc.c](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavformat/movenc.c).
Relevant functions include `mov_write_meta_tag`, `mov_write_ilst_tag`, and `mov_write_udta_tag`.

## Validation and publication

Video validation checks stream structure, AAC format, timing, rotation, metadata, chapters, language, and dispositions.
AAC timing allows 50 ms for packet rounding and container precision.
Copied timecode timing allows 1 ms. Its time base and frame count must remain unchanged.
Attached-picture timing comes from the container and does not receive the main video duration check.

`--verify` compares SHA-256 (256-bit Secure Hash Algorithm) hashes of concatenated packet payloads for each copied video and timecode stream.
It includes attached pictures. It adds whole-file reads.
It does not compare complete container files or measure speech reduction.

WAV validation always checks format, 24-bit PCM, 48 kHz, channels, zero start, duration, and exact sample count.
ffprobe duration ticks establish the count. If ticks are unavailable, a bounded decode counts samples.
WAV normally has no start timestamp field. An absent field represents zero.
`--audio-only` rejects `--verify` and `--faststart`.

The tool completes and validates the temporary output before publication.
A same-filesystem hard link publishes the file atomically without replacement.
The filesystem must support hard links.
Publication never replaces a file, symbolic link, or another job's result.
A publication error leaves no new final output.

## Resources and failures

Audio buffer memory depends on block size and pass count, not video duration.
Apple's model allocates additional memory. Two simultaneous jobs create four model instances.
This does not establish a duration-independent bound for total process memory.
See the [large MOV measurement](../PRAGUE_TEST_RESULTS.md) for a high observed memory value.

Video mode needs a new video-sized output and compressed temporary AAC audio.
WAV mode needs approximately 144,000 bytes per second per channel, plus a header.
`--faststart` is off by default because it adds disk work.
Each job uses a universally unique identifier (UUID) for its private directory, `.voiceremoved-<UUID>`.
This directory holds temporary files beside the final output.

FFmpeg and ffprobe run directly through Swift `Process`, without a shell.
The tool drains child standard error concurrently and retains the last 64 kibibytes (KiB).
Captured metadata has a limit of 8 mebibytes (MiB). Pipes apply backpressure.
SIGINT and SIGTERM cancel jobs, stop children, and remove temporary files.
A child that does not stop receives SIGKILL after one second.

SIGKILL, power loss, or cleanup failure can leave a temporary directory.
Cancellation does not remove valid outputs that completed earlier.
Original files remain unchanged. Output does not copy file permissions or extended attributes.

Input requires a readable audio start timestamp.
Required durations must come from ffprobe or a Matroska duration tag.
Arbitrary timestamp discontinuities, changing channels, and unusual edit lists require further validation.
Native output can change across macOS versions and is not byte-reproducible.

## Source and tests

- `Sources/VoiceRemovedCore/Isolation.swift`: unit setup and fixed-size renders.
- `Sources/VoiceRemovedCore/PCM.swift`: stream assembly, latency correction, and video alignment.
- `Sources/VoiceRemovedCore/AudioOnly.swift`: video timing preflight and WAV validation.
- `Sources/VoiceRemovedCore/Media.swift`: probes, remux arguments, and stream validation.
- `Sources/VoiceRemovedCore/Metadata.swift`: user metadata validation.
- `Sources/VoiceRemovedCore/Support.swift`: child lifetime, cancellation, tools, and publication.
- `Sources/VoiceRemovedCore/Pipeline.swift`: jobs and folder selection.
- `Sources/voice-remove/main.swift`: command parsing and job limits.
- `Tests/VoiceRemovedCoreTests/`: deterministic and process-level tests.
- `Integration/run.py`: synthetic native fixtures and preservation checks.

Tests cover latency, exact lengths, partial reads, channel independence, offsets, empty audio, and end handling.
They also cover stderr backpressure, cancellation, collisions, metadata, rotation, chapters, and cover art.
Native timecode fixtures require a genuine 50 fps MOV timecode track before processing.
WAV fixtures check mono/stereo alignment, silence, trims, complete upstream drain, exact counts, and absence of AAC/video intermediates.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for test commands.
