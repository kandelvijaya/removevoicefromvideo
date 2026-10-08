import Foundation

/// Container bookkeeping describes the new mux, not user metadata.
let containerBookkeepingTags: Set<String> = ["major_brand", "minor_version", "compatible_brands", "encoder", "handler_name",
                                            "vendor_id", "duration", "number_of_frames", "number_of_bytes", "bps",
                                            "_statistics_writing_app", "_statistics_writing_date_utc", "_statistics_tags"]

/// FFmpeg's MP4/iPod iTunes path writes covr, but not arbitrary mdta keys.
/// These keys use standard atoms (creation_time uses the container header).
/// Values still receive exact validation after muxing; some atoms normalize values.
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

/// Missing user tags cause a failure before publication, not a silent loss.
func validateTags(_ before: [String: String]?, _ after: [String: String]?, context: String) throws {
    let actual = Dictionary((after ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    for (key, value) in before ?? [:] where !containerBookkeepingTags.contains(key.lowercased()) {
        guard actual[key.lowercased()] == value else {
            throw Failure("validation failed: \(context) metadata tag '\(key)' changed or is unsupported by this container")
        }
    }
}
