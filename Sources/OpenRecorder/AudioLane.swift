import AVFoundation
import CoreMedia
import Foundation

/// Receives one audio lane (mic or system) from the capture stream, and:
///  - writes a 16 kHz mono Float32 WAV to disk (input for the offline verification pass)
///  - accumulates samples and emits fixed-size chunks for live transcription
final class AudioLaneProcessor {
    static let targetSampleRate: Double = 16_000
    static let chunkSeconds: Double = 12

    let lane: SpeakerLane

    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private let wavFile: AVAudioFile

    private var pending: [Float] = []
    /// Total samples already emitted to the transcriber, defines chunk start offsets.
    private var emittedSamples: Int = 0

    private let queue: DispatchQueue
    private let onChunk: (_ lane: SpeakerLane, _ samples: [Float], _ startOffset: Double) -> Void

    init(
        lane: SpeakerLane,
        wavURL: URL,
        onChunk: @escaping (_ lane: SpeakerLane, _ samples: [Float], _ startOffset: Double) -> Void
    ) throws {
        self.lane = lane
        self.onChunk = onChunk
        self.queue = DispatchQueue(label: "openrecorder.lane.\(lane.rawValue)")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.audioFormat("Could not create 16kHz mono format")
        }
        self.targetFormat = format
        self.wavFile = try AVAudioFile(
            forWriting: wavURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        queue.async { [weak self] in
            self?.process(pcm)
        }
    }

    /// Flush remaining samples as a final (short) chunk. Call once, at stop.
    func finish() {
        queue.sync {
            if !pending.isEmpty {
                let offset = Double(emittedSamples) / Self.targetSampleRate
                onChunk(lane, pending, offset)
                emittedSamples += pending.count
                pending.removeAll()
            }
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }

        do {
            try wavFile.write(from: converted)
        } catch {
            Log.error("WAV write failed (\(lane.rawValue)): \(error)")
        }

        guard let channel = converted.floatChannelData?[0] else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))

        let chunkSamples = Int(Self.chunkSeconds * Self.targetSampleRate)
        while pending.count >= chunkSamples {
            let chunk = Array(pending.prefix(chunkSamples))
            let offset = Double(emittedSamples) / Self.targetSampleRate
            pending.removeFirst(chunkSamples)
            emittedSamples += chunkSamples
            onChunk(lane, chunk, offset)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == targetFormat { return buffer }

        if converter == nil || converterSourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterSourceFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            Log.error("Audio convert failed (\(lane.rawValue)): \(error)")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return nil }

        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }
}

enum RecorderError: LocalizedError {
    case audioFormat(String)
    case windowNotFound(String)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .audioFormat(let message): return "Audio format error: \(message)"
        case .windowNotFound(let message): return "Window not found: \(message)"
        case .writerFailed(let message): return "Recording writer failed: \(message)"
        }
    }
}

enum Log {
    /// File sink so logs survive regardless of launch method (`open` detaches
    /// stderr). Tail with: tail -f /tmp/openrecorder.log
    static let fileURL = URL(fileURLWithPath: "/tmp/openrecorder.log")
    private static let queue = DispatchQueue(label: "openrecorder.log")
    private static let handle: FileHandle? = {
        let path = fileURL.path
        FileManager.default.createFile(atPath: path, contents: nil)
        return try? FileHandle(forWritingTo: fileURL)
    }()

    static func info(_ message: String) { write("[OpenRecorder] \(message)") }
    static func error(_ message: String) { write("[OpenRecorder][ERROR] \(message)") }

    private static func write(_ line: String) {
        NSLog("%@", line)
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            if let data = "\(stamp) \(line)\n".data(using: .utf8) {
                handle?.write(data)
            }
        }
    }
}
