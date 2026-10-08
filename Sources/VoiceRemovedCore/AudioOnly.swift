import Foundation

/// WAV time zero is the first frame of the first non-attached video stream.
/// Round duration and relative audio start independently to the nearest 48 kHz frame.
/// Half-frame ties round away from zero. No container duration participates.
struct AudioAlignment {
    let targetFrames: Int
    let offsetFrames: Int

    init(media: Media) throws {
        let audio = try media.validateInput()
        guard let video = media.mainVideo,
              let start = video.start, start.isFinite,
              let duration = video.length, duration.isFinite, duration > 0 else {
            throw Failure("--audio-only requires a finite main video start and positive finite main video duration")
        }
        targetFrames = try Self.frames(duration)
        offsetFrames = try Self.frames(audio.start! - start)
        guard targetFrames > 0 else { throw Failure("main video duration rounds to zero audio frames") }
    }

    static func frames(_ seconds: Double) throws -> Int {
        let rounded = (seconds * Double(sampleRate)).rounded(.toNearestOrAwayFromZero)
        // Strict bounds avoid trapping on conversion and allow safe negation of offsets.
        guard rounded.isFinite, rounded > Double(Int.min), rounded < Double(Int.max) else {
            throw Failure("audio alignment timestamp exceeds the supported sample range")
        }
        return Int(rounded)
    }
}

/// Validate WAV structure and timing. Return an exact count when ffprobe supplies ticks.
/// Missing tick fields require a bounded decode, not an estimate from decimal duration.
func validateWAV(_ output: Media, channels: Int, frameCount: Int) throws -> Int? {
    guard output.format?.format_name == "wav", output.streams.count == 1,
          let audio = output.audio.first, audio.codec_name == "pcm_s24le",
          audio.channels == channels, audio.sample_rate == "48000", audio.bits_per_sample == 24,
          let duration = audio.length, duration.isFinite, duration > 0,
          abs(duration - Double(frameCount) / Double(sampleRate)) <= 0.5 / Double(sampleRate) + 0.000001 else {
        throw Failure("validation failed: WAV must contain one aligned 48 kHz 24-bit PCM audio stream")
    }
    // WAV has no timestamp field. FFprobe normally omits start_time for WAV.
    if audio.start_time != nil {
        guard let start = audio.start, start.isFinite, start == 0 else {
            throw Failure("validation failed: WAV audio must start at zero")
        }
    }
    guard let ticks = audio.duration_ts, let base = audio.time_base else { return nil }
    let parts = base.split(separator: "/", omittingEmptySubsequences: false)
    guard ticks > 0, parts.count == 2,
          parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
          let numerator = Int64(parts[0]), numerator > 0,
          let denominator = Int64(parts[1]), denominator > 0 else {
        throw Failure("validation failed: invalid WAV duration ticks or time base")
    }
    let (scaledTicks, tickOverflow) = ticks.multipliedReportingOverflow(by: numerator)
    let (samples, sampleOverflow) = scaledTicks.multipliedReportingOverflow(by: Int64(sampleRate))
    guard !tickOverflow, !sampleOverflow, samples % denominator == 0,
          samples / denominator == Int64(frameCount) else {
        throw Failure("validation failed: WAV sample count differs from main video duration")
    }
    return frameCount
}

extension Tools {
    func validateWAVFile(_ url: URL, channels: Int, frameCount: Int, cancellation: Cancellation) throws {
        let output = try probe(url, cancellation)
        if try validateWAV(output, channels: channels, frameCount: frameCount) != nil { return }
        let decoder = try Child(executable: ffmpeg, arguments: [
            "-nostdin", "-hide_banner", "-v", "error", "-i", url.path,
            "-map", "0:a:0", "-c:a", "pcm_f32le", "-f", "f32le", "pipe:1"
        ], cancellation: cancellation, readOutput: true)
        defer { decoder.abort() }
        let source = PipePCM(decoder.output!, channels: channels, cancellation: cancellation)
        var count = 0
        while let data = try source.next() {
            count += data.count / (channels * 4)
            guard count <= frameCount else { throw Failure("validation failed: WAV has too many samples") }
        }
        try decoder.finish()
        guard count == frameCount else { throw Failure("validation failed: WAV has too few samples") }
    }
}
