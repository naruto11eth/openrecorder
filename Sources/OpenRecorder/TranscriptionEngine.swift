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
            let results = try await whisper.transcribe(audioArray: samples)
            var fresh: [TranscriptSegment] = []
            for result in results {
                for segment in result.segments {
                    let text = Self.cleanText(segment.text)
                    guard !text.isEmpty else { continue }
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

    private func hasSpeechEnergy(_ samples: [Float], threshold: Float = 0.005) -> Bool {
        guard !samples.isEmpty else { return false }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = (sumSquares / Float(samples.count)).squareRoot()
        return rms > threshold
    }

    /// Strip Whisper special tokens like <|startoftranscript|> and trim.
    static func cleanText(_ raw: String) -> String {
        var text = raw
        while let open = text.range(of: "<|"), let close = text.range(of: "|>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
