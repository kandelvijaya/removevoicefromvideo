import Foundation

public struct Options {
    public var passes = 2
    public var jobs = 2
    public var faststart = false
    public var verify = false
    public var audioOnly = false
    public init() {}

    public func validate() throws {
        guard [1, 2].contains(passes) else { throw Failure("passes must be 1 or 2") }
        if audioOnly && verify { throw Failure("--verify checks copied video and cannot be combined with --audio-only; WAV validation is always enabled") }
        if audioOnly && faststart { throw Failure("--faststart applies to video containers and cannot be combined with --audio-only") }
    }
}

public final class Pipeline {
    private let tools: Tools
    private let cancellation: Cancellation
    public init(cancellation: Cancellation) throws {
        self.cancellation = cancellation
        tools = try Tools()
    }
    public func process(_ input: URL, options: Options) throws -> URL {
        try cancellation.check()
        try options.validate()
        let final = outputURL(for: input, audioOnly: options.audioOnly)
        // lstat-equivalent existence check includes dangling symlinks.
        if FileManager.default.fileExists(atPath: final.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: final.path)) != nil {
            throw Failure("output already exists: \(final.path)")
        }
        log("\(input.lastPathComponent): probe")
        let media = try tools.probe(input, cancellation)
        let audio = try media.validateInput()
        let channels = audio.channels!
        let alignment = options.audioOnly ? try AudioAlignment(media: media) : nil
        for stream in media.streams where !options.audioOnly && stream.codec_type == "data" {
            if stream.isTimecode {
                log("\(input.lastPathComponent): COPY supported tmcd timecode stream \(stream.index)")
            } else {
                log("\(input.lastPathComponent): DROP unsupported data stream \(stream.index) (\(stream.codec_name ?? "unknown")); unmapped data payload will not appear in output")
            }
        }
        let work = final.deletingLastPathComponent().appendingPathComponent(".voiceremoved-" + UUID().uuidString, isDirectory: true)
        let encoded = work.appendingPathComponent("audio.m4a")
        let temporary = work.appendingPathComponent("output." + (options.audioOnly ? "wav" : input.pathExtension))
        // WAV discards video/container metadata, so remux restrictions do not apply.
        let remux = options.audioOnly ? nil : try remuxArguments(input: input, audio: encoded, temporary: temporary, media: media, faststart: options.faststart)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: work) }
            catch { log("temporary cleanup failed for \(work.path): \(error)") }
        }
        log("\(input.lastPathComponent): stream audio through \(options.passes) isolation pass(es)")
        // Create and check all units before spawning the streaming child processes.
        let units = try (0..<options.passes).map { _ in try Isolation(channels: channels) }
        let decoder = try Child(executable: tools.ffmpeg, arguments: [
            "-nostdin", "-hide_banner", "-v", "warning", "-i", input.path,
            "-map", "0:\(audio.index)", "-vn", "-sn", "-dn", "-ar", "48000", "-ac", String(channels),
            "-c:a", "pcm_f32le", "-f", "f32le", "pipe:1"
        ], cancellation: cancellation, readOutput: true)
        defer { decoder.abort() }
        var encoderArguments = [
            "-nostdin", "-hide_banner", "-v", "warning", "-n", "-f", "f32le", "-ar", "48000", "-ac", String(channels),
            "-i", "pipe:0"
        ]
        if options.audioOnly {
            // Seekable temporary file permits header finalization and automatic RF64 above 4 GiB.
            encoderArguments += ["-map_metadata", "-1", "-c:a", "pcm_s24le", "-rf64", "auto", "-f", "wav", temporary.path]
        } else {
            encoderArguments += ["-c:a", "aac", "-b:a", channels == 1 ? "160k" : "320k", encoded.path]
        }
        let encoder = try Child(executable: tools.ffmpeg, arguments: encoderArguments,
                                cancellation: cancellation, writeInput: true)
        defer { encoder.abort() }
        var source: PCMSource = PipePCM(decoder.output!, channels: channels, cancellation: cancellation)
        var passes: [LatencyStream] = []
        for unit in units {
            let pass = LatencyStream(source: source, renderer: unit, cancellation: cancellation)
            passes.append(pass); source = pass
        }
        var aligned: AlignedPCM?
        if let alignment = alignment {
            let stream = AlignedPCM(source: source, channels: channels, targetFrames: alignment.targetFrames,
                                    offsetFrames: alignment.offsetFrames, cancellation: cancellation)
            aligned = stream; source = stream
            log("\(input.lastPathComponent): WAV target \(alignment.targetFrames) frames; audio offset \(alignment.offsetFrames) frames")
        }
        var frames = 0
        var nextProgress = sampleRate * 30
        while let data = try source.next() {
            try cancellation.check()
            do { try encoder.input!.write(contentsOf: data) }
            catch {
                // Broken pipes usually mean an encoder error. Drain and report that error.
                try? encoder.input!.close()
                decoder.abort()
                do { try encoder.finish() } catch let processError { throw processError }
                throw Failure("\(options.audioOnly ? "WAV" : "AAC") input pipe write failed: \(error)")
            }
            frames += data.count / (channels * 4)
            if frames >= nextProgress {
                log("\(input.lastPathComponent): processed \(frames / sampleRate) seconds of audio")
                nextProgress += sampleRate * 30
            }
        }
        try decoder.finish()
        let decodedFrames = passes.last!.outputFrames
        guard decodedFrames > 0,
              passes.allSatisfy({ $0.inputFrames == decodedFrames && $0.outputFrames == decodedFrames }) else {
            throw Failure("isolation frame-count mismatch or empty decoded audio")
        }
        if let aligned = aligned, let alignment = alignment {
            guard aligned.inputFrames == decodedFrames, aligned.outputFrames == alignment.targetFrames,
                  frames == alignment.targetFrames else { throw Failure("audio alignment frame-count mismatch") }
        } else if frames != decodedFrames { throw Failure("isolation output frame-count mismatch") }
        try encoder.input!.close()
        try encoder.finish()
        if let duration = audio.length, abs(duration - Double(decodedFrames) / Double(sampleRate)) > 0.1 {
            throw Failure("decoded audio duration differs from source by more than 100 ms")
        }
        if options.audioOnly {
            log("\(input.lastPathComponent): validate 24-bit PCM WAV; decoded \(decodedFrames), aligned \(frames) frames")
            try tools.validateWAVFile(temporary, channels: channels, frameCount: frames, cancellation: cancellation)
        } else {
            log("\(input.lastPathComponent): remux copied video; audio \(frames) frames")
            try tools.run(remux!, cancellation)
            let output = try tools.probe(temporary, cancellation)
            try validateOutput(source: media, output: output, frameCount: frames)
            if options.verify {
                log("\(input.lastPathComponent): verify SHA-256 of every copied video and timecode packet payload")
                for (original, result) in zip(media.retained, output.retained) where original.codec_type == "video" || original.isTimecode {
                    let before = try tools.packetHash(input, index: original.index, cancellation)
                    let after = try tools.packetHash(temporary, index: result.index, cancellation)
                    guard before == after else { throw Failure("copied packet hash mismatch for stream \(original.index)") }
                }
            }
        }
        try cancellation.whileActive { try publish(temporary, to: final) }
        log("\(input.lastPathComponent): complete")
        return final
    }
}

public func inputs(at url: URL) throws -> [URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw Failure("input does not exist: \(url.path)") }
    if !isDirectory.boolValue {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure("input is not a regular file") }
        guard !url.deletingPathExtension().lastPathComponent.lowercased().hasSuffix("_voiceremoved") else { throw Failure("generated output is not an input") }
        return [url]
    }
    let extensions = Set(["mp4", "mov", "m4v", "mkv", "avi", "webm"])
    let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
    let selected = try contents.filter { item in
        let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true && extensions.contains(item.pathExtension.lowercased()) &&
            !item.deletingPathExtension().lastPathComponent.lowercased().hasSuffix("_voiceremoved")
    }.sorted { $0.path < $1.path }
    guard !selected.isEmpty else { throw Failure("folder contains no supported input videos (nonrecursive)") }
    return selected
}
