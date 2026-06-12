import AppKit
import Foundation

/// CIPA (California two-party consent) gate. Recording locally is NOT a legal
/// defense — disclosure must happen before recording starts. This gate blocks
/// auto-start behind an explicit click unless the user has opted into
/// auto-record (their call, logged either way).
enum ConsentGate {
    private static let consentLogURL = MeetingStore.rootURL.appendingPathComponent("consent-log.json")

    struct ConsentEntry: Codable {
        var date: Date
        var meetingSource: String
        var windowTitle: String?
        var mode: String // "prompted" | "auto"
    }

    /// Returns true if recording may proceed.
    @MainActor
    static func requestConsent(for meeting: DetectedMeeting, autoRecordEnabled: Bool) -> Bool {
        if autoRecordEnabled {
            log(meeting: meeting, mode: "auto")
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Record this \(meeting.source.displayName)?"
        alert.informativeText = """
        OpenRecorder will record this call's window, audio, and a transcript, \
        saved locally to ~/Documents/OpenRecorder.

        California and several other states require ALL participants' consent \
        before recording. Announce the recording before continuing, e.g.:

        “Heads up — I'm recording this call for notes. Let me know if you'd \
        like me to stop.”
        """
        alert.addButton(withTitle: "I've Announced It — Record")
        alert.addButton(withTitle: "Don't Record")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)

        let granted = alert.runModal() == .alertFirstButtonReturn
        if granted {
            log(meeting: meeting, mode: "prompted")
        }
        return granted
    }

    private static func log(meeting: DetectedMeeting, mode: String) {
        var entries: [ConsentEntry] = []
        if let data = try? Data(contentsOf: consentLogURL),
           let existing = try? JSONDecoder.standard.decode([ConsentEntry].self, from: data) {
            entries = existing
        }
        entries.append(ConsentEntry(
            date: Date(),
            meetingSource: meeting.source.rawValue,
            windowTitle: meeting.windowTitle,
            mode: mode
        ))
        try? FileManager.default.createDirectory(at: MeetingStore.rootURL, withIntermediateDirectories: true)
        MeetingStore.save(entries, to: consentLogURL)
    }
}
