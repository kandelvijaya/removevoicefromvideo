# Audio-only validation

Run date: 2026-10-08. Production implementation: `b676725`.

- Release build passed.
- `swift test`: 44 tests passed, zero failures.
- `python3 Integration/run.py --binary "$BIN" -v`: 17 tests passed, zero failures, 21.093 seconds.
- Independent source review found no implementation blockers. The integration helper now rounds signed offsets consistently with production.

## Requested DJI sample

Command: `voice-remove DJI_20261004115510_0052_D.MP4 --audio-only`.

- Two isolation passes; each reports 6360 latency frames.
- Wall time: 4.57 seconds (`/usr/bin/time -p`).
- Output: `DJI_20261004115510_0052_D_voiceremoved.wav`, beside the original.
- Format: 48 kHz, stereo, 24-bit PCM (`pcm_s24le`).
- Main video duration and WAV duration: 73.780000 seconds.
- Decoded source audio: 3,546,112 frames. Aligned WAV: 3,541,440 frames.
- WAV size: 21,248,778 bytes.
- Output validation confirmed exact sample count through ffprobe duration ticks.
- Input SHA-256 after processing: `99bc7a1f67e5e1c68c82bb4d88a60ac4deb6b6d5489b70bc54e311c5713b0f67`.
  This equals the previously recorded project sample hash. No separate pre-run hash was recorded for this input path.

Integration coverage includes mono/stereo, nonzero video starts, leading/trailing silence, trimming, upstream drain, folder collisions, no overwrite, and incompatible flags. Existing video-mode regression tests also passed.

The uploaded `Day 2 Prague_voiceremoved.mov` was not accessed or modified during this work.
Human listening and DaVinci Resolve import were not performed. RF64 interoperability remains unverified.
