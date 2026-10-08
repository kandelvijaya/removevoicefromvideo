import Foundation
import VoiceRemovedCore
import Darwin

let usage = """
Usage: voice-remove <video-or-folder> [--passes 1|2] [--jobs 1..8] [--faststart] [--verify]

Suppress conversation with Apple AUSoundIsolation. Requires macOS 15 or later.
Output: <stem>_voiceremoved.<original extension>, beside the input. Never overwrites.
Folders are nonrecursive. Default: two passes, two concurrent folder jobs.
--passes 1   Use one isolation unit instead of two.
--jobs N     Limit concurrent folder jobs (default 2, maximum 8).
--faststart  Rewrite MP4/MOV/M4V headers for progressive playback; extra disk work.
--verify     Compare SHA-256 hashes of every copied video stream (extra full reads).
--help       Show this help.
Successful output paths go to stdout. Progress and errors go to stderr.
"""

func parse(_ arguments: [String]) throws -> (URL, Options) {
    var options = Options()
    var path: String?
    var index = 0
    var positional = false
    while index < arguments.count {
        let arg = arguments[index]
        if !positional && arg == "--" { positional = true; index += 1; continue }
        if !positional && ["--passes", "--jobs"].contains(arg) {
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]) else { throw Failure("\(arg) needs an integer") }
            if arg == "--passes" {
                guard [1, 2].contains(value) else { throw Failure("--passes must be 1 or 2") }
                options.passes = value
            } else {
                guard (1...8).contains(value) else { throw Failure("--jobs must be 1 through 8") }
                options.jobs = value
            }
        } else if !positional && arg == "--faststart" { options.faststart = true }
        else if !positional && arg == "--verify" { options.verify = true }
        else {
            guard positional || !arg.hasPrefix("-") else { throw Failure("unknown option: \(arg)") }
            guard path == nil else { throw Failure("give exactly one video or folder") }
            path = arg
        }
        index += 1
    }
    guard let path = path else { throw Failure("give one video or folder; use --help") }
    return (URL(fileURLWithPath: path).standardizedFileURL, options)
}

let cancellation = Cancellation()
cancellation.installSignals()
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] {
        FileHandle.standardOutput.write(Data((usage + "\n").utf8))
        exit(0)
    }
    guard #available(macOS 15, *) else { throw Failure("macOS 15 or later is required for HQ conversation suppression") }
    let (location, options) = try parse(arguments)
    let videos = try inputs(at: location)
    let pipeline = try Pipeline(cancellation: cancellation)
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = options.jobs
    let lock = NSLock()
    var failures = 0
    let start = Date()
    for video in videos {
        queue.addOperation {
            do {
                let output = try pipeline.process(video, options: options)
                lock.lock()
                FileHandle.standardOutput.write(Data((output.path + "\n").utf8))
                lock.unlock()
            } catch {
                lock.lock(); failures += 1; lock.unlock()
                log("\(video.lastPathComponent): error: \(error)")
            }
        }
    }
    queue.waitUntilAllOperationsAreFinished()
    log(String(format: "Finished %d input(s) in %.2f seconds; %d failure(s)", videos.count, Date().timeIntervalSince(start), failures))
    if cancellation.isCancelled { exit(130) }
    exit(failures == 0 ? 0 : 1)
} catch {
    log("voice-remove: error: \(error)")
    exit(cancellation.isCancelled ? 130 : 1)
}
