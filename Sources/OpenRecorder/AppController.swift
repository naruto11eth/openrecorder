import AppKit
import Foundation

/// Wires detection → consent → capture → live STT → verification.
@MainActor
final class AppController {
    enum State: Equatable {
        case needsPermission
        case idle
        case loadingModel
        case recording(meetingID: String)
        case verifying(meetingID: String)
    }

    private let detector = MeetingDetector()
    private let transcription = TranscriptionEngine()
    private var capture: CaptureEngine?

    private var activeMeeting: DetectedMeeting?
    private var activeFolder: MeetingFolder?
    private var liveTranscript: Transcript?

    private(set) var state: State = .idle {
        didSet { onStateChanged?(state) }
    }

    var onStateChanged: ((State) -> Void)?

    var detectionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "detectionEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "detectionEnabled")
            newValue ? detector.start() : detector.stop()
        }
    }

    var autoRecordWithoutPrompt: Bool {
        get { UserDefaults.standard.bool(forKey: "autoRecordWithoutPrompt") }
        set { UserDefaults.standard.set(newValue, forKey: "autoRecordWithoutPrompt") }
    }

    private var permissionPollTimer: Timer?

    func start() {
        guard Permissions.hasScreenRecording else {
            Log.error("Screen Recording permission missing — opening System Settings. Toggle OpenRecorder on; the app continues automatically (no relaunch needed).")
            state = .needsPermission
            Permissions.openScreenRecordingSettings()
            // Poll until the user flips the switch, then continue startup.
            let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                guard Permissions.hasScreenRecording else { return }
                Task { @MainActor in
                    self?.permissionPollTimer?.invalidate()
                    self?.permissionPollTimer = nil
                    Log.info("Screen Recording granted — continuing startup")
                    self?.start()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            permissionPollTimer = timer
            return
        }

        Task {
            guard await Permissions.ensureMicrophone() else {
                Log.error("Microphone permission missing")
                return
            }
            // Warm the live model at launch so meeting start isn't blocked on it.
            state = .loadingModel
            do {
                try await transcription.prepare()
            } catch {
                Log.error("Live model load failed: \(error)")
            }
            state = .idle
        }

        detector.onMeetingStarted = { [weak self] meeting in
            Task { @MainActor in
                self?.handleMeetingStarted(meeting)
            }
        }
        detector.onMeetingEnded = { [weak self] _ in
            Task { @MainActor in
                await self?.stopRecording()
            }
        }
        if detectionEnabled {
            detector.start()
        }
    }

    func startManualRecording() {
        let meeting = detector.scanForMeeting() ?? DetectedMeeting(
            source: .manual,
            ownerPID: 0,
            ownerBundleID: "",
            windowID: nil,
            windowTitle: nil
        )
        handleMeetingStarted(meeting, skipConsent: true)
    }

    private func handleMeetingStarted(_ meeting: DetectedMeeting, skipConsent: Bool = false) {
        guard case .idle = state else { return }
        Log.info("Meeting detected: \(meeting.source.rawValue) — \(meeting.windowTitle ?? "?")")

        if !skipConsent {
            guard ConsentGate.requestConsent(for: meeting, autoRecordEnabled: autoRecordWithoutPrompt) else {
                Log.info("Recording declined")
                return
            }
        }

        Task { @MainActor in
            await beginRecording(meeting)
        }
    }

    private func beginRecording(_ meeting: DetectedMeeting) async {
        do {
            try await transcription.prepare()
            await transcription.reset()

            let folder = try MeetingStore.createFolder(for: meeting.source)
            let filter = try await CaptureEngine.resolveTarget(for: meeting)

            var transcript = Transcript(
                meetingID: folder.meetingID,
                source: meeting.source,
                startedAt: Date(),
                endedAt: nil,
                modelName: TranscriptionEngine.liveModel,
                segments: []
            )
            await transcription.setSegmentHandler { [weak self] fresh in
                Task { @MainActor in
                    self?.appendLiveSegments(fresh)
                }
            }

            let capture = CaptureEngine()
            capture.onStreamStopped = { [weak self] _ in
                Task { @MainActor in
                    await self?.stopRecording()
                }
            }
            let engine = transcription
            try await capture.start(
                filter: filter,
                movieURL: folder.movieURL,
                micWavURL: folder.micWavURL,
                systemWavURL: folder.systemWavURL,
                onChunk: { lane, samples, offset in
                    Task {
                        await engine.transcribeChunk(lane: lane, samples: samples, startOffset: offset)
                    }
                }
            )

            self.capture = capture
            self.activeMeeting = meeting
            self.activeFolder = folder
            self.liveTranscript = transcript
            transcript.segments = []
            state = .recording(meetingID: folder.meetingID)
        } catch {
            Log.error("Failed to start recording: \(error)")
            state = .idle
        }
    }

    private func appendLiveSegments(_ fresh: [TranscriptSegment]) {
        guard var transcript = liveTranscript, let folder = activeFolder else { return }
        transcript.segments.append(contentsOf: fresh)
        liveTranscript = transcript
        MeetingStore.save(transcript, to: folder.liveTranscriptURL)
    }

    func stopRecording() async {
        guard case .recording = state,
              let capture,
              let folder = activeFolder,
              var transcript = liveTranscript
        else { return }

        let meeting = activeMeeting
        self.capture = nil
        activeMeeting = nil

        await capture.stop()

        transcript.endedAt = Date()
        transcript.segments = await transcription.segments
        liveTranscript = nil
        MeetingStore.save(transcript, to: folder.liveTranscriptURL)
        MeetingStore.writeMarkdown(
            transcript: transcript,
            report: nil,
            windowTitle: meeting?.windowTitle,
            to: folder.markdownURL
        )

        state = .verifying(meetingID: folder.meetingID)
        Log.info("Recording saved to \(folder.url.path); starting verification pass")

        let windowTitle = meeting?.windowTitle
        Task.detached(priority: .utility) { [weak self] in
            do {
                let output = try await VerificationPass.run(
                    liveTranscript: transcript,
                    micWavURL: folder.micWavURL,
                    systemWavURL: folder.systemWavURL
                )
                MeetingStore.save(output.finalTranscript, to: folder.finalTranscriptURL)
                MeetingStore.save(output.report, to: folder.verificationURL)
                MeetingStore.writeMarkdown(
                    transcript: output.finalTranscript,
                    report: output.report,
                    windowTitle: windowTitle,
                    to: folder.markdownURL
                )
                let percent = Int(output.report.agreementRatio * 100)
                Log.info("Verification complete: \(percent)% agreement, \(output.report.discrepancies.count) discrepancies")
            } catch {
                Log.error("Verification pass failed: \(error)")
            }
            await MainActor.run { [weak self] in
                self?.state = .idle
            }
        }
    }
}
