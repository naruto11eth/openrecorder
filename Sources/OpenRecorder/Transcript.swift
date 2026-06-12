import Foundation

/// Which audio lane a segment came from. Channel separation gives us
/// Granola-style attribution for free: mic == the user, system == everyone else.
enum SpeakerLane: String, Codable {
    case me
    case them
}

struct TranscriptSegment: Codable {
    /// Seconds from meeting start.
    var start: Double
    var end: Double
    var text: String
    var lane: SpeakerLane
    /// Resolved display name when known (calendar attendees, future Meet caption scrape).
    var speakerName: String?
}

struct Transcript: Codable {
    var meetingID: String
    var source: MeetingSource
    var startedAt: Date
    var endedAt: Date?
    var modelName: String
    var segments: [TranscriptSegment]

    var sortedSegments: [TranscriptSegment] {
        segments.sorted { $0.start < $1.start }
    }
}

enum MeetingSource: String, Codable {
    case googleMeet = "google-meet"
    case slackHuddle = "slack-huddle"
    case manual

    var displayName: String {
        switch self {
        case .googleMeet: return "Google Meet"
        case .slackHuddle: return "Slack Huddle"
        case .manual: return "Manual Recording"
        }
    }
}

/// Result of diffing the realtime transcript against the offline high-accuracy pass.
struct VerificationReport: Codable {
    var meetingID: String
    var liveModel: String
    var offlineModel: String
    var totalLiveSegments: Int
    var totalOfflineSegments: Int
    /// 0...1 word-level agreement between the two passes.
    var agreementRatio: Double
    var discrepancies: [Discrepancy]

    struct Discrepancy: Codable {
        var start: Double
        var end: Double
        var lane: SpeakerLane
        var liveText: String
        var offlineText: String
        var similarity: Double
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var standard: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
