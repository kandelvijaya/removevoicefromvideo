import Foundation

struct Media: Decodable {
    struct Stream: Decodable {
        let index: Int
        let codec_type: String?
        let codec_name: String?
        let codec_tag_string: String?
        let time_base: String?
        let nb_frames: String?
        let channels: Int?
        let sample_rate: String?
        let start_time: String?
        let duration: String?
        let width: Int?
        let height: Int?
        let tags: [String: String]?
        let disposition: [String: Int]?
        let side_data_list: [SideData]?
        var start: Double? { start_time.flatMap(Double.init) }
        var length: Double? {
            if let value = duration.flatMap(Double.init) { return value }
            // Matroska writes an endpoint timestamp instead of stream.duration.
            if let value = tags?.first(where: { $0.key.lowercased() == "duration" })?.value {
                let pieces = value.split(separator: ":").compactMap { Double($0) }
                if pieces.count == 3 { return pieces[0] * 3600 + pieces[1] * 60 + pieces[2] - (start ?? 0) }
            }
            return nil
        }
        var rotation: Int? { side_data_list?.compactMap(\.rotation).first }
        // ffprobe can omit codec_name for a valid MOV timecode track.
        var isTimecode: Bool { codec_type == "data" && codec_tag_string == "tmcd" }
        var hasValidTimecodeTiming: Bool {
            guard let start = start, start.isFinite,
                  let duration = length, duration.isFinite, duration > 0,
                  let timeBase = time_base else { return false }
            let parts = timeBase.split(separator: "/", omittingEmptySubsequences: false)
            // FFmpeg uses signed 32-bit AVRational components and a signed 64-bit frame count.
            return parts.count == 2 && parts.allSatisfy {
                isPositiveTimecodeInteger(String($0), maximum: Int64(Int32.max))
            } && isPositiveTimecodeInteger(nb_frames)
        }
    }
    struct SideData: Decodable { let rotation: Int? }
    struct Chapter: Decodable {
        let start_time: String
        let end_time: String
        let tags: [String: String]?
    }
    struct Format: Decodable { let tags: [String: String]? }
    let streams: [Stream]
    let chapters: [Chapter]?
    let format: Format?

    var audio: [Stream] { streams.filter { $0.codec_type == "audio" } }
    var retained: [Stream] { streams.filter { ["video", "audio", "subtitle"].contains($0.codec_type ?? "") || $0.isTimecode } }
    func validateInput() throws -> Stream {
        guard audio.count == 1 else { throw Failure("expected one audio track, found \(audio.count); no-audio and multi-audio inputs are unsupported") }
        guard let channels = audio[0].channels, channels == 1 || channels == 2 else {
            throw Failure("unsupported audio channel count: \(audio[0].channels ?? 0); only mono and stereo are supported")
        }
        guard streams.contains(where: { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }) else {
            throw Failure("input has no main video stream")
        }
        guard let start = audio[0].start, start.isFinite else { throw Failure("audio start timestamp is missing or invalid") }
        for stream in streams where !["video", "audio", "subtitle", "data"].contains(stream.codec_type ?? "") {
            throw Failure("unsupported stream \(stream.index): \(stream.codec_type ?? "unknown")")
        }
        return audio[0]
    }
}

/// Require decimal digits only; reject signs, whitespace, placeholders, and overflow.
private func isPositiveTimecodeInteger(_ text: String?, maximum: Int64 = Int64.max) -> Bool {
    guard let text = text, !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
          let value = Int64(text), value > 0, value <= maximum else { return false }
    return true
}

extension Tools {
    func probe(_ url: URL, _ cancellation: Cancellation) throws -> Media {
        let data = try capture(ffprobe, ["-v", "error", "-show_streams", "-show_chapters", "-show_format", "-of", "json", url.path], cancellation)
        do { return try JSONDecoder().decode(Media.self, from: data) }
        catch { throw Failure("invalid ffprobe JSON for \(url.lastPathComponent): \(error)") }
    }
    func packetHash(_ url: URL, index: Int, _ cancellation: Cancellation) throws -> Data {
        try capture(ffmpeg, ["-nostdin", "-hide_banner", "-v", "error", "-i", url.path, "-map", "0:\(index)",
                            "-c", "copy", "-f", "hash", "-hash", "sha256", "pipe:1"], cancellation, limit: 4096)
    }
}

func remuxArguments(input: URL, audio: URL, temporary: URL, media: Media, faststart: Bool) throws -> [String] {
    let sourceAudio = try media.validateInput()
    let containerArguments = try remuxContainerArguments(input: input, media: media, faststart: faststart)
    // Processed AAC starts at zero. Restore the original audio timestamp, including negative starts.
    var args = ["-nostdin", "-hide_banner", "-v", "warning", "-n", "-copyts", "-i", input.path,
                "-itsoffset", String(sourceAudio.start!), "-i", audio.path]
    for stream in media.retained {
        args += ["-map", stream.codec_type == "audio" ? "1:a:0" : "0:\(stream.index)"]
    }
    args += ["-c", "copy", "-c:v", "copy", "-map_metadata:g", "0:g", "-map_chapters", "0", "-avoid_negative_ts", "disabled"]
    for (index, stream) in media.retained.enumerated() {
        args += ["-map_metadata:s:\(index)", "0:s:\(stream.index)"]
        let flags = (stream.disposition ?? [:]).filter { $0.value != 0 }.map(\.key).sorted().joined(separator: "+")
        args += ["-disposition:\(index)", flags.isEmpty ? "0" : flags]
    }
    args += containerArguments
    args.append(temporary.path)
    return args
}

