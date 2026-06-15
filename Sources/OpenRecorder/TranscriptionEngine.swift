import Foundation
import WhisperKit

/// Live transcription: serially transcribes 12-second lane chunks as the
/// capture engine emits them. Chunks queue up if the model falls behind;
/// the offline verification pass covers any quality gaps.
actor TranscriptionEngine {
    static let liveModel = "base.en"

    private var whisper: WhisperKit?
    private(set) var segments: [TranscriptSegment] = []

    var onSegments: (([TranscriptSegment]) -> Void)?

    func setSegmentHandler(_ handler: @escaping ([TranscriptSegment]) -> Void) {
        onSegments = handler
    }

    func prepare() async throws {
        guard whisper == nil else { return }
        Log.info("Loading live STT model (\(Self.liveModel))…")
        let config = WhisperKitConfig(model: Self.liveModel)
        whisper = try await WhisperKit(config)
        Log.info("Live STT model ready")
    }

    func reset() {
        segments = []
    }

    func transcribeChunk(lane: SpeakerLane, samples: [Float], startOffset: Double) async {
        guard let whisper else { return }
        // Whisper hallucinates on near-silence; skip quiet chunks.
        guard hasSpeechEnergy(samples) else { return }

        do {
            let options = DecodingOptions(
                temperature: 0.0,
                suppressBlank: true,
                compressionRatioThreshold: 2.0,
                logProbThreshold: -1.0,
                noSpeechThreshold: 0.6
            )
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
            var fresh: [TranscriptSegment] = []
            for result in results {
                for segment in result.segments {
                    guard let text = Self.meaningfulText(segment.text) else { continue }
                    fresh.append(TranscriptSegment(
                        start: startOffset + Double(segment.start),
                        end: startOffset + Double(segment.end),
                        text: text,
                        lane: lane
                    ))
                }
            }
            guard !fresh.isEmpty else { return }
            segments.append(contentsOf: fresh)
            onSegments?(fresh)
        } catch {
            Log.error("Live transcription chunk failed (\(lane.rawValue)): \(error)")
        }
    }

    private func hasSpeechEnergy(_ samples: [Float], threshold: Float = 0.01) -> Bool {
        guard !samples.isEmpty else { return false }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = (sumSquares / Float(samples.count)).squareRoot()
        return rms > threshold
    }

    /// Returns readable speech text, or nil if the segment is pure non-speech.
    /// Whisper wraps ambient sound in brackets/parens ("[BLANK_AUDIO]",
    /// "(wind blowing)", "(crowd murmuring)"); a segment whose entire content
    /// is such an annotation is noise and gets dropped.
    static func meaningfulText(_ raw: String) -> String? {
        var text = raw
        // Strip Whisper special tokens like <|startoftranscript|>.
        while let open = text.range(of: "<|"),
              let close = text.range(of: "|>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Remove bracketed/parenthesized spans + stray brackets; if nothing
        // real remains, the segment was a non-speech annotation.
        var stripped = text
        for pattern in ["\\[[^\\]]*\\]", "\\([^\\)]*\\)", "[\\[\\]()]"] {
            stripped = stripped.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : text
    }
}
