import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Records the call window (video + app audio + mic) to a fragmented QuickTime
/// file via one SCStream, and tees both audio lanes into AudioLaneProcessors
/// for live transcription + WAV lane files.
final class CaptureEngine: NSObject, SCStreamDelegate, SCStreamOutput {
    /// H.264 hard limit in AVAssetWriter; exceeding it crashes on 5K/6K displays.
    static let maxVideoWidth = 4096
    static let maxVideoHeight = 2304

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?

    private var sessionStarted = false
    private let writerQueue = DispatchQueue(label: "openrecorder.writer")
    private let sampleQueue = DispatchQueue(label: "openrecorder.samples")

    private var micLane: AudioLaneProcessor?
    private var systemLane: AudioLaneProcessor?

    var onStreamStopped: ((Error?) -> Void)?

    /// Resolve the SCWindow for a detected meeting. desktopIndependentWindow
    /// filters follow the window across monitors automatically.
    static func resolveTarget(for meeting: DetectedMeeting) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )

        if let windowID = meeting.windowID,
           let window = content.windows.first(where: { $0.windowID == windowID }) {
            return SCContentFilter(desktopIndependentWindow: window)
        }

        // Window ID went stale between detection and start — re-match by owner + title.
        let candidates = content.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            guard app.processID == meeting.ownerPID || app.bundleIdentifier == meeting.ownerBundleID else {
                return false
            }
            guard let title = window.title else { return false }
            switch meeting.source {
            case .googleMeet:
                return MeetingDetector.meetTitleKeywords.contains { title.contains($0) }
            case .slackHuddle:
                return MeetingDetector.huddleTitleKeywords.contains { title.contains($0) }
            case .manual:
                return window.isOnScreen
            }
        }

        if let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            return SCContentFilter(desktopIndependentWindow: window)
        }

        // Last resort: record the main display so the meeting isn't lost.
        if let display = content.displays.first {
            Log.info("Call window not found, falling back to display capture")
            return SCContentFilter(display: display, excludingWindows: [])
        }
        throw RecorderError.windowNotFound("No shareable window or display for \(meeting.source.rawValue)")
    }

    func start(
        filter: SCContentFilter,
        movieURL: URL,
        micWavURL: URL,
        systemWavURL: URL,
        onChunk: @escaping (_ lane: SpeakerLane, _ samples: [Float], _ startOffset: Double) -> Void
    ) async throws {
        micLane = try AudioLaneProcessor(lane: .me, wavURL: micWavURL, onChunk: onChunk)
        systemLane = try AudioLaneProcessor(lane: .them, wavURL: systemWavURL, onChunk: onChunk)

        let configuration = SCStreamConfiguration()
        let pixelWidth = min(Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)), Self.maxVideoWidth)
        let pixelHeight = min(Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)), Self.maxVideoHeight)
        configuration.width = max(pixelWidth, 320)
        configuration.height = max(pixelHeight, 240)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15) // 15 fps is plenty for meetings
        configuration.showsCursor = true
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = true
        configuration.queueDepth = 6

        let writer = try AVAssetWriter(outputURL: movieURL, fileType: .mov)
        // Crash safety: without fragments, a crash mid-meeting loses the whole file.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(configuration.width * configuration.height * 15 / 20, 1_000_000),
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        systemAudioInput.expectsMediaDataInRealTime = true
        let micAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        micAudioInput.expectsMediaDataInRealTime = true

        for input in [videoInput, systemAudioInput, micAudioInput] where writer.canAdd(input) {
            writer.add(input)
        }
        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }

        self.writer = writer
        self.videoInput = videoInput
        self.systemAudioInput = systemAudioInput
        self.micAudioInput = micAudioInput
        self.sessionStarted = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        Log.info("Capture started → \(movieURL.lastPathComponent) @ \(configuration.width)x\(configuration.height)")
    }

    func stop() async {
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                Log.error("stopCapture: \(error)")
            }
        }
        stream = nil

        micLane?.finish()
        systemLane?.finish()
        micLane = nil
        systemLane = nil

        // Safe: writer access is serialized on writerQueue and nothing else
        // touches these objects after stop() begins.
        nonisolated(unsafe) let finishingWriter = writer
        nonisolated(unsafe) let finishingInputs = [videoInput, systemAudioInput, micAudioInput]
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async {
                guard let finishingWriter, finishingWriter.status == .writing else {
                    continuation.resume()
                    return
                }
                for input in finishingInputs {
                    input?.markAsFinished()
                }
                finishingWriter.finishWriting {
                    continuation.resume()
                }
            }
        }
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        micAudioInput = nil
        Log.info("Capture stopped, file finalized")
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            guard isCompleteFrame(sampleBuffer) else { return }
            write(sampleBuffer, to: videoInput, isVideo: true)
        case .audio:
            systemLane?.append(sampleBuffer)
            write(sampleBuffer, to: systemAudioInput, isVideo: false)
        case .microphone:
            micLane?.append(sampleBuffer)
            write(sampleBuffer, to: micAudioInput, isVideo: false)
        @unknown default:
            break
        }
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw)
        else { return false }
        return status == .complete
    }

    private func write(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?, isVideo: Bool) {
        writerQueue.async { [weak self] in
            guard let self, let writer = self.writer, let input else { return }
            guard writer.status == .writing else { return }

            // Anchor the session clock to the first *video* frame so all
            // tracks share one timeline.
            if !self.sessionStarted {
                guard isVideo else { return }
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                self.sessionStarted = true
            }

            if input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Stream stopped: \(error.localizedDescription)")
        onStreamStopped?(error)
    }
}
