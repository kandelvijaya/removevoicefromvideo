import Foundation

/// Container bookkeeping describes the new mux, not user metadata.
/// Missing user tags cause a failure before publication, not a silent loss.
func validateTags(_ before: [String: String]?, _ after: [String: String]?, context: String) throws {
    let technical: Set<String> = ["major_brand", "minor_version", "compatible_brands", "encoder", "handler_name",
                                  "vendor_id", "duration", "number_of_frames", "number_of_bytes", "bps",
                                  "_statistics_writing_app", "_statistics_writing_date_utc", "_statistics_tags"]
    let actual = Dictionary((after ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    for (key, value) in before ?? [:] where !technical.contains(key.lowercased()) {
        guard actual[key.lowercased()] == value else {
            throw Failure("validation failed: \(context) metadata tag '\(key)' changed or is unsupported by this container")
        }
    }
}
