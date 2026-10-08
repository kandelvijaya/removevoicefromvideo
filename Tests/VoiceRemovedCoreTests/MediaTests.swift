import XCTest
import Foundation
@testable import VoiceRemovedCore

final class MediaTests: XCTestCase {
    let fixture = """
    {"streams":[
      {"index":0,"codec_type":"video","codec_name":"h264","width":128,"height":72,
       "start_time":"0.000","duration":"2.000","disposition":{"default":1},"tags":{"language":"eng"}},
      {"index":1,"codec_type":"audio","codec_name":"aac","channels":2,"sample_rate":"48000",
       "start_time":"1.250","duration":"2.100","disposition":{"default":1},"tags":{"language":"deu"}},
      {"index":2,"codec_type":"data","codec_name":"djmd"},
      {"index":3,"codec_type":"video","codec_name":"mjpeg","width":64,"height":64,"disposition":{"attached_pic":1}}
    ],"chapters":[],"format":{"tags":{"title":"Original title"}}}
    """
    func decode(_ json: String) throws -> Media { try JSONDecoder().decode(Media.self, from: Data(json.utf8)) }
    func testRemuxRestoresStartAndPreservesAllVideoMaps() throws {
        let media = try decode(fixture)
        let arguments = try remuxArguments(input: URL(fileURLWithPath: "/clip.MP4"),
            audio: URL(fileURLWithPath: "/audio.m4a"), temporary: URL(fileURLWithPath: "/temp.MP4"), media: media, faststart: false)
        XCTAssertTrue(arguments.contains("0:0"))
        XCTAssertTrue(arguments.contains("0:3"))
        XCTAssertTrue(arguments.contains("1:a:0"))
        XCTAssertFalse(arguments.contains("0:2"))
        XCTAssertFalse(arguments.contains("-shortest"))
        XCTAssertFalse(arguments.contains("+faststart"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-itsoffset")! + 1], "1.25")
        XCTAssertTrue(arguments.contains("attached_pic"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-c:v")! + 1], "copy")
    }
    func testUnsupportedTrackCountsAndChannelsFail() throws {
        XCTAssertThrowsError(try decode("{\"streams\":[]}").validateInput())
        XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: "\"channels\":2", with: "\"channels\":6")).validateInput())
        let multi = "{\"streams\":[{\"index\":0,\"codec_type\":\"audio\"},{\"index\":1,\"codec_type\":\"audio\"}]}"
        XCTAssertThrowsError(try decode(multi).validateInput())
    }
    func testMissingAudioStartFails() throws {
        let media = try decode(fixture.replacingOccurrences(of: "\"start_time\":\"1.250\",", with: ""))
        XCTAssertThrowsError(try media.validateInput())
    }
    func testMatroskaDurationEndpoint() throws {
        let media = try decode("""
        {"streams":[{"index":0,"start_time":"1.250","tags":{"DURATION":"00:00:03.350"}}]}
        """)
        XCTAssertEqual(media.streams[0].length!, 2.1, accuracy: 0.000001)
    }
    func testLostMetadataFails() throws {
        XCTAssertThrowsError(try validateTags(["title": "Keep me"], [:], context: "file"))
        XCTAssertNoThrow(try validateTags(["encoder": "old", "title": "Keep me"], ["encoder": "new", "TITLE": "Keep me"], context: "file"))
    }
    func testOutputValidationRejectsShortenedAudio() throws {
        let source = try decode(fixture)
        let output = try decode("""
        {"streams":[
          {"index":0,"codec_type":"video","codec_name":"h264","width":128,"height":72,
           "start_time":"0.000","duration":"2.000","disposition":{"default":1},"tags":{"language":"eng"}},
          {"index":1,"codec_type":"audio","codec_name":"aac","channels":2,"sample_rate":"48000",
           "start_time":"1.250","duration":"2.000","disposition":{"default":1},"tags":{"language":"deu"}},
          {"index":2,"codec_type":"video","codec_name":"mjpeg","width":64,"height":64,"disposition":{"attached_pic":1}}
        ],"chapters":[],"format":{"tags":{"title":"Original title"}}}
        """)
        XCTAssertThrowsError(try validateOutput(source: source, output: output, frameCount: 100800))
    }
}

final class PublicationTests: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
    func testOutputSuffixPreservesExtension() {
        XCTAssertEqual(outputURL(for: URL(fileURLWithPath: "/tmp/a.b.MP4")).path, "/tmp/a.b_voiceremoved.MP4")
    }
    func testCollisionCannotReplaceExistingContent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("temp")
        let final = directory.appendingPathComponent("final")
        try Data("new".utf8).write(to: temporary)
        try Data("old".utf8).write(to: final)
        XCTAssertThrowsError(try publish(temporary, to: final))
        XCTAssertEqual(try Data(contentsOf: final), Data("old".utf8))
    }
    func testDanglingSymlinkCollisionCannotReplaceLink() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("temp")
        let final = directory.appendingPathComponent("final")
        try Data("new".utf8).write(to: temporary)
        try FileManager.default.createSymbolicLink(atPath: final.path, withDestinationPath: "missing")
        XCTAssertThrowsError(try publish(temporary, to: final))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: final.path), "missing")
    }
    func testConcurrentPublicationHasOneWinner() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("temp")
        let final = directory.appendingPathComponent("final")
        try Data("complete".utf8).write(to: temporary)
        let lock = NSLock()
        var successes = 0
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if (try? publish(temporary, to: final)) != nil {
                lock.lock(); successes += 1; lock.unlock()
            }
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(try Data(contentsOf: final), Data("complete".utf8))
    }
    func testFolderExcludesOutputsHiddenFilesAndSymlinks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.MP4", "b.mov", "a_voiceremoved.MP4", ".hidden.mp4", "note.txt"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link.mp4").path, withDestinationPath: "a.MP4")
        XCTAssertEqual(try inputs(at: directory).map(\.lastPathComponent), ["a.MP4", "b.mov"])
    }
}
