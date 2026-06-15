import Foundation
import WhisperKit

/// Post-meeting verification: re-transcribe the saved lane WAVs with a larger
/// model, diff against the realtime transcript, and produce the final
/// (higher-accuracy) transcript plus a discrepancy report.
enum VerificationPass {
    static let offlineModel = "large-v3_turbo"

    struct Output {
        var finalTranscript: Transcript
        var report: VerificationReport
    }

    static func run(
        liveTranscript: Transcript,
        micWavURL: URL,
        systemWavURL: URL
    ) async throws -> Output {
        Log.info("Verification pass: loading offline model (\(offlineModel))…")
        let config = WhisperKitConfig(model: offlineModel)
        let whisper = try await WhisperKit(config)

        var offlineSegments: [TranscriptSegment] = []
        for (lane, url) in [(SpeakerLane.me, micWavURL), (SpeakerLane.them, systemWavURL)] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            Log.info("Verification pass: transcribing \(url.lastPathComponent)…")
            let results = try await whisper.transcribe(audioPath: url.path)
            for result in results {
                for segment in result.segments {
                    guard let text = TranscriptionEngine.meaningfulText(segment.text) else { continue }
                    offlineSegments.append(TranscriptSegment(
                        start: Double(segment.start),
                        end: Double(segment.end),
                        text: text,
                        lane: lane
                    ))
                }
            }
        }

        let report = reconcile(
            live: liveTranscript.segments,
            offline: offlineSegments,
            meetingID: liveTranscript.meetingID
        )

        var final = liveTranscript
        final.modelName = offlineModel
        final.segments = offlineSegments.sorted { $0.start < $1.start }

        return Output(finalTranscript: final, report: report)
    }

    /// Time-overlap alignment: for each offline segment, gather live segments
    /// on the same lane that overlap its window, then compare word sets.
    static func reconcile(
        live: [TranscriptSegment],
        offline: [TranscriptSegment],
        meetingID: String
    ) -> VerificationReport {
        var discrepancies: [VerificationReport.Discrepancy] = []
        var similaritySum = 0.0
        var compared = 0

        for offlineSegment in offline {
            let overlapping = live.filter { liveSegment in
                liveSegment.lane == offlineSegment.lane &&
                    liveSegment.end > offlineSegment.start - 1.0 &&
                    liveSegment.start < offlineSegment.end + 1.0
            }
            guard !overlapping.isEmpty else {
                discrepancies.append(.init(
                    start: offlineSegment.start,
                    end: offlineSegment.end,
                    lane: offlineSegment.lane,
                    liveText: "",
                    offlineText: offlineSegment.text,
                    similarity: 0
                ))
                continue
            }

            let liveText = overlapping.map(\.text).joined(separator: " ")
            let similarity = wordOverlap(liveText, offlineSegment.text)
            similaritySum += similarity
            compared += 1

            if similarity < 0.6 {
                discrepancies.append(.init(
                    start: offlineSegment.start,
                    end: offlineSegment.end,
                    lane: offlineSegment.lane,
                    liveText: liveText,
                    offlineText: offlineSegment.text,
                    similarity: similarity
                ))
            }
        }

        return VerificationReport(
            meetingID: meetingID,
            liveModel: TranscriptionEngine.liveModel,
            offlineModel: offlineModel,
            totalLiveSegments: live.count,
            totalOfflineSegments: offline.count,
            agreementRatio: compared > 0 ? similaritySum / Double(compared) : 0,
            discrepancies: discrepancies
        )
    }

    /// Jaccard similarity over normalized word sets — cheap, order-insensitive,
    /// good enough to flag segments the live pass got wrong.
    static func wordOverlap(_ a: String, _ b: String) -> Double {
        let wordsA = normalizedWords(a)
        let wordsB = normalizedWords(b)
        if wordsA.isEmpty && wordsB.isEmpty { return 1 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    private static func normalizedWords(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }
}
