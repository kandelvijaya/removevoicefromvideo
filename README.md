# voice-remove

Reduce conversation audio in videos on macOS with Apple's AUSoundIsolation model.
The tool is a compiled Swift command-line program. Original files remain unchanged.
All processing stays on your Mac. The tool does not upload media.

Speech can remain audible. Other sounds can change. The tool does not target singing.
Listen to each output before use.

## Requirements

- macOS 15 or later.
- Swift 5.9 or later, with a software development kit (SDK) that supports macOS 15.
- FFmpeg and ffprobe.

Apple supplies the native model through macOS. The repository contains no model downloads or sample videos.

## Build

1. Install FFmpeg and ffprobe.

   ```sh
   brew install ffmpeg
   ```

2. Build the program.

   ```sh
   swift build -c release
   ```

3. Set the path to the executable.

   ```sh
   BIN="$(swift build -c release --show-bin-path)/voice-remove"
   ```

Swift Package Manager selects the build directory. No shell wrapper is required.

## Use

Give one file or folder.

```sh
"$BIN" clip.MP4
"$BIN" /path/to/videos --jobs 2
"$BIN" clip.mov --passes 1 --verify
"$BIN" clip.MP4 --audio-only
```

The tool writes each output beside its input:

- Video: `<stem>_voiceremoved.<original extension>`.
- Audio only: `<stem>_voiceremoved.wav`.

The tool **never replaces an existing file**. There is no force option.
If a path starts with `-`, put `--` before the path.

| Option | Function |
| --- | --- |
| `--passes 1\|2` | Set the number of isolation passes. Default: `2`. |
| `--jobs N` | Set the maximum number of simultaneous folder jobs, from `1` to `8`. Default: `2`. |
| `--audio-only` | Create an aligned Waveform Audio File Format (WAV) file instead of a video. |
| `--verify` | Check that copied video, cover art, and timecode data match the source. |
| `--faststart` | Move MP4, MOV, or M4V headers to the start for progressive playback. Default: off. |
| `--help` | Show the command options. |

`--verify` compares stream data, not complete files. It requires additional reads of the input and output.
`--audio-only` rejects `--verify` and `--faststart`. WAV validation always runs.

Folder searches exclude subfolders, hidden files, symbolic links, and names that end with `_voiceremoved` before the extension.
Folder jobs continue after individual failures. Output order depends on job completion.

Successful output paths go to standard output (`stdout`). Progress and errors go to standard error (`stderr`).
Exit codes are `0` for success, `1` for failure, and `130` for cancellation.

## Audio-only output

The WAV output uses 48 kHz, 24-bit pulse-code modulation (PCM).
The tool preserves mono or stereo channels. This mode creates no intermediate AAC (Advanced Audio Coding) file and copies no video.

The main video is the first video stream that is not an attached picture.
WAV time zero matches the first frame of the main video. The WAV duration matches the main video, not the container.
The tool adds silence or trims audio to align the start and end. It rounds times to the nearest audio sample.
WAV output contains no source metadata, chapters, cover art, subtitles, or timecode.

In DaVinci Resolve, place the WAV at the original video's start.
Import into DaVinci Resolve remains unverified.

Above approximately 4 gibibytes (GiB), FFmpeg selects RF64, a 64-bit extension of WAV.
RF64 support in DaVinci Resolve remains unverified.

## Formats and limits

- Folder searches select MP4, MOV, M4V, MKV, AVI, and WebM files. Filename extensions are not case-sensitive.
- MP4 and MOV are the main tested containers. A selected extension does not guarantee compatibility.
- Inputs require one mono or stereo audio track, a main video stream, and a readable audio start timestamp.
- Audio-only output also requires a finite video start and a positive finite video duration.
- The default mode copies video and encodes audio as AAC. Some containers, such as WebM, reject AAC.
- Video output can retain audio beyond the video's end. WAV output matches the video's duration.
- Video output retains compatible video streams, cover art, subtitles, metadata, chapters, rotation, and stream settings.
- Video output copies `tmcd` timecode tracks in MOV only. Other video containers with these tracks cause errors.
- For video output, the tool reports and drops other data tracks, such as DJI telemetry.
- For video output, MOV cover art and unsupported metadata combinations cause errors. See [implementation details](docs/IMPLEMENTATION.md).
- All audio uses 48 kHz. Output can change across macOS versions. Speech reduction is not guaranteed.
- Multiple audio tracks, surround audio, and unknown stream types cause errors. User-selected time ranges are not supported.
- Timestamp gaps, channel changes, and unusual edit lists require further tests.
- The tool does not copy file permissions or extended attributes.

## Resources and cancellation

Audio buffers have fixed size. Apple's model uses additional memory.
Use `--jobs 1` if available memory is low. More jobs do not guarantee faster processing.

Video mode needs space for a new video and temporary AAC audio.
WAV output needs approximately 144,000 bytes per second per channel, plus a small header.

The tool validates each temporary output before it publishes the file. The destination filesystem must support hard links.
Cancellation stops child processes and removes temporary files. Forced termination or power loss can leave temporary files.
Cancellation does not remove outputs that already completed.

## Tests

The latest local run passed **44 unit tests and 17 native integration tests**.
These results do not establish speech reduction or a general processing speed.

Run the unit tests.

```sh
swift test
```

After a release build, run the native integration tests.

```sh
python3 Integration/run.py --binary "$BIN" -v
```

Native integration tests create synthetic media. They require FFmpeg's `libx264` encoder, not personal videos.
[GitHub Actions](.github/workflows/ci.yml) runs unit tests, a release build, and a command help check on macOS 15.
Native integration tests are optional through **Actions → CI → Run workflow**.
Native model support on GitHub runners remains unverified.

## Further information

- [Implementation details](docs/IMPLEMENTATION.md): isolation, alignment, metadata, validation, and failure behavior.
- [Contribution guide](CONTRIBUTING.md): development and repository checks.
- [Audio-only test results](AUDIO_ONLY_TEST_RESULTS.md).
- [Large MOV test results](PRAGUE_TEST_RESULTS.md).
- [Initial benchmark results](TEST_RESULTS.md).
