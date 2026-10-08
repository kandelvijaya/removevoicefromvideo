import Foundation

/// Container bookkeeping describes the new mux, not user metadata.
let containerBookkeepingTags: Set<String> = ["major_brand", "minor_version", "compatible_brands", "encoder", "handler_name",
                                            "vendor_id", "duration", "number_of_frames", "number_of_bytes", "bps",
                                            "_statistics_writing_app", "_statistics_writing_date_utc", "_statistics_tags"]

/// FFmpeg's MP4/iPod iTunes path writes covr, but not arbitrary mdta keys.
/// These keys use standard atoms (creation_time uses the container header).
/// Values receive strict validation after muxing; creation_time compares exact instants.
func validateCoverFileMetadata(_ tags: [String: String]?) throws {
    let supported: Set<String> = ["creation_time", "title", "artist", "album_artist", "composer", "album", "date",
                                  "encoding_tool", "comment", "genre", "copyright", "grouping", "lyrics", "description",
                                  "synopsis", "show", "episode_id", "network", "keywords", "episode_sort", "season_number",
                                  "media_type", "hd_video", "gapless_playback", "compilation", "track", "disc", "tmpo",
                                  "disc_subtitle", "location"]
    for key in (tags ?? [:]).keys.sorted() {
        guard supported.contains(key.lowercased()) || containerBookkeepingTags.contains(key.lowercased()) else {
            throw Failure("attached pictures require standard MP4/M4V file metadata; unsupported tag '\(key)' cannot coexist with cover art")
        }
    }
}

/// A copied tmcd track must retain its value and handler, not just its data type.
/// Other user tags (including creation_time and language) receive normal validation.
func validateTimecodeTags(_ before: [String: String]?, _ after: [String: String]?, context: String) throws {
    guard let value = before?["timecode"], !value.isEmpty, after?["timecode"] == value else {
        throw Failure("validation failed: \(context) timecode value changed or is missing")
    }
    if let handler = before?["handler_name"], after?["handler_name"] != handler {
        throw Failure("validation failed: \(context) handler metadata changed")
    }
}

/// Parse RFC 3339 timestamps without Date/Double rounding or calendar normalization.
/// Keep every nonzero fractional digit; only trailing zeroes have no semantic effect.
private struct CreationInstant: Equatable {
    let seconds: Int64
    let fraction: String

    init?(_ text: String) {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20 else { return nil }
        func number(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[start..<(start + count)] {
                guard (48...57).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58,
              let year = number(0, 4), (1...9999).contains(year),
              let month = number(5, 2), (1...12).contains(month),
              let day = number(8, 2),
              let hour = number(11, 2), hour < 24,
              let minute = number(14, 2), minute < 60,
              let second = number(17, 2), second < 60 else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...monthDays[month - 1]).contains(day) else { return nil }
        var position = 19
        var fraction = ""
        if bytes[position] == 46 {
            position += 1
            let start = position
            while position < bytes.count && (48...57).contains(bytes[position]) { position += 1 }
            guard position > start else { return nil }
            var end = position
            while end > start && bytes[end - 1] == 48 { end -= 1 }
            fraction = String(decoding: bytes[start..<end], as: UTF8.self)
        }
        guard position < bytes.count else { return nil }
        let offset: Int
        if bytes[position] == 90 && position + 1 == bytes.count {
            offset = 0
        } else {
            guard position + 6 == bytes.count, bytes[position] == 43 || bytes[position] == 45,
                  bytes[position + 3] == 58,
                  let hours = number(position + 1, 2), hours < 24,
                  let minutes = number(position + 4, 2), minutes < 60 else { return nil }
            // RFC 3339's -00:00 means an unknown local offset, not a known UTC instant.
            guard bytes[position] != 45 || hours != 0 || minutes != 0 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (bytes[position] == 43 ? 1 : -1)
        }
        // Proleptic Gregorian days since 0001-01-01; 1970-01-01 is day 719162.
        let priorYears = year - 1
        let days = 365 * priorYears + priorYears / 4 - priorYears / 100 + priorYears / 400
            + monthDays.prefix(month - 1).reduce(0, +) + day - 1 - 719162
        self.seconds = Int64(days) * 86400 + Int64(hour * 3600 + minute * 60 + second - offset)
        self.fraction = fraction
    }
}

/// MOV stores creation_time in both mvhd and mdta when use_metadata_tags is enabled.
/// FFprobe can join these values with ';'. Accept only redundant copies of one instant,
/// never conflicting timestamps, precision loss, an empty member, or malformed text.
private func creationTimesMatch(_ before: String, _ after: String?) -> Bool {
    func instant(_ value: String) -> CreationInstant? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        guard let first = parts.first, let expected = CreationInstant(String(first)) else { return nil }
        for part in parts.dropFirst() {
            guard CreationInstant(String(part)) == expected else { return nil }
        }
        return expected
    }
    guard let after = after, let expected = instant(before), let actual = instant(after) else { return false }
    return expected == actual
}

/// Missing user tags cause a failure before publication, not a silent loss.
/// Only creation_time permits strict semantic comparison; all other user values stay exact.
func validateTags(_ before: [String: String]?, _ after: [String: String]?, context: String) throws {
    let actual = Dictionary((after ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    for (key, value) in before ?? [:] where !containerBookkeepingTags.contains(key.lowercased()) {
        let result = actual[key.lowercased()]
        let matches = result == value || (key.lowercased() == "creation_time" && creationTimesMatch(value, result))
        guard matches else {
            throw Failure("validation failed: \(context) metadata tag '\(key)' changed or is unsupported by this container")
        }
    }
}
