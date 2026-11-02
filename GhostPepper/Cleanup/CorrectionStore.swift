import Combine
import Foundation

struct MisheardReplacement: Codable, Equatable, Hashable, Sendable {
    let wrong: String
    let right: String

    init(wrong: String, right: String) {
        self.wrong = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        self.right = right.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class CorrectionStore: ObservableObject {
    @Published private(set) var commonlyMisheard: [MisheardReplacement]
    @Published private(set) var commonlyMisheardDraft: String

    var preferredOCRCustomWords: [String] {
        preferredTranscriptions
    }

    var commonlyMisheardText: String {
        get { commonlyMisheardDraft }
        set { updateCommonlyMisheard(from: newValue) }
    }

    /// The measured glossary (voice-eval: mined from atlas + session transcripts, reviewed
    /// by Elea, 2026-11-02). THE list: feeds Whisper promptTokens and OCR customWords, and
    /// cleanup CORRECTION-HINTS when a preset enables them. Not user-editable; new terms
    /// arrive baked, from the eval loop (task:preset-fidelity).
    static let glossaryPreset: [String] = [
        "lapse",
        "flywheel",
        "agentic",
        "recipipe",
        "bbml",
        "elex",
        "krea",
        "kreka",
        "devbox",
        "portboard",
        "gxfer",
        "pickpush",
        "posttrain",
        "pretrain",
        "dot-claude",
        "research-main",
        "ruleset",
        "pytorchjob",
        "tigris",
        "skim",
        "slogs",
        "krc",
        "rcc",
        "kqmono",
        "kueue",
        "krablet",
        "runstat",
        "pluck",
        "DSPy",
        "GEPA",
        "GRPO",
        "DPO",
        "tmux",
        "worktree",
        "uv",
        "venv",
        "zsh",
        "pyenv",
        "subagent",
        "FSDP",
        "LoRA",
        "NCCL",
        "DTensor",
        "SFT",
        "RLHF",
        "MCP",
        "MLX",
        "CoreML",
        "Qwen",
        "Postgres",
        "SQLite",
        "FastAPI",
        "uvicorn",
        "pydantic",
        "Kubernetes",
        "k8s",
        "PyTorch",
        "JAX",
        "tokenizer",
        "wandb",
        "weka",
        "GCS",
        "Claude",
        "Kimi",
        "Elea",
        "GitHub",
        "OpenAI",
        "Anthropic",
        "Gemini",
        "Hugging Face",
        "atlas",
        "JSON",
        "YAML",
        "SQL",
        "API",
        "CLI",
        "SDK",
        "LLM",
    ]

    private static let commonlyMisheardDefaultsKey = "commonlyMisheardDraft"

    private let defaults: UserDefaults

    /// The baked preset is the list; not user-editable (task:preset-fidelity).
    var preferredTranscriptions: [String] {
        Self.glossaryPreset
    }

    init(defaults: UserDefaults = .standard) {
        let commonlyMisheardDraft = defaults.string(forKey: Self.commonlyMisheardDefaultsKey) ?? ""

        self.defaults = defaults
        self.commonlyMisheardDraft = commonlyMisheardDraft
        self.commonlyMisheard = Self.parseCommonlyMisheard(from: commonlyMisheardDraft)
    }

    func updateCommonlyMisheard(from text: String) {
        commonlyMisheardDraft = text
        commonlyMisheard = Self.parseCommonlyMisheard(from: text)
        persistCommonlyMisheard()
    }

    func appendCommonlyMisheard(_ replacement: MisheardReplacement) {
        guard !replacement.wrong.isEmpty,
              !replacement.right.isEmpty,
              !commonlyMisheard.contains(replacement) else {
            return
        }

        let line = "\(replacement.wrong) -> \(replacement.right)"
        let separator = commonlyMisheardDraft.isEmpty || commonlyMisheardDraft.hasSuffix("\n") ? "" : "\n"
        updateCommonlyMisheard(from: commonlyMisheardDraft + separator + line)
    }

    private func persistCommonlyMisheard() {
        defaults.set(commonlyMisheardDraft, forKey: Self.commonlyMisheardDefaultsKey)
    }

    private static func parsePreferredTranscriptions(from text: String) -> [String] {
        uniqueValues(
            text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private static func parseCommonlyMisheard(from text: String) -> [MisheardReplacement] {
        let replacements = text
            .components(separatedBy: .newlines)
            .compactMap { line -> MisheardReplacement? in
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty else {
                    return nil
                }

                let parts = trimmedLine.components(separatedBy: "->")
                guard parts.count == 2 else {
                    return nil
                }

                let replacement = MisheardReplacement(
                    wrong: parts[0],
                    right: parts[1]
                )
                guard !replacement.wrong.isEmpty, !replacement.right.isEmpty else {
                    return nil
                }

                return replacement
            }

        return uniqueValues(replacements)
    }

    private static func uniqueValues<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}
