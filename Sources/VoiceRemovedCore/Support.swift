import Foundation
import Darwin

public struct Failure: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

public func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// One shared cancellation scope owns every child, including folder workers.
public final class Cancellation {
    private let lock = NSLock()
    private var stopped = false
    private var children: [UUID: Process] = [:]
    private var signals: [DispatchSourceSignal] = []
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public func check() throws { if isCancelled { throw Failure("cancelled") } }
    /// Only use this for short operations. Publication and cancellation share one boundary.
    func whileActive(_ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw Failure("cancelled") }
        try action()
    }
    public func installSignals() {
        signal(SIGPIPE, SIG_IGN)
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.cancel() }
            source.resume()
            signals.append(source)
        }
    }
    // Start and registration share the lock so cancellation cannot miss a new child.
    func start(_ process: Process, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if stopped { throw Failure("cancelled") }
        try process.run()
        children[id] = process
    }
    func remove(_ id: UUID) { lock.lock(); children.removeValue(forKey: id); lock.unlock() }
    public func cancel() {
        lock.lock()
        stopped = true
        let active = Array(children.values)
        lock.unlock()
        for child in active { Self.stop(child) }
    }
    static func stop(_ child: Process) {
        if child.isRunning { child.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
}

/// stderr is always drained. Only the last 64 KiB stays in memory.
final class Child {
    private let process = Process()
    private let id = UUID()
    private let cancellation: Cancellation
    private let errorPipe = Pipe()
    private let drain = DispatchGroup()
    private let lock = NSLock()
    private var diagnostics = Data()
    private var finished = false
    let output: FileHandle?
    let input: FileHandle?

    init(executable: URL, arguments: [String], cancellation: Cancellation,
         readOutput: Bool = false, writeInput: Bool = false) throws {
        self.cancellation = cancellation
        process.executableURL = executable
        process.arguments = arguments
        process.standardError = errorPipe
        let outPipe = readOutput ? Pipe() : nil
        let inPipe = writeInput ? Pipe() : nil
        output = outPipe?.fileHandleForReading
        input = inPipe?.fileHandleForWriting
        process.standardOutput = outPipe ?? FileHandle.nullDevice as Any
        process.standardInput = inPipe ?? FileHandle.nullDevice as Any
        try cancellation.start(process, id: id)
        // Close the parent's copies of the child's pipe ends.
        try outPipe?.fileHandleForWriting.close()
        try inPipe?.fileHandleForReading.close()
        try errorPipe.fileHandleForWriting.close()
        drain.enter()
        DispatchQueue.global().async { [self] in
            defer { drain.leave() }
            while let data = try? errorPipe.fileHandleForReading.read(upToCount: 8192), !data.isEmpty {
                lock.lock()
                diagnostics.append(data)
                if diagnostics.count > 65536 { diagnostics.removeFirst(diagnostics.count - 65536) }
                lock.unlock()
            }
        }
    }
    func finish() throws {
        guard !finished else { return }
        process.waitUntilExit()
        drain.wait()
        finished = true
        cancellation.remove(id)
        try cancellation.check()
        lock.lock(); let text = String(decoding: diagnostics, as: UTF8.self); lock.unlock()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure("\(process.executableURL!.lastPathComponent) failed (\(process.terminationStatus)): \(text)")
        }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { log(text) }
    }
    func abort() {
        guard !finished else { return }
        Cancellation.stop(process)
        try? input?.close()
        try? output?.close()
        process.waitUntilExit()
        drain.wait()
        cancellation.remove(id)
        finished = true
    }
    deinit { abort() }
}

struct Tools {
    let ffmpeg: URL
    let ffprobe: URL
    init() throws {
        func locate(_ name: String) throws -> URL {
            let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            for dir in ["/opt/homebrew/bin", "/usr/local/bin"] + dirs {
                let path = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: path.path) { return path }
            }
            throw Failure("\(name) not found. Install FFmpeg: brew install ffmpeg")
        }
        ffmpeg = try locate("ffmpeg"); ffprobe = try locate("ffprobe")
    }
    func capture(_ executable: URL, _ args: [String], _ cancellation: Cancellation, limit: Int = 8 * 1024 * 1024) throws -> Data {
        let child = try Child(executable: executable, arguments: args, cancellation: cancellation, readOutput: true)
        defer { child.abort() }
        var result = Data()
        while let data = try child.output!.read(upToCount: 8192), !data.isEmpty {
            try cancellation.check()
            guard result.count + data.count <= limit else { throw Failure("tool output exceeds safe metadata limit") }
            result.append(data)
        }
        try child.finish()
        return result
    }
    func run(_ args: [String], _ cancellation: Cancellation) throws {
        let child = try Child(executable: ffmpeg, arguments: args, cancellation: cancellation)
        defer { child.abort() }
        try child.finish()
    }
}

public func outputURL(for input: URL, audioOnly: Bool = false) -> URL {
    let stem = input.deletingPathExtension().lastPathComponent
    let ext = audioOnly ? "wav" : input.pathExtension
    return input.deletingLastPathComponent().appendingPathComponent(stem + "_voiceremoved" + (ext.isEmpty ? "" : "." + ext))
}

/// Atomic, same-filesystem publication. link() never replaces an existing path.
public func publish(_ temporary: URL, to final: URL) throws {
    guard link(temporary.path, final.path) == 0 else {
        throw Failure("cannot publish \(final.path): \(String(cString: strerror(errno)))")
    }
}
