import XCTest
import Foundation
@testable import VoiceRemovedCore

private final class Chunks: PCMSource {
    var bytes: Data
    let channels: Int
    var sizes: [Int]
    var index = 0
    init(_ bytes: Data, channels: Int, sizes: [Int]) {
        self.bytes = bytes; self.channels = channels; self.sizes = sizes
    }
    func next() throws -> Data? {
        guard !bytes.isEmpty else { return nil }
        let count = min(bytes.count, sizes[index % sizes.count] * channels * 4)
        index += 1
        let result = Data(bytes.prefix(count)); bytes.removeFirst(count)
        return result
    }
}

/// A deterministic sample delay stands in for the opaque, nondeterministic Apple model.
private final class Delay: BlockRenderer {
    let channels: Int
    let latencyFrames: Int
    var history: Data
    var calls = 0
    init(channels: Int, latency: Int) {
        self.channels = channels; latencyFrames = latency
        history = Data(count: channels * latency * 4)
    }
    func render(_ padded: Data) throws -> Data {
        XCTAssertEqual(padded.count, 4096 * channels * 4)
        calls += 1
        history.append(padded)
        let result = Data(history.prefix(padded.count))
        history.removeFirst(padded.count)
        return result
    }
}

final class StreamingTests: XCTestCase {
    func testInitialLatencyDiscardAndExactTailForOneAndTwoPasses() throws {
        for channels in [1, 2] {
            for frames in [0, 1, 4095, 4096, 4097, 8192, 10001] {
                for latency in [0, 1, 4095, 4096, 6360, 8193] {
                    for passCount in [1, 2] {
                        // Distinct L/R samples catch accidental channel collapse.
                        let samples = (0..<(frames * channels)).map { Float($0 + 1) / 100000 }
                        let expected = samples.withUnsafeBytes { Data($0) }
                        var source: PCMSource = Chunks(expected, channels: channels, sizes: [1, 13, 4096, 37])
                        var passes: [LatencyStream] = []
                        for _ in 0..<passCount {
                            let renderer = Delay(channels: channels, latency: latency)
                            let stream = LatencyStream(source: source, renderer: renderer, cancellation: Cancellation())
                            passes.append(stream); source = stream
                        }
                        var actual = Data()
                        while let part = try source.next() {
                            XCTAssertLessThanOrEqual(part.count, 4096 * channels * 4)
                            actual.append(part)
                        }
                        XCTAssertEqual(actual, expected, "channels=\(channels) frames=\(frames) latency=\(latency) passes=\(passCount)")
                        for pass in passes {
                            XCTAssertEqual(pass.inputFrames, frames)
                            XCTAssertEqual(pass.outputFrames, frames)
                        }
                        XCTAssertNil(try source.next())
                    }
                }
            }
        }
    }
    func testPipeCoalescesArbitraryPartialByteReads() throws {
        let pipe = Pipe()
        let expected = Data((0..<40004).map { UInt8($0 % 251) }) // 10001 mono frames
        let writer = DispatchGroup()
        writer.enter()
        DispatchQueue.global().async {
            defer { try? pipe.fileHandleForWriting.close(); writer.leave() }
            var offset = 0
            while offset < expected.count {
                let take = min(7, expected.count - offset)
                try? pipe.fileHandleForWriting.write(contentsOf: expected.subdata(in: offset..<(offset + take)))
                offset += take
            }
        }
        let source = PipePCM(pipe.fileHandleForReading, channels: 1, cancellation: Cancellation())
        var actual = Data()
        while let part = try source.next() { actual.append(part) }
        writer.wait()
        XCTAssertEqual(actual, expected)
        try pipe.fileHandleForReading.close()
    }
    func testTruncatedPCMFrameFails() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data([1, 2, 3]))
        try pipe.fileHandleForWriting.close()
        let source = PipePCM(pipe.fileHandleForReading, channels: 2, cancellation: Cancellation())
        XCTAssertThrowsError(try source.next())
        try pipe.fileHandleForReading.close()
    }
    func testCancellationStopsBeforeRendering() throws {
        let cancel = Cancellation()
        cancel.cancel()
        let renderer = Delay(channels: 1, latency: 6360)
        let source = Chunks(Data(count: 4), channels: 1, sizes: [1])
        let stream = LatencyStream(source: source, renderer: renderer, cancellation: cancel)
        XCTAssertThrowsError(try stream.next())
        XCTAssertEqual(renderer.calls, 0)
    }
}
