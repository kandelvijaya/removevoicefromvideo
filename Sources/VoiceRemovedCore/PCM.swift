import Foundation

let blockFrames = 4096
let sampleRate = 48000

/// Sources return interleaved Float32 bytes. nil means end of stream, not a short read.
protocol PCMSource: AnyObject {
    func next() throws -> Data?
}
protocol BlockRenderer: AnyObject {
    var channels: Int { get }
    var latencyFrames: Int { get }
    /// Always supplies and renders exactly 4096 frames, including tail zeros.
    func render(_ padded: Data) throws -> Data
}

/// Coalesces partial byte reads without dropping bytes at pipe boundaries.
final class PipePCM: PCMSource {
    let handle: FileHandle
    let channels: Int
    let cancellation: Cancellation
    init(_ handle: FileHandle, channels: Int, cancellation: Cancellation) {
        self.handle = handle; self.channels = channels; self.cancellation = cancellation
    }
    func next() throws -> Data? {
        let capacity = blockFrames * channels * 4
        var data = Data()
        while data.count < capacity {
            try cancellation.check()
            guard let part = try handle.read(upToCount: capacity - data.count), !part.isEmpty else { break }
            data.append(part)
        }
        guard data.count % (channels * 4) == 0 else { throw Failure("decoder returned an incomplete PCM frame") }
        return data.isEmpty ? nil : data
    }
}

/// Aligns corrected audio to a video interval without changing per-pass frame accounting.
/// The final next() drains all upstream frames, even if the target ended before audio.
final class AlignedPCM: PCMSource {
    private let source: PCMSource
    private let channels: Int
    private let targetFrames: Int
    private let cancellation: Cancellation
    private var silenceFrames: Int
    private var skipFrames: Int
    private var carry = Data()
    private var eof = false
    private(set) var inputFrames = 0
    private(set) var outputFrames = 0

    init(source: PCMSource, channels: Int, targetFrames: Int, offsetFrames: Int, cancellation: Cancellation) {
        self.source = source; self.channels = channels; self.targetFrames = targetFrames
        self.cancellation = cancellation
        silenceFrames = min(targetFrames, max(0, offsetFrames))
        skipFrames = max(0, -offsetFrames)
    }

    private func read() throws -> Data? {
        try cancellation.check()
        guard let data = try source.next() else { eof = true; return nil }
        guard !data.isEmpty, data.count <= blockFrames * channels * 4, data.count % (channels * 4) == 0 else {
            throw Failure("invalid upstream PCM alignment block")
        }
        inputFrames += data.count / (channels * 4)
        return data
    }

    func next() throws -> Data? {
        try cancellation.check()
        if outputFrames == targetFrames {
            carry.removeAll(keepingCapacity: false)
            while !eof { _ = try read() }
            return nil
        }
        let stride = channels * 4
        let capacity = min(blockFrames, targetFrames - outputFrames) * stride
        var result = Data()
        let silence = min(silenceFrames, capacity / stride)
        result.append(Data(count: silence * stride))
        silenceFrames -= silence
        while result.count < capacity {
            if carry.isEmpty && !eof { carry = try read() ?? Data() }
            if !carry.isEmpty {
                let skip = min(skipFrames, carry.count / stride)
                carry.removeFirst(skip * stride); skipFrames -= skip
                let take = min(capacity - result.count, carry.count)
                result.append(carry.prefix(take)); carry.removeFirst(take)
            } else if eof {
                result.append(Data(count: capacity - result.count))
            }
        }
        outputFrames += result.count / stride
        return result
    }
}

/// Discards INITIAL latency, then emits exactly the number of source frames.
/// Each pass owns its own length accounting and zero-padded tail flush.
final class LatencyStream: PCMSource {
    private let source: PCMSource
    private let renderer: BlockRenderer
    private let cancellation: Cancellation
    private var carry = Data()
    private var eof = false
    private var rendered = 0
    private(set) var inputFrames = 0
    private(set) var outputFrames = 0
    init(source: PCMSource, renderer: BlockRenderer, cancellation: Cancellation) {
        self.source = source; self.renderer = renderer; self.cancellation = cancellation
    }
    func next() throws -> Data? {
        let stride = renderer.channels * 4
        let capacity = blockFrames * stride
        while true {
            try cancellation.check()
            if eof && outputFrames == inputFrames { return nil }
            var block = Data()
            while block.count < capacity {
                if !carry.isEmpty {
                    let take = min(capacity - block.count, carry.count)
                    block.append(carry.prefix(take)); carry.removeFirst(take)
                } else if eof { break }
                else if let part = try source.next() {
                    guard !part.isEmpty, part.count <= capacity, part.count % stride == 0 else {
                        throw Failure("invalid upstream PCM block")
                    }
                    carry = part
                    inputFrames += part.count / stride
                } else { eof = true }
            }
            if eof && outputFrames == inputFrames { return nil }
            block.append(Data(count: capacity - block.count))
            let result = try renderer.render(block)
            guard result.count == capacity else { throw Failure("renderer returned an invalid block") }
            let skip = min(blockFrames, max(0, renderer.latencyFrames - rendered))
            rendered += blockFrames
            let count = min(blockFrames - skip, inputFrames - outputFrames)
            if count > 0 {
                outputFrames += count
                return result.subdata(in: (skip * stride)..<((skip + count) * stride))
            }
        }
    }
}
