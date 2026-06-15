import AppKit
import CoreAudio
import Foundation

struct DetectedMeeting: Equatable {
    var source: MeetingSource
    /// PID of the app that owns the call window (browser or Slack).
    var ownerPID: pid_t
    var ownerBundleID: String
    /// Window number from CGWindowList, used to resolve the SCWindow to record.
    var windowID: CGWindowID?
    var windowTitle: String?
}

/// Three-signal meeting detection, polled every 2 seconds:
///  1. Process scan — Slack or a known browser is running (NSWorkspace).
///  2. Window-title scan — CGWindowList titles matching Meet/Huddle keywords.
///     Requires Screen Recording permission for kCGWindowName; without it we
///     fall back to signal 3.
///  3. Mic-in-use — CoreAudio default input device is active somewhere.
///     Secondary signal only: Bluetooth mics often report inactive.
final class MeetingDetector {
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser", // Arc
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.vivaldi.Vivaldi",
    ]
    static let slackBundleID = "com.tinyspeck.slackmacgap"

    static let meetTitleKeywords = ["meet.google.com", "Google Meet", "Meet – ", "Meet - "]
    static let huddleTitleKeywords = ["Huddle", "huddle", "Slack call"]

    /// Meet titles that mean "not in a call yet" — lobby/landing pages.
    static let meetExcludedTitles = ["Meet – Landing", "Google Meet - Landing"]

    var onMeetingStarted: ((DetectedMeeting) -> Void)?
    var onMeetingEnded: ((DetectedMeeting) -> Void)?

    private var timer: Timer?
    private(set) var current: DetectedMeeting?
    /// Consecutive misses required before declaring the meeting over, so a
    /// brief window-title flicker (tab switch) doesn't kill the recording.
    private var missCount = 0
    private let missThreshold = 5

    func start() {
        stop()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let detected = scanForMeeting()

        switch (current, detected) {
        case (nil, .some(let meeting)):
            current = meeting
            missCount = 0
            onMeetingStarted?(meeting)
        case (.some(let active), nil):
            missCount += 1
            Log.info("Meeting window gone (\(missCount)/\(missThreshold)) — will stop if it stays gone")
            if missCount >= missThreshold {
                current = nil
                missCount = 0
                onMeetingEnded?(active)
            }
        case (.some, .some(let meeting)):
            missCount = 0
            current = meeting // keep windowID fresh if the window moved
        case (nil, nil):
            break
        }
    }

    func scanForMeeting() -> DetectedMeeting? {
        let running = NSWorkspace.shared.runningApplications
        let slack = running.first { $0.bundleIdentifier == Self.slackBundleID }
        let browsers = running.filter { Self.browserBundleIDs.contains($0.bundleIdentifier ?? "") }

        guard slack != nil || !browsers.isEmpty else { return nil }

        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for info in windowInfo {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0
            else { continue }

            let title = info[kCGWindowName as String] as? String

            // Slack: require a real "Huddle" window title. We deliberately do
            // NOT use mic-in-use as a fallback — during recording OpenRecorder
            // holds the mic open, which would self-trigger a phantom huddle and
            // prevent the meeting from ever being detected as ended.
            if let slack, slack.processIdentifier == pid,
               let title, Self.huddleTitleKeywords.contains(where: { title.contains($0) }) {
                return DetectedMeeting(
                    source: .slackHuddle,
                    ownerPID: pid,
                    ownerBundleID: Self.slackBundleID,
                    windowID: windowID,
                    windowTitle: title
                )
            }

            if let browser = browsers.first(where: { $0.processIdentifier == pid }),
               let title,
               Self.meetTitleKeywords.contains(where: { title.contains($0) }),
               !Self.meetExcludedTitles.contains(where: { title.contains($0) }) {
                return DetectedMeeting(
                    source: .googleMeet,
                    ownerPID: pid,
                    ownerBundleID: browser.bundleIdentifier ?? "",
                    windowID: windowID,
                    windowTitle: title
                )
            }
        }

        return nil
    }

    /// CoreAudio: is the default input device running somewhere (any process)?
    static func isDefaultInputDeviceActive() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return false }

        var isRunning = UInt32(0)
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let runningStatus = AudioObjectGetPropertyData(
            deviceID, &runningAddress, 0, nil, &runningSize, &isRunning
        )
        return runningStatus == noErr && isRunning != 0
    }
}
