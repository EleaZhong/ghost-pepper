import Foundation

/// Transcribes audio buffers using the currently selected speech backend.
///
/// Serializes transcription requests so only one runs at a time.
final class SpeechTranscriber {
    private let modelManager: ModelManager
    private let serialQueue = DispatchQueue(label: "com.whispercat.transcriber", qos: .userInitiated)
    private let semaphore = DispatchSemaphore(value: 1)

    /// Whether the underlying model is ready for transcription.
    @MainActor
    var isReady: Bool {
        modelManager.isReady
    }

    /// Whisper artifacts to filter out of transcription results.
    private static let artifacts: Set<String> = [
        "[BLANK_AUDIO]",
        "[NO_SPEECH]",
        "(blank audio)",
        "(no speech)",
        "[MUSIC]",
        "[APPLAUSE]",
        "[LAUGHTER]",
    ]

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    /// Removes Whisper hallucination artifacts like [BLANK_AUDIO] from text.
    /// Also strips whole-transcript phantom thank-yous (measured 3/513 archive clips, all
    /// turbo, all short quiet audio; a clip whose entire content is "Thank you." is a silence
    /// hallucination) and collapses runs of 3+ identical sentences (decoder repetition loops;
    /// pairs are kept - two repetitions is emphasis, three is a loop).
    static func removeArtifacts(from text: String) -> String {
        var cleaned = text
        for artifact in artifacts {
            cleaned = cleaned.replacingOccurrences(of: artifact, with: "")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSolePhantomThanks(cleaned) {
            return ""
        }
        return collapseImmediateRepeats(in: cleaned)
    }

    private static let phantomThanksPattern = try! NSRegularExpression(
        pattern: #"^(thank you|thanks)[.!…\s]*$"#, options: .caseInsensitive
    )

    static func isSolePhantomThanks(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return phantomThanksPattern.firstMatch(in: text, range: range) != nil
    }

    static func collapseImmediateRepeats(in text: String) -> String {
        let sentencePattern = try! NSRegularExpression(pattern: #"[^.!?]+[.!?]*"#)
        let range = NSRange(text.startIndex..., in: text)
        let sentences = sentencePattern.matches(in: text, range: range)
            .map { String(text[Range($0.range, in: text)!]) }
        guard sentences.count >= 3 else { return text }

        var out: [String] = []
        var i = 0
        while i < sentences.count {
            let current = sentences[i]
            let key = current.lowercased().components(separatedBy: .whitespacesAndNewlines).joined()
            var runEnd = i + 1
            while runEnd < sentences.count {
                let nextKey = sentences[runEnd].lowercased().components(separatedBy: .whitespacesAndNewlines).joined()
                guard nextKey == key else { break }
                runEnd += 1
            }
            out.append(current)  // a run of any length keeps its first sentence
            i = runEnd >= i + 3 ? runEnd : i + 1  // 3+ identical: skip the loop; 1-2: keep as said
        }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    /// Transcribes a 16 kHz mono PCM float audio buffer into text.
    ///
    /// - Parameter audioBuffer: Array of Float samples at 16 kHz sample rate, mono.
    /// - Returns: The transcribed text, or nil if the buffer is empty,
    ///   the model is not ready, or transcription produced no output.
    func transcribe(audioBuffer: [Float], language: String? = nil) async -> String? {
        guard !audioBuffer.isEmpty else { return nil }

        // Serialize concurrent transcription requests
        return await withCheckedContinuation { continuation in
            serialQueue.async { [semaphore] in
                semaphore.wait()
                let task = Task {
                    defer { semaphore.signal() }
                    return await self.modelManager.transcribe(audioBuffer: audioBuffer, language: language)
                }
                let result = Task {
                    await task.value
                }
                Task {
                    let value = await result.value
                    continuation.resume(returning: value)
                }
            }
        }
    }
}
