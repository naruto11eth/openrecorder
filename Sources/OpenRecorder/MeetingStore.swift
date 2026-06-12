import Foundation

/// One folder per meeting under ~/Documents/OpenRecorder:
///   2026-06-12T14-32-05_google-meet/
///     recording.mov          — window video + system audio + mic (fragmented)
///     mic.wav, system.wav    — 16 kHz lane files (verification-pass input)
///     transcript_live.json   — realtime transcript
///     transcript_final.json  — offline high-accuracy transcript
///     verification.json      — live-vs-offline discrepancy report
///     meeting.md             — human-readable notes file
struct MeetingFolder {
    let url: URL
    let meetingID: String

    var movieURL: URL { url.appendingPathComponent("recording.mov") }
    var micWavURL: URL { url.appendingPathComponent("mic.wav") }
    var systemWavURL: URL { url.appendingPathComponent("system.wav") }
    var liveTranscriptURL: URL { url.appendingPathComponent("transcript_live.json") }
    var finalTranscriptURL: URL { url.appendingPathComponent("transcript_final.json") }
    var verificationURL: URL { url.appendingPathComponent("verification.json") }
    var markdownURL: URL { url.appendingPathComponent("meeting.md") }
}

enum MeetingStore {
    static var rootURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRecorder", isDirectory: true)
    }

    static func createFolder(for source: MeetingSource, at date: Date = Date()) throws -> MeetingFolder {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let meetingID = "\(formatter.string(from: date))_\(source.rawValue)"
        let url = rootURL.appendingPathComponent(meetingID, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return MeetingFolder(url: url, meetingID: meetingID)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            try JSONEncoder.pretty.encode(value).write(to: url, options: .atomic)
        } catch {
            Log.error("Failed to save \(url.lastPathComponent): \(error)")
        }
    }

    static func writeMarkdown(
        transcript: Transcript,
        report: VerificationReport?,
        windowTitle: String?,
        to url: URL
    ) {
        var lines: [String] = []
        lines.append("# \(transcript.source.displayName) — \(isoDay(transcript.startedAt))")
        lines.append("")
        lines.append("- **Started:** \(isoFull(transcript.startedAt))")
        if let ended = transcript.endedAt {
            let minutes = Int(ended.timeIntervalSince(transcript.startedAt) / 60)
            lines.append("- **Ended:** \(isoFull(ended)) (\(minutes) min)")
        }
        if let windowTitle {
            lines.append("- **Window:** \(windowTitle)")
        }
        lines.append("- **Transcription model:** \(transcript.modelName)")
        if let report {
            let percent = Int(report.agreementRatio * 100)
            lines.append("- **Live vs offline agreement:** \(percent)% (\(report.discrepancies.count) segments corrected)")
        }
        lines.append("")
        lines.append("## Transcript")
        lines.append("")

        for segment in transcript.sortedSegments {
            let speaker = segment.speakerName ?? (segment.lane == .me ? "Me" : "Them")
            lines.append("**[\(timestamp(segment.start))] \(speaker):** \(segment.text)")
            lines.append("")
        }

        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.error("Failed to write meeting.md: \(error)")
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func isoFull(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
