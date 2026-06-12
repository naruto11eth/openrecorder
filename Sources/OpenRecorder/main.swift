import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = AppController()

    private let statusLine = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let recordItem = NSMenuItem(title: "Start Recording Now", action: #selector(toggleRecording), keyEquivalent: "r")
    private let detectItem = NSMenuItem(title: "Detect Meetings Automatically", action: #selector(toggleDetection), keyEquivalent: "")
    private let autoItem = NSMenuItem(title: "Auto-Record Without Asking", action: #selector(toggleAutoRecord), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "OpenRecorder")
        }

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        recordItem.target = self
        menu.addItem(recordItem)
        menu.addItem(.separator())
        detectItem.target = self
        autoItem.target = self
        menu.addItem(detectItem)
        menu.addItem(autoItem)
        menu.addItem(.separator())

        let openFolder = NSMenuItem(title: "Open Recordings Folder", action: #selector(openRecordings), keyEquivalent: "o")
        openFolder.target = self
        menu.addItem(openFolder)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenRecorder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        controller.onStateChanged = { [weak self] state in
            self?.render(state)
        }
        refreshToggles()
        controller.start()
    }

    private func render(_ state: AppController.State) {
        switch state {
        case .needsPermission:
            statusLine.title = "Grant Screen Recording in System Settings…"
            statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Needs permission")
        case .idle:
            statusLine.title = "Idle — watching for meetings"
            recordItem.title = "Start Recording Now"
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Idle")
        case .loadingModel:
            statusLine.title = "Loading transcription model…"
        case .recording(let meetingID):
            statusLine.title = "Recording: \(meetingID)"
            recordItem.title = "Stop Recording"
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
        case .verifying(let meetingID):
            statusLine.title = "Verifying transcript: \(meetingID)"
            recordItem.title = "Start Recording Now"
            statusItem.button?.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Verifying")
        }
    }

    private func refreshToggles() {
        detectItem.state = controller.detectionEnabled ? .on : .off
        autoItem.state = controller.autoRecordWithoutPrompt ? .on : .off
    }

    @objc private func toggleRecording() {
        if case .recording = controller.state {
            Task { await controller.stopRecording() }
        } else {
            controller.startManualRecording()
        }
    }

    @objc private func toggleDetection() {
        controller.detectionEnabled.toggle()
        refreshToggles()
    }

    @objc private func toggleAutoRecord() {
        controller.autoRecordWithoutPrompt.toggle()
        refreshToggles()
    }

    @objc private func openRecordings() {
        try? FileManager.default.createDirectory(at: MeetingStore.rootURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(MeetingStore.rootURL)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
