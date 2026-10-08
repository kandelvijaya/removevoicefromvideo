import XCTest
import Foundation
@testable import VoiceRemovedCore

final class AudioOnlyTests: XCTestCase {
    func decode(_ json: String) throws -> Media {
        try JSONDecoder().decode(Media.self, from: Data(json.utf8))
    }
    let fixture = """
    {"streams":[
      {"index":0,"codec_type":"video","start_time":"99","duration":"700","disposition":{"attached_pic":1}},
      {"index":1,"codec_type":"video","start_time":"1.25","duration":"2.137"},
      {"index":2,"codec_type":"audio","channels":2,"start_time":"1.5","duration":"6"},
      {"index":3,"codec_type":"data","codec_tag_string":"tmcd"}
    ],"format":{"tags":{"duration":"9000","project_note":"not copied"}}}
    """
    let wav = """
    {"streams":[{"index":0,"codec_type":"audio","codec_name":"pcm_s24le","channels":2,
      "sample_rate":"48000","bits_per_sample":24,"duration":"2.137000",
      "duration_ts":102576,"time_base":"1/48000"}],"format":{"format_name":"wav"}}
    """

    func testMainVideoControlsAlignmentNotCoverContainerAudioOrTimecode() throws {
        let media = try decode(fixture)
        let alignment = try AudioAlignment(media: media)
        XCTAssertEqual(alignment.targetFrames, 102576)
        XCTAssertEqual(alignment.offsetFrames, 12000)
        XCTAssertThrowsError(try remuxContainerArguments(input: URL(fileURLWithPath: "/clip.mp4"), media: media, faststart: false))
        XCTAssertNoThrow(try AudioAlignment(media: media), "WAV must not inherit copied timecode/cover metadata restrictions")
        let beforeVideo = try AudioAlignment(media: decode(fixture.replacingOccurrences(of: "\"start_time\":\"1.5\"", with: "\"start_time\":\"0.5\"")))
        XCTAssertEqual(beforeVideo.offsetFrames, -36000)
    }
    func testAlignmentUsesNearestSampleWithExplicitHalfTieRule() throws {
        for (frames, expected) in [(0.49, 0), (0.5, 1), (0.51, 1), (-0.49, 0), (-0.5, -1), (-0.51, -1), (4096.5, 4097)] {
            XCTAssertEqual(try AudioAlignment.frames(frames / Double(sampleRate)), expected)
        }
        for invalid in [Double.nan, Double.infinity, -Double.infinity, Double(Int.max), Double(Int.min)] {
            XCTAssertThrowsError(try AudioAlignment.frames(invalid))
        }
    }
    func testMissingInvalidOrZeroVideoTimingFailsPreflight() throws {
        for field in ["start_time", "duration"] {
            for value: String? in [nil, "N/A", "NaN", "inf"] + (field == "duration" ? ["0", "-1", "0.000001"] : []) {
                var object = try JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
                var streams = object["streams"] as! [[String: Any]]
                streams[1][field] = value
                object["streams"] = streams
                let media = try JSONDecoder().decode(Media.self, from: JSONSerialization.data(withJSONObject: object))
                XCTAssertThrowsError(try AudioAlignment(media: media), "\(field)=\(value ?? "missing")")
            }
        }
        XCTAssertNoThrow(try AudioAlignment(media: decode(fixture.replacingOccurrences(of: "\"start_time\":\"1.25\"", with: "\"start_time\":\"-1.25\""))))
    }
    func testWAVValidationExactFramesAndMissingTicksFallback() throws {
        XCTAssertEqual(try validateWAV(decode(wav), channels: 2, frameCount: 102576), 102576)
        XCTAssertThrowsError(try validateWAV(decode(wav), channels: 1, frameCount: 102576))
        XCTAssertThrowsError(try validateWAV(decode(wav), channels: 2, frameCount: 102575))
        // Decimal duration alone never establishes exact sample count.
        let noTicks = wav.replacingOccurrences(of: "\"duration_ts\":102576,", with: "")
        XCTAssertNil(try validateWAV(decode(noTicks), channels: 2, frameCount: 102576))
        let noBase = wav.replacingOccurrences(of: ",\"time_base\":\"1/48000\"", with: "")
        XCTAssertNil(try validateWAV(decode(noBase), channels: 2, frameCount: 102576))
        XCTAssertEqual(try validateWAV(decode(wav.replacingOccurrences(of: "\"duration_ts\":102576", with: "\"start_time\":\"0\",\"duration_ts\":102576")),
                                       channels: 2, frameCount: 102576), 102576)
    }
    func testWAVValidationRejectsFormatAndTimingMetadataMismatch() throws {
        for (old, new) in [
            ("pcm_s24le", "aac"), ("48000", "44100"), ("\"bits_per_sample\":24", "\"bits_per_sample\":16"),
            ("2.137000", "2.136000"), ("2.137000", "NaN"), ("2.137000", "inf"),
            ("102576", "102575"), ("1/48000", "1/24000"), ("1/48000", "0/0"),
            ("1/48000", "-1/-48000"), ("1/48000", "9223372036854775807/48000"),
            ("\"format_name\":\"wav\"", "\"format_name\":\"mov\"")
        ] {
            XCTAssertThrowsError(try validateWAV(decode(wav.replacingOccurrences(of: old, with: new)), channels: 2, frameCount: 102576), new)
        }
        for start in ["1", "-0.01", "NaN", "N/A"] {
            let changed = wav.replacingOccurrences(of: "\"duration_ts\":", with: "\"start_time\":\"\(start)\",\"duration_ts\":")
            XCTAssertThrowsError(try validateWAV(decode(changed), channels: 2, frameCount: 102576), start)
        }
        let extra = wav.replacingOccurrences(of: "}],\"format\":", with: "},{\"index\":1,\"codec_type\":\"video\"}],\"format\":")
        XCTAssertThrowsError(try validateWAV(decode(extra), channels: 2, frameCount: 102576))
    }
    func testAudioOnlyOutputSuffixAndInapplicableFlags() throws {
        XCTAssertEqual(outputURL(for: URL(fileURLWithPath: "/tmp/a.b.MP4"), audioOnly: true).path, "/tmp/a.b_voiceremoved.wav")
        var options = Options()
        options.audioOnly = true
        XCTAssertNoThrow(try options.validate())
        options.verify = true
        XCTAssertThrowsError(try options.validate())
        options.verify = false; options.faststart = true
        XCTAssertThrowsError(try options.validate())
    }
}