/// Call before isolation or audio decoding, not just at final remux time.
func remuxContainerArguments(input: URL, media: Media, faststart: Bool) throws -> [String] {
    let ext = input.pathExtension.lowercased()
    let isMOVFamily = ["mp4", "mov", "m4v"].contains(ext)
    if faststart && !isMOVFamily { throw Failure("--faststart only supports MP4, MOV, and M4V") }
    let timecodes = media.streams.filter(\.isTimecode)
    if !timecodes.isEmpty {
        // MOV's codec table supports copied tmcd (AV_CODEC_ID_NONE); MP4/M4V tables do not.
        // Automatic timecode generation uses a separate muxer path and is disabled below.
        guard ext == "mov" else { throw Failure("copied tmcd timecode tracks require MOV; MP4, M4V, and other containers are unsupported") }
        for stream in timecodes {
            guard stream.hasValidTimecodeTiming,
                  let value = stream.tags?["timecode"], !value.isEmpty else {
                throw Failure("timecode stream \(stream.index) lacks valid timing, a positive rational time base, a positive frame count, or timecode metadata")
            }
        }
    }
    guard isMOVFamily else { return [] }
    // Only copy explicitly mapped tmcd tracks. Never synthesize an unrequested track
    // from a video's timecode tag (which otherwise bypasses our stream mapping).
    let timecodeArguments = ["-write_tmcd", "0"]
    let hasPicture = media.streams.contains { $0.disposition?["attached_pic"] == 1 }
    if hasPicture {
        // FFmpeg's MOV udta path writes neither covr nor iTunes metadata.
        guard ext != "mov" else { throw Failure("attached pictures in MOV are unsupported by the FFmpeg MOV muxer") }
        try validateCoverFileMetadata(media.format?.tags)
        // use_metadata_tags selects mdta and bypasses covr. Keep the iTunes path.
        return timecodeArguments + (faststart ? ["-movflags", "+faststart"] : [])
    }
    // No cover art: mdta can retain arbitrary file-level keys.
    return timecodeArguments + ["-movflags", faststart ? "+use_metadata_tags+faststart" : "+use_metadata_tags"]
}

func validateOutput(source: Media, output: Media, frameCount: Int) throws {
    let originals = source.retained
    guard output.retained.count == originals.count else { throw Failure("validation failed: stream count changed") }
    // The MOV muxer can synthesize a chapter data track. It is not camera telemetry.
    let additional = output.streams.filter { !["video", "audio", "subtitle"].contains($0.codec_type ?? "") && !$0.isTimecode }
    guard additional.allSatisfy({ $0.codec_type == "data" && $0.codec_name == "bin_data" && !(source.chapters ?? []).isEmpty }) else {
        throw Failure("validation failed: unexpected extra output stream")
    }
    let tolerance = 0.05 // AAC frame rounding and container time-base precision.
    for (before, after) in zip(originals, output.retained) {
        guard before.codec_type == after.codec_type else { throw Failure("validation failed: stream order changed") }
        if before.isTimecode {
            guard after.isTimecode, before.codec_name == after.codec_name,
                  before.hasValidTimecodeTiming, after.hasValidTimecodeTiming,
                  before.time_base == after.time_base, before.nb_frames == after.nb_frames,
                  let start = before.start, let resultStart = after.start,
                  let duration = before.length, let resultDuration = after.length,
                  abs(start - resultStart) <= 0.001, abs(duration - resultDuration) <= 0.001 else {
                throw Failure("validation failed: copied timecode track format or timing changed")
            }
            try validateTimecodeTags(before.tags, after.tags, context: "timecode stream \(before.index)")
        } else if before.codec_type != "audio" {
            guard before.codec_name == after.codec_name, before.width == after.width, before.height == after.height else {
                throw Failure("validation failed: copied stream format changed")
            }
            if before.disposition?["attached_pic"] != 1 {
                if let a = before.start {
                    guard let b = after.start, abs(a - b) <= tolerance else {
                        throw Failure("validation failed: copied stream start changed")
                    }
                }
                if let a = before.length {
                    guard let b = after.length, abs(a - b) <= tolerance else {
                        throw Failure("validation failed: copied stream duration changed")
                    }
                }
            }
        } else {
            guard after.codec_name == "aac", before.channels == after.channels, after.sample_rate == "48000",
                  let start = after.start, let originalStart = before.start, abs(start - originalStart) <= tolerance,
                  let duration = after.length, abs(duration - Double(frameCount) / Double(sampleRate)) <= tolerance else {
                throw Failure("validation failed: AAC format, start, or duration changed")
            }
        }
        guard before.rotation == after.rotation else { throw Failure("validation failed: video rotation changed") }
        let beforeFlags = (before.disposition ?? [:]).filter { $0.value != 0 }
        let afterFlags = (after.disposition ?? [:]).filter { $0.value != 0 }
        guard beforeFlags == afterFlags else { throw Failure("validation failed: stream dispositions changed") }
        if let language = before.tags?["language"], language != after.tags?["language"] {
            throw Failure("validation failed: stream language changed")
        }
        try validateTags(before.tags, after.tags, context: "stream \(before.index)")
    }
    try validateTags(source.format?.tags, output.format?.tags, context: "file")
    let beforeChapters = source.chapters ?? []
    let afterChapters = output.chapters ?? []
    guard beforeChapters.count == afterChapters.count else { throw Failure("validation failed: chapter count changed") }
    for (a, b) in zip(beforeChapters, afterChapters) {
        guard let startA = Double(a.start_time), let startB = Double(b.start_time),
              let endA = Double(a.end_time), let endB = Double(b.end_time),
              abs(startA - startB) <= tolerance, abs(endA - endB) <= tolerance, a.tags == b.tags else {
            throw Failure("validation failed: chapter timing or metadata changed")
        }
    }
}
