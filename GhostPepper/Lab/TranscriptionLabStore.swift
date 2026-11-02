import Foundation

struct TranscriptionLabStageTimings: Codable, Equatable {
    let transcriptionDuration: TimeInterval?
    let cleanupDuration: TimeInterval?
}

/// Append-only archive of every dictation: audio, transcripts, and stage timings.
/// Nothing here deletes. There is no entry cap, no pruning, and an unreadable
/// archive is an error for the caller, never a reason to reset the archive.
final class TranscriptionLabStore {
    private static let minimumDisplayableAudioDuration: TimeInterval = 0.05

    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// Entries worth showing in the Lab, newest first. Recordings too short to
    /// display as more than 0.0s are hidden here but stay in the archive.
    func loadEntries() throws -> [TranscriptionLabEntry] {
        try loadAllEntries()
            .filter { $0.audioDuration >= Self.minimumDisplayableAudioDuration }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Every archived entry, including ones hidden from the Lab.
    func loadAllEntries() throws -> [TranscriptionLabEntry] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return []
        }

        let data = try Data(contentsOf: indexURL)
        return try decoder.decode([TranscriptionLabEntry].self, from: data)
    }

    func loadStageTimings() throws -> [UUID: TranscriptionLabStageTimings] {
        guard FileManager.default.fileExists(atPath: timingsURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: timingsURL)
        let encodedTimings = try decoder.decode([String: TranscriptionLabStageTimings].self, from: data)
        return Dictionary(uniqueKeysWithValues: encodedTimings.compactMap { key, value in
            guard let entryID = UUID(uuidString: key) else {
                return nil
            }

            return (entryID, value)
        })
    }

    func insert(
        _ entry: TranscriptionLabEntry,
        audioData: Data,
        stageTimings: TranscriptionLabStageTimings
    ) throws {
        var entries = try loadAllEntries()
        var timings = try loadStageTimings()

        try FileManager.default.createDirectory(at: audioDirectoryURL, withIntermediateDirectories: true)
        try audioData.write(to: audioURL(for: entry.audioFileName), options: .atomic)

        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { $0.createdAt > $1.createdAt }
        timings[entry.id] = stageTimings

        try writeEntries(entries)
        try writeStageTimings(timings)
    }

    func audioURL(for audioFileName: String) -> URL {
        audioDirectoryURL.appendingPathComponent(audioFileName)
    }

    private var indexURL: URL {
        directoryURL.appendingPathComponent("transcription-lab-index.json")
    }

    private var audioDirectoryURL: URL {
        directoryURL.appendingPathComponent("audio", isDirectory: true)
    }

    private var timingsURL: URL {
        directoryURL.appendingPathComponent("transcription-lab-timings.json")
    }

    private func writeEntries(_ entries: [TranscriptionLabEntry]) throws {
        let data = try encoder.encode(entries)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: indexURL, options: .atomic)
    }

    private func writeStageTimings(_ timings: [UUID: TranscriptionLabStageTimings]) throws {
        let encodedTimings = Dictionary(uniqueKeysWithValues: timings.map { key, value in
            (key.uuidString, value)
        })
        let timingsData = try encoder.encode(encodedTimings)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try timingsData.write(to: timingsURL, options: .atomic)
    }

    private static var defaultDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("GhostPepper", isDirectory: true)
            .appendingPathComponent("transcription-lab", isDirectory: true)
    }
}
