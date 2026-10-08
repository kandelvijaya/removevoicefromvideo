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
        XCTAssertFalse(arguments.contains("-movflags"), "cover art must use the default iTunes metadata path")
        XCTAssertTrue(arguments.contains("-map_metadata:g"))
        XCTAssertTrue(arguments.contains("0:g"))
        XCTAssertTrue(arguments.contains("-map_metadata:s:2"))
        XCTAssertTrue(arguments.contains("0:s:3"))
    }
    func testCoverFaststartDoesNotSelectMDTA() throws {
        for ext in ["MP4", "m4v"] {
            let arguments = try remuxContainerArguments(input: URL(fileURLWithPath: "/clip.\(ext)"),
                                                       media: decode(fixture), faststart: true)
            XCTAssertEqual(arguments, ["-write_tmcd", "0", "-movflags", "+faststart"])
        }
    }
    func testCustomMetadataWithCoverFailsPreflight() throws {
        let media = try decode(fixture.replacingOccurrences(of: "\"title\":\"Original title\"",
                                                            with: "\"title\":\"Original title\",\"project_note\":\"Keep me\""))
        XCTAssertThrowsError(try remuxContainerArguments(input: URL(fileURLWithPath: "/clip.mp4"), media: media, faststart: false)) { error in
            XCTAssertTrue(String(describing: error).contains("project_note"))
        }
        // Preflight does not relax final metadata validation.
        XCTAssertThrowsError(try validateTags(media.format?.tags, ["title": "Original title"], context: "file"))
    }
    func testMetadataWithoutCoverUsesMDTA() throws {
        let media = try decode(fixture.replacingOccurrences(of: "\"attached_pic\":1", with: "\"attached_pic\":0")
            .replacingOccurrences(of: "\"title\":\"Original title\"", with: "\"project_note\":\"Keep me\""))
        for ext in ["mp4", "mov", "m4v"] {
            XCTAssertEqual(try remuxContainerArguments(input: URL(fileURLWithPath: "/clip.\(ext)"), media: media, faststart: false),
                           ["-write_tmcd", "0", "-movflags", "+use_metadata_tags"])
            XCTAssertEqual(try remuxContainerArguments(input: URL(fileURLWithPath: "/clip.\(ext)"), media: media, faststart: true),
                           ["-write_tmcd", "0", "-movflags", "+use_metadata_tags+faststart"])
        }
    }
    func testMOVCoverAndNonMOVFaststartFailPreflight() throws {
        let media = try decode(fixture)
        XCTAssertThrowsError(try remuxContainerArguments(input: URL(fileURLWithPath: "/clip.mov"), media: media, faststart: false))
        XCTAssertThrowsError(try remuxContainerArguments(input: URL(fileURLWithPath: "/clip.mkv"), media: media, faststart: true))
        XCTAssertEqual(try remuxContainerArguments(input: URL(fileURLWithPath: "/clip.mkv"), media: media, faststart: false), [])
    }
    func testStandardCoverMetadataKeysAndBookkeepingPassPreflight() throws {
        XCTAssertNoThrow(try validateCoverFileMetadata(["creation_time": "2026-10-04T09:55:11.000000Z",
                                                       "title": "Keep me", "comment": "Keep me too", "encoder": "Camera"]))
        XCTAssertThrowsError(try validateCoverFileMetadata(["com.apple.quicktime.make": "Camera"]))
    }
    let timecodeFixture = """
    {"streams":[
      {"index":0,"codec_type":"video","codec_name":"h264","width":128,"height":72,
       "start_time":"0.000000","duration":"2.000000","disposition":{"default":1},"tags":{"timecode":"01:00:00:00"}},
      {"index":1,"codec_type":"audio","codec_name":"aac","channels":2,"sample_rate":"48000",
       "start_time":"0.000000","duration":"2.000000","disposition":{"default":1}},
      {"index":2,"codec_type":"data","codec_tag_string":"tmcd","time_base":"1/12800","nb_frames":"1",
       "start_time":"0.000000","duration":"2.000000","disposition":{"default":1},
       "tags":{"timecode":"01:00:00:00","language":"eng","handler_name":"TimeCodeHandler",
               "creation_time":"2026-10-07T17:48:35.000000Z"}}
    ],"chapters":[]}
    """
    func testTimecodeWithoutCodecNameIsMappedAndNotRegenerated() throws {
        let media = try decode(timecodeFixture)
        XCTAssertNil(media.streams[2].codec_name)
        XCTAssertTrue(media.streams[2].isTimecode)
        XCTAssertEqual(media.retained.map(\.index), [0, 1, 2])
        let args = try remuxArguments(input: URL(fileURLWithPath: "/clip.mov"),
                                     audio: URL(fileURLWithPath: "/audio.m4a"),
                                     temporary: URL(fileURLWithPath: "/temp.mov"), media: media, faststart: false)
        XCTAssertTrue(args.contains("0:2"))
        XCTAssertTrue(args.contains("-map_metadata:s:2"))
        XCTAssertTrue(args.contains("-disposition:2"))
        XCTAssertEqual(args[args.firstIndex(of: "-write_tmcd")! + 1], "0")
        XCTAssertNoThrow(try validateOutput(source: media, output: media, frameCount: 96000))
    }
    func testTimecodeRejectsFormatTimingValueAndMetadataChanges() throws {
        // Remove the video's tag so each failure exercises the copied data track.
        let fixture = timecodeFixture.replacingOccurrences(of: "\"tags\":{\"timecode\":\"01:00:00:00\"}", with: "\"tags\":{}")
        let source = try decode(fixture)
        let changes = [
            ("\"tmcd\"", "\"djmd\""),
            ("\"1/12800\"", "\"1/1000\""),
            ("\"nb_frames\":\"1\"", "\"nb_frames\":\"2\""),
            ("01:00:00:00", "02:00:00:00"),
            ("\"timecode\":\"01:00:00:00\"", "\"other\":\"01:00:00:00\""),
            ("TimeCodeHandler", "VideoHandler"),
            ("2026-10-07T17:48:35.000000Z", "2026-10-08T17:48:35.000000Z"),
            ("\"language\":\"eng\"", "\"language\":\"und\"")
        ]
        for (old, new) in changes {
            let output = try decode(fixture.replacingOccurrences(of: old, with: new))
            XCTAssertThrowsError(try validateOutput(source: source, output: output, frameCount: 96000), old)
        }
        for endpoint in ["start_time", "duration"] {
            var object = try JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
            var streams = object["streams"] as! [[String: Any]]
            streams[2][endpoint] = endpoint == "start_time" ? "0.002000" : "2.002000"
            object["streams"] = streams
            let output = try JSONDecoder().decode(Media.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try validateOutput(source: source, output: output, frameCount: 96000), endpoint)
        }
    }
    func testMissingDuplicateAndUnknownOutputDataAreRejected() throws {
        let source = try decode(timecodeFixture)
        for extra in [
            "{\"index\":3,\"codec_type\":\"data\",\"codec_tag_string\":\"tmcd\"}",
            "{\"index\":3,\"codec_type\":\"data\",\"codec_name\":\"djmd\"}",
            "{\"index\":3,\"codec_type\":\"data\",\"codec_name\":\"bin_data\"}"
        ] {
            let output = try decode(timecodeFixture.replacingOccurrences(of: "],\"chapters\":[]", with: ",\(extra)],\"chapters\":[]"))
            XCTAssertThrowsError(try validateOutput(source: source, output: output, frameCount: 96000))
        }
        var object = try JSONSerialization.jsonObject(with: Data(timecodeFixture.utf8)) as! [String: Any]
        object["streams"] = Array((object["streams"] as! [[String: Any]]).prefix(2))
        let missing = try JSONDecoder().decode(Media.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try validateOutput(source: source, output: missing, frameCount: 96000))
    }
    func testOnlyDataWithTMCDTagIsRetainedAndUnknownDataStillDrops() throws {
        let media = try decode(timecodeFixture.replacingOccurrences(of: "],\"chapters\":[]", with:
            ", {\"index\":3,\"codec_type\":\"data\",\"codec_name\":\"djmd\",\"codec_tag_string\":\"djmd\"}],\"chapters\":[]"))
        XCTAssertEqual(media.retained.map(\.index), [0, 1, 2])
        let args = try remuxArguments(input: URL(fileURLWithPath: "/clip.mov"), audio: URL(fileURLWithPath: "/audio.m4a"),
                                     temporary: URL(fileURLWithPath: "/temp.mov"), media: media, faststart: false)
        XCTAssertTrue(args.contains("0:2"))
        XCTAssertFalse(args.contains("0:3"))
        let impostor = try decode("{\"streams\":[{\"index\":0,\"codec_type\":\"unknown\",\"codec_tag_string\":\"tmcd\"}]}")
        XCTAssertFalse(impostor.streams[0].isTimecode)
    }
    func testTimecodeWithChaptersDoesNotAdmitUnknownOutputData() throws {
        let fixture = timecodeFixture.replacingOccurrences(of: "\"chapters\":[]", with:
            "\"chapters\":[{\"start_time\":\"0.000\",\"end_time\":\"1.900\",\"tags\":{\"title\":\"Chapter\"}}]")
        let source = try decode(fixture)
        let output = try decode(fixture.replacingOccurrences(of: "],\"chapters\":", with:
            ", {\"index\":3,\"codec_type\":\"data\",\"codec_tag_string\":\"djmd\"}],\"chapters\":"))
        XCTAssertThrowsError(try validateOutput(source: source, output: output, frameCount: 96000))
    }
    func testUnsupportedOrIncompleteTimecodeFailsPreflight() throws {
        let media = try decode(timecodeFixture)
        XCTAssertThrowsError(try remuxContainerArguments(input: URL(fileURLWithPath: "/clip.mkv"), media: media, faststart: false))
        let incomplete = try decode(timecodeFixture.replacingOccurrences(of: "\"nb_frames\":\"1\",", with: ""))
        XCTAssertThrowsError(try remuxContainerArguments(input: URL(fileURLWithPath: "/clip.mov"), media: incomplete, faststart: false))
        let missingValue = try decode(timecodeFixture.replacingOccurrences(of: "01:00:00:00", with: ""))
        XCTAssertThrowsError(try remuxContainerArguments(input: URL(fileURLWithPath: "/clip.mov"), media: missingValue, faststart: false))
    }
    func timecodeMedia(setting field: String, to value: String?) throws -> Media {
        var object = try JSONSerialization.jsonObject(with: Data(timecodeFixture.utf8)) as! [String: Any]
        var streams = object["streams"] as! [[String: Any]]
        streams[2][field] = value // nil removes the field.
        object["streams"] = streams
        return try JSONDecoder().decode(Media.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testCopiedTimecodeRequiresMOVButOrdinaryMP4AndM4VStillPass() throws {
        let media = try decode(timecodeFixture)
        var object = try JSONSerialization.jsonObject(with: Data(timecodeFixture.utf8)) as! [String: Any]
        object["streams"] = Array((object["streams"] as! [[String: Any]]).prefix(2))
        let ordinary = try JSONDecoder().decode(Media.self, from: JSONSerialization.data(withJSONObject: object))
        for ext in ["mp4", "MP4", "m4v", "M4V"] {
            for faststart in [false, true] {
                let input = URL(fileURLWithPath: "/clip.\(ext)")
                XCTAssertThrowsError(try remuxContainerArguments(input: input, media: media, faststart: faststart)) { error in
                    XCTAssertTrue(String(describing: error).contains("copied tmcd timecode tracks require MOV"))
                }
                // A video's timecode tag alone does not require an explicitly copied track.
                let args = try remuxArguments(input: input, audio: URL(fileURLWithPath: "/audio.m4a"),
                    temporary: URL(fileURLWithPath: "/temp.\(ext)"), media: ordinary, faststart: faststart)
                XCTAssertFalse(args.contains("0:2"))
                XCTAssertEqual(args[args.firstIndex(of: "-write_tmcd")! + 1], "0")
                XCTAssertEqual(args.contains("+use_metadata_tags+faststart"), faststart)
            }
        }
        for ext in ["mov", "MOV"] {
            XCTAssertNoThrow(try remuxContainerArguments(input: URL(fileURLWithPath: "/clip.\(ext)"), media: media, faststart: false))
        }
    }
    func testInvalidTimecodeNumericFieldsFailPreflightAndOutputEvenWhenIdentical() throws {
        let valid = try decode(timecodeFixture)
        let invalidFields: [(String, [String?])] = [
            ("time_base", [nil, "", "N/A", "0/0", "0/1", "1/0", "-1/2", "1/-2", "-1/-2",
                           "1", "/1", "1/", "1//2", "1/2/3", "+1/2", "1/+2", "1.0/2", "1e1/2",
                           " 1/2", "1/2 ", "1/\n2", "１/2", "2147483648/1", "1/2147483648",
                           "9223372036854775808/1", "1/9223372036854775808"]),
            ("nb_frames", [nil, "", "N/A", "0", "-1", "+1", "1.0", "1e2", "1/1", " 1", "1 ", "1\n", "１",
                           "9223372036854775808", "18446744073709551616"]),
            ("start_time", [nil, "", "N/A", "NaN", "inf"]),
            ("duration", [nil, "", "N/A", "NaN", "inf", "0", "-1"])
        ]
        for (field, values) in invalidFields {
            for value in values {
                let invalid = try timecodeMedia(setting: field, to: value)
                let context = "\(field)=\(value ?? "<missing>")"
                XCTAssertThrowsError(try remuxContainerArguments(input: URL(fileURLWithPath: "/clip.mov"),
                    media: invalid, faststart: false), context)
                XCTAssertThrowsError(try validateOutput(source: valid, output: invalid, frameCount: 96000), context)
                XCTAssertThrowsError(try validateOutput(source: invalid, output: valid, frameCount: 96000), context)
                XCTAssertThrowsError(try validateOutput(source: invalid, output: invalid, frameCount: 96000), context)
            }
        }
    }
    func testValidTimecodeNumericBoundariesPass() throws {
        for (field, value) in [("time_base", "2147483647/1"), ("time_base", "1/2147483647"),
                               ("time_base", "2147483647/2147483647"), ("time_base", "01/012800"),
                               ("nb_frames", "9223372036854775807"), ("nb_frames", "01"),
                               ("start_time", "-1.000000")] {
            let media = try timecodeMedia(setting: field, to: value)
            XCTAssertNoThrow(try remuxContainerArguments(input: URL(fileURLWithPath: "/clip.mov"), media: media, faststart: false))
            XCTAssertNoThrow(try validateOutput(source: media, output: media, frameCount: 96000))
        }
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
    func testCreationTimeEquivalentFormatsAndRedundantMOVValuesPass() throws {
        let values = [
            ("2026-10-07T17:48:35.000000Z", "2026-10-07T17:48:35Z"),
            ("2026-10-07T17:48:35Z", "2026-10-07T19:48:35.000+02:00"),
            ("2026-10-07T17:48:35Z", "2026-10-07T12:18:35-05:30"),
            ("2026-10-07T23:48:35Z", "2026-10-08T01:48:35+02:00"),
            ("2024-02-29T23:48:35Z", "2024-03-01T01:48:35+02:00"),
            ("2026-10-07T17:48:35.123456789123Z", "2026-10-07T17:48:35.123456789123000+00:00"),
            ("2026-10-07T17:48:35.000000Z", "2026-10-07T17:48:35.000000Z;2026-10-07T17:48:35.000000Z"),
            ("2026-10-07T17:48:35Z;2026-10-07T19:48:35+02:00", "2026-10-07T17:48:35.000Z")
        ]
        for (before, after) in values {
            for context in ["file", "stream 2"] {
                XCTAssertNoThrow(try validateTags(["creation_time": before], ["CREATION_TIME": after], context: context), after)
                XCTAssertNoThrow(try validateTags(["creation_time": after], ["creation_time": before], context: context), before)
            }
        }
    }
    func testCreationTimeDifferentInstantsOrLostPrecisionFail() throws {
        let original = "2026-10-07T17:48:35.123456789123Z"
        for changed in ["2026-10-08T17:48:35.123456789123Z", "2026-10-07T17:48:36.123456789123Z",
                        "2026-10-07T17:48:35Z", "2026-10-07T17:48:35.123456Z",
                        "2026-10-07T17:48:35.123456789124Z", "2026-10-07T17:48:35.123456789123+02:00",
                        original + ";2026-10-07T17:48:35.123456789124Z"] {
            XCTAssertThrowsError(try validateTags(["creation_time": original], ["creation_time": changed], context: "file"), changed)
        }
        XCTAssertThrowsError(try validateTags(["creation_time": original], [:], context: "file"))
    }
    func testCreationTimeMalformedValuesCannotReceiveFormatEquivalence() throws {
        let original = "2026-10-07T17:48:35Z"
        for invalid in ["", "N/A", "2026-10-07", "2026-10-07 17:48:35Z", "2026-10-07T17:48:35",
                        "2026-10-07T17:48:35.Z", "2026-10-07T17:48:35Zjunk", " " + original, original + "\n",
                        "2026-10-07t17:48:35z", "2026-10-07T17:48:35+0000", "2026-10-07T17:48:35-00:00",
                        "2026-10-07T17:48:35+24:00", "2026-10-07T17:48:35+00:60",
                        "2026-10-07T24:48:35Z", "2026-10-07T17:60:35Z", "2026-10-07T17:48:60Z",
                        "0000-10-07T17:48:35Z", "2026-00-07T17:48:35Z", "2026-13-07T17:48:35Z",
                        "2026-10-00T17:48:35Z", "2026-04-31T17:48:35Z", "2026-02-29T17:48:35Z",
                        "1900-02-29T17:48:35Z", "２０２６-10-07T17:48:35Z",
                        original + ";", ";" + original, original + ";;" + original, original + ";N/A"] {
            XCTAssertThrowsError(try validateTags(["creation_time": original], ["creation_time": invalid], context: "file"), invalid)
            XCTAssertThrowsError(try validateTags(["creation_time": invalid], ["creation_time": original], context: "file"), invalid)
        }
        // Invalid calendar dates must not normalize to a different spelling of that invalid date.
        XCTAssertThrowsError(try validateTags(["creation_time": "2026-02-29T17:48:35Z"],
                                             ["creation_time": "2026-02-29T17:48:35.000Z"], context: "file"))
    }
    func testTimestampEquivalenceDoesNotRelaxOtherUserMetadata() throws {
        let before = "2026-10-07T17:48:35.000000Z"
        for key in ["date", "title", "timecode", "project_note"] {
            XCTAssertThrowsError(try validateTags([key: before], [key: "2026-10-07T17:48:35Z"], context: "file"), key)
            XCTAssertThrowsError(try validateTags([key: before], [key: before + ";" + before], context: "file"), key)
        }
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
