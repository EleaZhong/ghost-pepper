import Foundation

/// A baked dictation configuration (task:presets-only-ux): speech model + cleanup
/// on/off + cleanup model, born only from the voice-eval experiment loop. Presets are
/// the only model knobs the app exposes; the glossary, prompt shapes, and artifact
/// filters are shared infrastructure, and the voice tag stays a manual toggle.
struct DictationPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    let speechModelID: String
    let cleanupEnabled: Bool
    let cleanupModelKind: LocalCleanupModelKind
    /// OCR window context in the cleanup prompt. OFF in every current preset: the gold
    /// matrix was measured without OCR, so on is unmeasured. Capture-and-archive runs
    /// regardless, so a future eval can judge on vs off from the same archive.
    let ocrInCleanup: Bool
    /// Preferred/misheard lists inside the cleanup prompt. OFF: unmeasured. The glossary
    /// still feeds decode promptTokens (measured +8.9pt jargon recall on small.en).
    let cleanupHints: Bool

    /// Measured default: turbo + glossary prompt was 5.4% corpus WER / 73% jargon recall
    /// on the 100-clip gold; cleanup 2B removes fillers and self-corrections.
    static let standard = DictationPreset(
        id: "standard",
        title: "Standard",
        summary: "Whisper large-v3 turbo + glossary, cleanup on (Qwen 3.5 2B). The measured daily driver.",
        speechModelID: "openai_whisper-large-v3-v20240930_turbo_632MB",
        cleanupEnabled: true,
        cleanupModelKind: .qwen35_2b_q4_k_m,
        ocrInCleanup: false,
        cleanupHints: false
    )

    /// Lowest latency, cleanup off: raw turbo text, glossary still on.
    static let verbatim = DictationPreset(
        id: "verbatim",
        title: "Verbatim",
        summary: "Whisper large-v3 turbo + glossary, cleanup off. Raw ASR, fastest paste.",
        speechModelID: "openai_whisper-large-v3-v20240930_turbo_632MB",
        cleanupEnabled: false,
        cleanupModelKind: .qwen35_2b_q4_k_m,
        ocrInCleanup: false,
        cleanupHints: false
    )

    /// small.en for comparison days: measured 10.6% WER / 73% recall with the glossary.
    static let reference = DictationPreset(
        id: "reference-small-en",
        title: "Reference (small.en)",
        summary: "Whisper small.en + glossary, cleanup off. The pre-turbo baseline, kept for A/B days.",
        speechModelID: "openai_whisper-small.en",
        cleanupEnabled: false,
        cleanupModelKind: .qwen35_2b_q4_k_m,
        ocrInCleanup: false,
        cleanupHints: false
    )

    static let all: [DictationPreset] = [standard, verbatim, reference]
    static let `default` = standard

    static func preset(for id: String) -> DictationPreset {
        all.first { $0.id == id } ?? `default`
    }
}
