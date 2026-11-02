import SwiftUI
import Combine
import CoreAudio
import ServiceManagement

enum AppStatus: String {
    case ready = "Ready"
    case loading = "Loading model..."
    case recording = "Recording..."
    case transcribing = "Transcribing..."
    case cleaningUp = "Cleaning up..."
    case error = "Error"
}

enum AppThemeID: String, CaseIterable, Identifiable {
    case current
    case windows95
    case space

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .current: "Default"
        case .windows95: "Windows 95"
        case .space: "Space"
        }
    }

    var subtitle: String {
        switch self {
        case .current: "The current Ghost Pepper skin."
        case .windows95: "Classic gray chrome, navy accents, and square edges."
        case .space: "Deep starfield panels with electric blue-violet accents."
        }
    }
}

struct AppTheme {
    static let storageKey = "appTheme"

    let id: AppThemeID

    static func resolve(_ rawValue: String) -> AppTheme {
        AppTheme(id: AppThemeID(rawValue: rawValue) ?? .current)
    }

    var accent: Color {
        switch id {
        case .current: .orange
        case .windows95: Color(red: 0.0, green: 0.0, blue: 0.50)
        case .space: Color(red: 0.45, green: 0.78, blue: 1.0)
        }
    }

    var accentText: Color {
        switch id {
        case .current, .windows95: .black
        case .space: Color(red: 0.02, green: 0.03, blue: 0.12)
        }
    }

    var windowBackground: Color {
        switch id {
        case .current: Color(nsColor: .windowBackgroundColor)
        case .windows95: Color(red: 0.78, green: 0.78, blue: 0.72)
        case .space: Color(red: 0.02, green: 0.03, blue: 0.12)
        }
    }

    var textBackground: Color {
        switch id {
        case .current: Color(nsColor: .textBackgroundColor)
        case .windows95: Color(red: 0.86, green: 0.86, blue: 0.80)
        case .space: Color(red: 0.05, green: 0.07, blue: 0.18)
        }
    }

    var controlBackground: Color {
        switch id {
        case .current: Color(nsColor: .controlBackgroundColor)
        case .windows95: Color(red: 0.75, green: 0.75, blue: 0.70)
        case .space: Color(red: 0.08, green: 0.10, blue: 0.26)
        }
    }

    var separator: Color {
        switch id {
        case .current: Color(nsColor: .separatorColor)
        case .windows95: Color.black.opacity(0.42)
        case .space: Color(red: 0.45, green: 0.78, blue: 1.0).opacity(0.28)
        }
    }

    var selectedFill: Color {
        switch id {
        case .current: Color(nsColor: .selectedContentBackgroundColor).opacity(0.22)
        case .windows95: Color(red: 0.0, green: 0.0, blue: 0.50).opacity(0.18)
        case .space: Color(red: 0.45, green: 0.22, blue: 0.90).opacity(0.28)
        }
    }

    var contextBubbleBackground: LinearGradient {
        switch id {
        case .current:
            LinearGradient(
                colors: [
                    Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)),
                    Color(nsColor: NSColor(red: 0.12, green: 0.09, blue: 0.06, alpha: 1))
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .windows95:
            LinearGradient(
                colors: [Color(red: 0.78, green: 0.78, blue: 0.72), Color(red: 0.68, green: 0.68, blue: 0.63)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .space:
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.03, blue: 0.14), Color(red: 0.15, green: 0.07, blue: 0.32)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    var usesDarkText: Bool {
        id == .windows95
    }
}

enum EmptyTranscriptionDisposition: Equatable {
    case cancel
    case showNoSoundDetected
}

@MainActor
class AppState: ObservableObject {
    enum PipelineOwner {
        case liveRecording
        case transcriptionLab
    }

    typealias CleanupResult = (
        text: String,
        prompt: String,
        attemptedCleanup: Bool,
        cleanupUsedFallback: Bool
    )
    typealias WindowContextProvider = @MainActor () async -> RecordingOCRPrefetchResult?

    private struct RecordingTranscriptionResult {
        let rawTranscription: String?
        let speakerFilteringRan: Bool
        let diarizationSummary: DiarizationSummary?
    }

    @Published var status: AppStatus = .loading
    @Published var isRecording: Bool = false
    @Published var errorMessage: String?
    @Published var shortcutErrorMessage: String?
    @Published var cleanupBackend: CleanupBackendOption {
        didSet {
            cleanupSettingsDefaults.set(cleanupBackend.rawValue, forKey: Self.cleanupBackendDefaultsKey)
        }
    }
    @Published var frontmostWindowContextEnabled: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                frontmostWindowContextEnabled,
                forKey: Self.frontmostWindowContextEnabledDefaultsKey
            )
        }
    }
    @Published var playSounds: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                playSounds,
                forKey: Self.playSoundsDefaultsKey
            )
        }
    }
    @Published private(set) var alwaysAllowedPasteApplications: [PasteTargetApplication] = []
    @AppStorage("cleanupEnabled") var cleanupEnabled: Bool = true
    @AppStorage("transcriptionLabEnabled") var transcriptionLabEnabled: Bool = false
    @AppStorage("cleanupPrompt") var cleanupPrompt: String = TextCleaner.defaultPrompt
    @AppStorage("transcriptionTagEnabled") var transcriptionTagEnabled: Bool = false
    @AppStorage("transcriptionTagText") var transcriptionTagText: String = "[voice]"
    @AppStorage("transcriptionTagIsPrefix") var transcriptionTagIsPrefix: Bool = true
    @AppStorage("speechModel") var speechModel: String = SpeechModelCatalog.defaultModelID
    @AppStorage("preferredLanguage") var preferredLanguage: String = "auto"
    @Published var showWhatsNew = false
    @AppStorage("pauseMediaWhileRecording") var pauseMediaWhileRecording: Bool = true
    @Published private(set) var pushToTalkChord: KeyChord
    @Published private(set) var toggleToTalkChord: KeyChord
    @Published private(set) var pepperChatChord: KeyChord
    @Published var postPasteLearningEnabled: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                postPasteLearningEnabled,
                forKey: Self.postPasteLearningEnabledDefaultsKey
            )
            postPasteLearningCoordinator.learningEnabled = postPasteLearningEnabled
        }
    }
    @Published var ignoreOtherSpeakers: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                ignoreOtherSpeakers,
                forKey: Self.ignoreOtherSpeakersDefaultsKey
            )
        }
    }
    @Published var selectedWikiModelKind: LocalCleanupModelKind {
        didSet {
            cleanupSettingsDefaults.set(
                selectedWikiModelKind.rawValue,
                forKey: Self.selectedWikiModelDefaultsKey
            )
        }
    }

    let modelManager: ModelManager
    let audioRecorder: AudioRecorder
    let transcriber: SpeechTranscriber
    let textPaster: TextPaster
    lazy var soundEffects = SoundEffects(isEnabled: { [weak self] in
        self?.playSounds ?? true
    })
    private lazy var mediaPlaybackController = MediaPlaybackController(enabled: { [weak self] in
        self?.pauseMediaWhileRecording ?? true
    })
    let hotkeyMonitor: HotkeyMonitoring
    let overlay = RecordingOverlayController()
    let textCleanupManager: TextCleanupManager
    let usageStats = UsageStatsStore()
    let frontmostWindowOCRService: FrontmostWindowOCRService
    let cleanupPromptBuilder: CleanupPromptBuilder
    let correctionStore: CorrectionStore
    let textCleaner: TextCleaner
    let chordBindingStore: ChordBindingStore
    let postPasteLearningCoordinator: PostPasteLearningCoordinator
    let debugLogStore: DebugLogStore
    let transcriptionLabStore: TranscriptionLabStore
    let recognizedVoiceStore: RecognizedVoiceStore
    let transcriptionLabSpeakerProfileStore: TranscriptionLabSpeakerProfileStore
    let appRelauncher: AppRelaunching
    var recordingSessionCoordinatorFactory: (() -> RecordingSessionCoordinator?)?
    var recordingTranscriptionSessionFactory: ((SpeechModelDescriptor) -> RecordingTranscriptionSession?)?
    var transcribeAudioBufferOverride: (([Float]) -> String?)?
    var cleanedTranscriptionResultOverride: ((String, OCRContext?) async -> CleanupResult)?
    private(set) var activeRecordingSessionCoordinator: RecordingSessionCoordinator?
    private(set) var activeRecordingTranscriptionSession: RecordingTranscriptionSession?

    var isReady: Bool {
        status == .ready
    }

    static func emptyTranscriptionDisposition(forAudioSampleCount sampleCount: Int) -> EmptyTranscriptionDisposition {
        if sampleCount < emptyTranscriptionCancelThresholdSampleCount {
            return .cancel
        }

        return .showNoSoundDetected
    }

    private var cleanupStateObserver: AnyCancellable?
    private var modelStateObserver: AnyCancellable?
    private var pushToTalkChordObserver: AnyCancellable?
    private var granolaImportObserver: AnyCancellable?
    private var peopleIndexEntryObserver: AnyCancellable?
    private let recordingOCRPrefetch: RecordingOCRPrefetch
    private let speakerIdentityResolver = SpeakerIdentityResolver()
    private var activePerformanceTrace: PerformanceTrace?
    private var activeCleanupAttempted = false
    private var pipelineOwner: PipelineOwner?
    private var speechAnalyzerReloadsInFlight = 0
    private var pendingMeetingSessionStarts = 0
    private let cleanupSettingsDefaults: UserDefaults
    private let inputMonitoringChecker: () -> Bool
    private let inputMonitoringPrompter: () -> Void
    private let selectedInputDeviceIDProvider: () -> AudioDeviceID?
    private let resetAudioRecorder: () -> Void
    private var hotkeyMonitorStarted = false

    private static let cleanupBackendDefaultsKey = "cleanupBackend"
    private static let frontmostWindowContextEnabledDefaultsKey = "frontmostWindowContextEnabled"
    private static let postPasteLearningEnabledDefaultsKey = "postPasteLearningEnabled"
    private static let ignoreOtherSpeakersDefaultsKey = "ignoreOtherSpeakers"
    private static let selectedWikiModelDefaultsKey = "selectedWikiModelKind"
    private static let playSoundsDefaultsKey = "playSounds"
    private static let alwaysAllowedPasteApplicationsDefaultsKey = "alwaysAllowedPasteApplications"
    private static let archivedRecordingSampleRate = 16_000.0
    private static let speechAnalyzerReloadPollIntervalNanoseconds: UInt64 = 10_000_000
    // History shows one decimal place, so shorter recordings render as 0.0s noise.
    private static let minimumArchivedRecordingSampleCount = 800
    private static let emptyTranscriptionCancelThresholdSampleCount = 8_000 // ~0.5 seconds — show "no sound" hint for almost all failed recordings
    private static let speechModelErrorPrefix = "Failed to load speech model: "
    static let liveRecordingNoInputErrorMessage = "Failed to start recording: No audio input device available."

    nonisolated static let defaultPushToTalkChord = KeyChord(keys: Set([
        PhysicalKey(keyCode: 54),  // Right Command
        PhysicalKey(keyCode: 61)   // Right Option
    ]))!

    nonisolated static let defaultToggleToTalkChord = KeyChord(keys: Set([
        PhysicalKey(keyCode: 54),  // Right Command
        PhysicalKey(keyCode: 61),  // Right Option
        PhysicalKey(keyCode: 49)   // Space
    ]))!

    nonisolated static let defaultPepperChatChord = KeyChord(keys: Set([
        PhysicalKey(keyCode: 54),  // Right Command
        PhysicalKey(keyCode: 31)   // O
    ]))!

    nonisolated static let defaultShortcutBindings: [ChordAction: KeyChord] = [
        .pushToTalk: defaultPushToTalkChord,
        .toggleToTalk: defaultToggleToTalkChord,
        .pepperChat: defaultPepperChatChord
    ]

    init(
        hotkeyMonitor: HotkeyMonitoring = HotkeyMonitor(bindings: AppState.defaultShortcutBindings),
        chordBindingStore: ChordBindingStore = ChordBindingStore(),
        cleanupSettingsDefaults: UserDefaults = .standard,
        modelManager: ModelManager? = nil,
        textCleanupManager: TextCleanupManager? = nil,
        frontmostWindowOCRService: FrontmostWindowOCRService = FrontmostWindowOCRService(),
        cleanupPromptBuilder: CleanupPromptBuilder = CleanupPromptBuilder(),
        correctionStore: CorrectionStore? = nil,
        audioRecorder: AudioRecorder = AudioRecorder(),
        textPaster: TextPaster = TextPaster(),
        debugLogStore: DebugLogStore = DebugLogStore(),
        transcriptionLabStore: TranscriptionLabStore = TranscriptionLabStore(),
        recognizedVoiceStore: RecognizedVoiceStore = RecognizedVoiceStore(),
        transcriptionLabSpeakerProfileStore: TranscriptionLabSpeakerProfileStore = TranscriptionLabSpeakerProfileStore(),
        appRelauncher: AppRelaunching? = nil,
        inputMonitoringChecker: @escaping () -> Bool = PermissionChecker.checkInputMonitoring,
        inputMonitoringPrompter: @escaping () -> Void = PermissionChecker.promptInputMonitoring,
        selectedInputDeviceIDProvider: @escaping () -> AudioDeviceID? = { AudioDeviceManager.selectedInputDeviceID() },
        resetAudioRecorder: (() -> Void)? = nil
    ) {
        self.hotkeyMonitor = hotkeyMonitor
        self.chordBindingStore = chordBindingStore
        self.cleanupSettingsDefaults = cleanupSettingsDefaults
        self.modelManager = modelManager ?? ModelManager()
        self.audioRecorder = audioRecorder
        self.textPaster = textPaster
        self.debugLogStore = debugLogStore
        self.transcriptionLabStore = transcriptionLabStore
        self.recognizedVoiceStore = recognizedVoiceStore
        self.transcriptionLabSpeakerProfileStore = transcriptionLabSpeakerProfileStore
        self.appRelauncher = appRelauncher ?? AppRelauncher()
        self.inputMonitoringChecker = inputMonitoringChecker
        self.inputMonitoringPrompter = inputMonitoringPrompter
        self.selectedInputDeviceIDProvider = selectedInputDeviceIDProvider
        self.resetAudioRecorder = resetAudioRecorder ?? { [audioRecorder] in
            audioRecorder.resetForDeviceChange()
        }
        self.pushToTalkChord = chordBindingStore.binding(for: .pushToTalk) ?? AppState.defaultPushToTalkChord
        self.toggleToTalkChord = chordBindingStore.binding(for: .toggleToTalk) ?? AppState.defaultToggleToTalkChord
        self.pepperChatChord = chordBindingStore.binding(for: .pepperChat) ?? AppState.defaultPepperChatChord
        self.textCleanupManager = textCleanupManager ?? TextCleanupManager(defaults: cleanupSettingsDefaults)
        self.frontmostWindowOCRService = frontmostWindowOCRService
        self.recordingOCRPrefetch = RecordingOCRPrefetch { [frontmostWindowOCRService] customWords in
            await frontmostWindowOCRService.captureContext(customWords: customWords)
        }
        self.cleanupPromptBuilder = cleanupPromptBuilder
        self.correctionStore = correctionStore ?? CorrectionStore(defaults: cleanupSettingsDefaults)
        let storedCleanupBackend = CleanupBackendOption(
            rawValue: cleanupSettingsDefaults.string(forKey: Self.cleanupBackendDefaultsKey) ?? ""
        ) ?? .localModels
        let storedFrontmostWindowContextEnabled = cleanupSettingsDefaults.bool(
            forKey: Self.frontmostWindowContextEnabledDefaultsKey
        )
        let storedPostPasteLearningEnabled: Bool
        if cleanupSettingsDefaults.object(forKey: Self.postPasteLearningEnabledDefaultsKey) == nil {
            storedPostPasteLearningEnabled = true
        } else {
            storedPostPasteLearningEnabled = cleanupSettingsDefaults.bool(
                forKey: Self.postPasteLearningEnabledDefaultsKey
            )
        }
        let storedIgnoreOtherSpeakers: Bool
        if cleanupSettingsDefaults.object(forKey: Self.ignoreOtherSpeakersDefaultsKey) == nil {
            storedIgnoreOtherSpeakers = false
        } else {
            storedIgnoreOtherSpeakers = cleanupSettingsDefaults.bool(
                forKey: Self.ignoreOtherSpeakersDefaultsKey
            )
        }
        self.cleanupBackend = storedCleanupBackend
        self.frontmostWindowContextEnabled = storedFrontmostWindowContextEnabled
        self.postPasteLearningEnabled = storedPostPasteLearningEnabled
        self.ignoreOtherSpeakers = storedIgnoreOtherSpeakers
        self.alwaysAllowedPasteApplications = Self.loadAlwaysAllowedPasteApplications(
            defaults: cleanupSettingsDefaults
        )
        let storedWikiModelKind = LocalCleanupModelKind(
            rawValue: cleanupSettingsDefaults.string(forKey: Self.selectedWikiModelDefaultsKey) ?? ""
        )
        self.selectedWikiModelKind = storedWikiModelKind == .gemma4_12b_it_optiq_4bit_mlx
            ? .wikiDefault
            : (storedWikiModelKind ?? .wikiDefault)
        if cleanupSettingsDefaults.object(forKey: Self.playSoundsDefaultsKey) == nil {
            self.playSounds = true
        } else {
            self.playSounds = cleanupSettingsDefaults.bool(forKey: Self.playSoundsDefaultsKey)
        }
        // One-time migration: enable meeting transcription for existing users on update
        self.transcriber = SpeechTranscriber(modelManager: self.modelManager)
        self.textCleaner = TextCleaner(
            cleanupManager: self.textCleanupManager,
            correctionStore: self.correctionStore
        )
        self.postPasteLearningCoordinator = PostPasteLearningCoordinator(
            correctionStore: self.correctionStore,
            learningEnabled: storedPostPasteLearningEnabled,
            revisit: { session in
                await PostPasteLearningObservationProvider.captureObservation(
                    for: session
                )
            }
        )

        // Forward nested model manager state changes so SwiftUI refreshes settings rows in place.
        self.modelManager.vocabularyPromptProvider = { [weak self] in
            self?.correctionStore.preferredTranscriptions ?? []
        }
        modelStateObserver = self.modelManager.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }

        // Forward cleanup manager state changes to trigger menu bar icon refresh.
        cleanupStateObserver = self.textCleanupManager.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }

        // One-time backfill of historical Meetings/Granola/People counts

        // People index entries fire `.indexEntryWritten` after each
        // `write_file` is finalized by the agent. We only count `.people` —
        // future index kinds would need their own counters or a separate
        cleanupSettingsDefaults.set(storedCleanupBackend.rawValue, forKey: Self.cleanupBackendDefaultsKey)
        cleanupSettingsDefaults.set(
            storedFrontmostWindowContextEnabled,
            forKey: Self.frontmostWindowContextEnabledDefaultsKey
        )
        cleanupSettingsDefaults.set(
            storedPostPasteLearningEnabled,
            forKey: Self.postPasteLearningEnabledDefaultsKey
        )
        cleanupSettingsDefaults.set(
            storedIgnoreOtherSpeakers,
            forKey: Self.ignoreOtherSpeakersDefaultsKey
        )
        cleanupSettingsDefaults.set(
            playSounds,
            forKey: Self.playSoundsDefaultsKey
        )
        persistShortcutBindingsIfNeeded()
        hotkeyMonitor.updateBindings(shortcutBindings)
        self.textPaster.onPaste = { [postPasteLearningCoordinator = self.postPasteLearningCoordinator] session in
            postPasteLearningCoordinator.handlePaste(session)
        }
        self.textPaster.configureAlwaysAllowedApplications { [weak self] bundleIdentifier in
            self?.alwaysAllowedPasteApplications.contains {
                $0.bundleIdentifier == bundleIdentifier
            } ?? false
        }
        self.audioRecorder.onRecordingStarted = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.micLiveAt = Date()
            }
        }
        self.audioRecorder.onRecordingStopped = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.micColdAt = Date()
            }
        }
        self.textPaster.onPasteStart = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.pasteStartAt = Date()
            }
        }
        self.textPaster.onPasteEnd = { [weak self] in
            Task { @MainActor in
                self?.completeActivePerformanceTraceIfNeeded()
            }
        }
        self.postPasteLearningCoordinator.onLearnedCorrection = { [weak overlay] replacement in
            Task { @MainActor in
                overlay?.show(message: .learnedCorrection(replacement))
            }
        }
        let componentDebugLogger: (DebugLogCategory, String) -> Void = { [weak debugLogStore] category, message in
            Task { @MainActor in
                debugLogStore?.record(category: category, message: message)
            }
        }
        let sensitiveComponentDebugLogger: (DebugLogCategory, String) -> Void = { [weak debugLogStore] category, message in
            Task { @MainActor in
                debugLogStore?.recordSensitive(category: category, message: message)
            }
        }
        if let hotkeyMonitor = hotkeyMonitor as? HotkeyMonitor {
            hotkeyMonitor.debugLogger = componentDebugLogger
        }
        self.textCleanupManager.debugLogger = componentDebugLogger
        self.frontmostWindowOCRService.debugLogger = componentDebugLogger
        self.frontmostWindowOCRService.sensitiveDebugLogger = sensitiveComponentDebugLogger
        self.textCleaner.debugLogger = componentDebugLogger
        self.textCleaner.sensitiveDebugLogger = sensitiveComponentDebugLogger
        self.postPasteLearningCoordinator.debugLogger = componentDebugLogger
        self.modelManager.debugLogger = componentDebugLogger
    }

    func initialize(skipPermissionPrompts: Bool = false) async {
        // Enable launch at login by default on first run
        if !UserDefaults.standard.bool(forKey: "hasSetLaunchAtLogin") {
            UserDefaults.standard.set(true, forKey: "hasSetLaunchAtLogin")
            try? SMAppService.mainApp.register()
        }

        if !skipPermissionPrompts {
            let hasMic = await PermissionChecker.checkMicrophone()
            if !hasMic {
                errorMessage = "Microphone access required"
                status = .error
                return
            }

            let needsAccessibility = !PermissionChecker.checkAccessibility()
            let needsInputMonitoring = !inputMonitoringChecker()
            if needsAccessibility || needsInputMonitoring {
                showSettings()
            }
        }

        // Show "What's New" dialog for returning users who haven't seen the meeting announcement
        // Wire up "no sound" overlay to open settings
        overlay.onNoSoundSettingsTapped = { [weak self] in
            self?.showSettings()
        }
        overlay.onAlwaysAllowPaste = { [weak self] in
            self?.alwaysAllowLastPasteTarget()
        }

        // Pre-warm audio engine so first recording starts faster
        audioRecorder.prewarm()
        FocusedElementLocator.startPasteTargetTracking()

        status = .loading
        let showOverlay = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        if showOverlay {
            overlay.show(message: .modelLoading)
        }
        debugLogStore.record(category: .model, message: "App initialization started.")
        if !modelManager.isReady || modelManager.modelName != speechModel {
            await loadSpeechModel(name: speechModel)
        }
        if showOverlay {
            overlay.dismiss()
        }

        guard modelManager.isReady else {
            return
        }

        await startHotkeyMonitor()

        await refreshCleanupModelState()

    }

    func relaunchApp() {
        do {
            try appRelauncher.relaunch()
        } catch {
            errorMessage = "Failed to relaunch Ghost Pepper: \(error.localizedDescription)"
        }
    }

    func startHotkeyMonitor() async {
        hotkeyMonitor.onRecordingStart = nil
        hotkeyMonitor.onRecordingStop = nil
        hotkeyMonitor.onRecordingRestart = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Push-to-talk upgraded to toggle — reset buffer only if recording just started
                // (less than 1 second of audio at 16kHz). If they've been talking longer, keep it.
                let sampleCount = self.audioRecorder.audioBuffer.count
                if sampleCount < 16000 {
                    self.audioRecorder.resetBuffer()
                    self.debugLogStore.record(category: .hotkey, message: "Recording restarted (push-to-talk upgraded to toggle, \(sampleCount) samples discarded).")
                } else {
                    self.debugLogStore.record(category: .hotkey, message: "Push-to-talk upgraded to toggle, keeping \(sampleCount) samples of existing audio.")
                }
            }
        }

        hotkeyMonitor.onPushToTalkStart = { [weak self] in
            Task { @MainActor in
                self?.beginPerformanceTrace()
                await self?.startRecording()
            }
        }
        hotkeyMonitor.onPushToTalkStop = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.hotkeyLiftedAt = Date()
                await self?.stopRecordingAndTranscribe()
            }
        }
        hotkeyMonitor.onToggleToTalkStart = { [weak self] in
            Task { @MainActor in
                self?.beginPerformanceTrace()
                await self?.startRecording()
            }
        }
        hotkeyMonitor.onToggleToTalkStop = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.hotkeyLiftedAt = Date()
                await self?.stopRecordingAndTranscribe()
            }
        }

        hotkeyMonitor.updateBindings(shortcutBindings)

        if hotkeyMonitorStarted {
            debugLogStore.record(category: .hotkey, message: "Hotkey monitor start skipped because it is already active.")
            if status != .error {
                status = .ready
                errorMessage = nil
            }
            return
        }

        if !inputMonitoringChecker() {
            // Try to prompt, but don't block — Accessibility alone may be sufficient
            inputMonitoringPrompter()
            debugLogStore.record(category: .hotkey, message: "Input Monitoring not granted, attempting to start with Accessibility only.")
        }

        if hotkeyMonitor.start() {
            hotkeyMonitorStarted = true
            status = .ready
            errorMessage = nil
            debugLogStore.record(category: .hotkey, message: "Hotkey monitor is ready.")
        } else {
            PermissionChecker.promptAccessibility()
            errorMessage = "Accessibility access required — grant permission then click Retry"
            status = .error
            debugLogStore.record(category: .hotkey, message: errorMessage ?? "Accessibility access required.")
        }
    }

    func prepareRecordingSessionIfNeeded() async {
        audioRecorder.onConvertedAudioChunk = nil
        activeRecordingSessionCoordinator = nil
        activeRecordingTranscriptionSession = nil

        if let speechModelDescriptor = SpeechModelCatalog.model(named: speechModel) {
            if let recordingTranscriptionSessionFactory {
                activeRecordingTranscriptionSession = recordingTranscriptionSessionFactory(
                    speechModelDescriptor
                )
            } else if let recordingTranscriptionSession = modelManager.makeRecordingTranscriptionSession(
                language: preferredLanguage == "auto" ? nil : preferredLanguage
            ) {
                activeRecordingTranscriptionSession = recordingTranscriptionSession
            } else if speechModelDescriptor.backend == .fluidAudio {
                activeRecordingTranscriptionSession = ChunkedRecordingTranscriptionSession(
                    transcribeChunk: { [weak self] samples in
                        await self?.transcribeAudioBuffer(samples)
                    }
                )
            }
        }

        guard ignoreOtherSpeakers, selectedSpeechModelSupportsSpeakerFiltering else {
            if let activeRecordingTranscriptionSession {
                audioRecorder.onConvertedAudioChunk = { [weak activeRecordingTranscriptionSession] samples in
                    activeRecordingTranscriptionSession?.appendAudioChunk(samples)
                }
            }
            return
        }

        let coordinator: RecordingSessionCoordinator?
        if let recordingSessionCoordinatorFactory {
            coordinator = recordingSessionCoordinatorFactory()
        } else {
            coordinator = await modelManager.makeRecordingSessionCoordinator()
        }

        guard let coordinator else {
            if let activeRecordingTranscriptionSession {
                audioRecorder.onConvertedAudioChunk = { [weak activeRecordingTranscriptionSession] samples in
                    activeRecordingTranscriptionSession?.appendAudioChunk(samples)
                }
            }
            return
        }

        activeRecordingSessionCoordinator = coordinator
        audioRecorder.onConvertedAudioChunk = {
            [weak coordinator, weak activeRecordingTranscriptionSession] samples in
            coordinator?.appendAudioChunk(samples)
            activeRecordingTranscriptionSession?.appendAudioChunk(samples)
        }
    }

    private func clearRecordingSessionCoordinator() {
        audioRecorder.onConvertedAudioChunk = nil
        activeRecordingSessionCoordinator = nil
        activeRecordingTranscriptionSession = nil
    }

    private var selectedSpeechModelSupportsSpeakerFiltering: Bool {
        SpeechModelCatalog.model(named: speechModel)?.supportsSpeakerFiltering == true
    }

    private var canStartSpeechAnalyzerConsumer: Bool {
        guard SpeechModelCatalog.model(named: speechModel)?.backend == .speechAnalyzer else {
            return true
        }

        return status == .ready
            && modelManager.isReady
            && modelManager.modelName == speechModel
            && speechAnalyzerReloadsInFlight == 0
    }

    private func startRecording() async {
        // If the selected speech model isn't ready, show loading message
        guard status == .ready,
              modelManager.isReady,
              modelManager.modelName == speechModel,
              speechAnalyzerReloadsInFlight == 0 else {
            debugLogStore.record(
                category: .hotkey,
                message: "Recording start skipped because app is not ready. status=\(status.rawValue), modelReady=\(modelManager.isReady), loadedSpeechModel=\(modelManager.modelName), selectedSpeechModel=\(speechModel), speechAnalyzerReloadsInFlight=\(speechAnalyzerReloadsInFlight)"
            )
            if status == .loading
                || !modelManager.isReady
                || modelManager.modelName != speechModel
                || speechAnalyzerReloadsInFlight > 0 {
                overlay.show(message: .modelLoading)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.overlay.dismiss()
                }
            }
            return
        }

        if activePerformanceTrace == nil {
            beginPerformanceTrace()
        }

        guard acquirePipeline(for: .liveRecording) else {
            debugLogStore.record(category: .hotkey, message: "Recording start skipped because the transcription pipeline is busy.")
            activePerformanceTrace = nil
            activeCleanupAttempted = false
            return
        }

        do {
            await prepareRecordingSessionIfNeeded()
            if cleanupEnabled && canAttemptCleanup && frontmostWindowContextEnabled {
                recordingOCRPrefetch.start(customWords: ocrCustomWords)
            } else {
                recordingOCRPrefetch.cancel()
            }
            if cleanupEnabled && canAttemptCleanup {
                let promptComponents = activeCleanupPromptComponents(windowContext: nil)
                textCleanupManager.startPromptPrefill(
                    systemPromptPrefix: promptComponents.stablePromptPrefix,
                    modelKind: textCleanupManager.selectedCleanupModelKind
                )
            } else {
                textCleanupManager.cancelPromptPrefill()
            }
            mediaPlaybackController.pauseIfPlaying()
            audioRecorder.targetDeviceID = selectedInputDeviceIDProvider()
            try audioRecorder.startRecording()
            debugLogStore.record(category: .hotkey, message: "Recording started.")
            soundEffects.playStart()
            overlay.show(message: .recording)
            isRecording = true
            status = .recording
        } catch {
            recordingOCRPrefetch.cancel()
            releasePipeline(owner: .liveRecording)
            activePerformanceTrace = nil
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            status = .error
        }
    }

    private var isTranscribing = false

    private func stopRecordingAndTranscribe() async {
        guard status == .recording, !isTranscribing else { return }
        isTranscribing = true
        defer { isTranscribing = false }

        debugLogStore.record(category: .hotkey, message: "Recording stopped. Starting transcription.")
        let buffer = await audioRecorder.stopRecording()
        let recordingSessionCoordinator = activeRecordingSessionCoordinator
        let recordingTranscriptionSession = activeRecordingTranscriptionSession
        clearRecordingSessionCoordinator()
        soundEffects.playStop()
        mediaPlaybackController.resumeIfPaused()
        isRecording = false
        status = .transcribing
        overlay.show(message: .transcribing)
        activePerformanceTrace?.transcriptionStartAt = Date()
        let windowContextProvider: WindowContextProvider?
        if frontmostWindowContextEnabled {
            windowContextProvider = { [weak self] in
                await self?.recordingOCRPrefetch.resolve()
            }
        } else {
            windowContextProvider = nil
        }

        let didProduceTranscript = await processRecordingResult(
            audioBuffer: buffer,
            recordingSessionCoordinator: recordingSessionCoordinator,
            recordingTranscriptionSession: recordingTranscriptionSession,
            archivedWindowContext: nil,
            windowContextProvider: windowContextProvider,
            shouldPaste: true,
            shouldRecordDebugSnapshot: true
        )

        if didProduceTranscript {
            usageStats.record(.dictation)
            overlay.dismiss(ifShowing: .transcribing)
            overlay.dismiss(ifShowing: .cleaningUp)
        } else {
            switch Self.emptyTranscriptionDisposition(forAudioSampleCount: buffer.count) {
            case .cancel:
                overlay.dismiss()
                debugLogStore.record(category: .model, message: "Empty transcription cancelled after a short recording.")
            case .showNoSoundDetected:
                overlay.show(message: .noSoundDetected)
                debugLogStore.record(category: .model, message: "No sound detected. Check mic in Settings → Recording.")
            }
            completeActivePerformanceTraceIfNeeded()
        }

        status = .ready
        releasePipeline(owner: .liveRecording)
    }

    func finishRecordingForTesting(
        audioBuffer: [Float],
        recordingSessionCoordinator: RecordingSessionCoordinator?,
        recordingTranscriptionSession: RecordingTranscriptionSession? = nil,
        archivedWindowContext: OCRContext?,
        windowContextProvider: WindowContextProvider? = nil
    ) async {
        _ = await processRecordingResult(
            audioBuffer: audioBuffer,
            recordingSessionCoordinator: recordingSessionCoordinator,
            recordingTranscriptionSession: recordingTranscriptionSession,
            archivedWindowContext: archivedWindowContext,
            windowContextProvider: windowContextProvider,
            shouldPaste: false,
            shouldRecordDebugSnapshot: false
        )
    }

    private func processRecordingResult(
        audioBuffer: [Float],
        recordingSessionCoordinator: RecordingSessionCoordinator?,
        recordingTranscriptionSession: RecordingTranscriptionSession?,
        archivedWindowContext: OCRContext?,
        windowContextProvider: WindowContextProvider?,
        shouldPaste: Bool,
        shouldRecordDebugSnapshot: Bool
    ) async -> Bool {
        let transcriptionResult = await transcribedTextForRecording(
            audioBuffer,
            recordingSessionCoordinator: recordingSessionCoordinator,
            recordingTranscriptionSession: recordingTranscriptionSession
        )

        guard let text = transcriptionResult.rawTranscription else {
            recordingOCRPrefetch.cancel()
            await archiveRecordingForLab(
                audioBuffer: audioBuffer,
                windowContext: archivedWindowContext,
                rawTranscription: nil,
                correctedTranscription: nil,
                cleanupUsedFallback: false,
                speakerFilteringEnabled: ignoreOtherSpeakers && selectedSpeechModelSupportsSpeakerFiltering,
                speakerFilteringRan: transcriptionResult.speakerFilteringRan,
                diarizationSummary: transcriptionResult.diarizationSummary
            )
            activePerformanceTrace?.transcriptionEndAt = Date()
            return false
        }

        activePerformanceTrace?.transcriptionEndAt = Date()
        var windowContext = archivedWindowContext
        if cleanupEnabled && canAttemptCleanup {
            activeCleanupAttempted = true
            if frontmostWindowContextEnabled,
               windowContext == nil,
               let resolvedWindowContext = await windowContextProvider?() {
                windowContext = resolvedWindowContext.context
                activePerformanceTrace?.ocrCaptureDuration = resolvedWindowContext.elapsed
            }
            activePerformanceTrace?.cleanupStartAt = Date()
            status = .cleaningUp
            if shouldPaste {
                overlay.show(message: .cleaningUp)
            }
            if frontmostWindowContextEnabled, windowContext == nil {
                debugLogStore.record(category: .ocr, message: "No frontmost-window OCR context was captured.")
            }
        } else {
            recordingOCRPrefetch.cancel()
        }

        let cleanupResult = await cleanedTranscriptionResult(text, windowContext: windowContext)
        let finalText = cleanupResult.text
        activeCleanupAttempted = cleanupResult.attemptedCleanup
        if cleanupResult.attemptedCleanup {
            activePerformanceTrace?.cleanupEndAt = Date()
        }

        await archiveRecordingForLab(
            audioBuffer: audioBuffer,
            windowContext: windowContext,
            rawTranscription: text,
            correctedTranscription: finalText,
            cleanupUsedFallback: cleanupResult.cleanupUsedFallback,
            speakerFilteringEnabled: ignoreOtherSpeakers && selectedSpeechModelSupportsSpeakerFiltering,
            speakerFilteringRan: transcriptionResult.speakerFilteringRan,
            diarizationSummary: transcriptionResult.diarizationSummary
        )

        if shouldRecordDebugSnapshot {
            recordCleanupDebugSnapshot(
                rawTranscription: text,
                windowContext: windowContext,
                cleanedOutput: finalText,
                attemptedCleanup: cleanupResult.attemptedCleanup
            )
        }

        if shouldPaste {
            let pasteResult = textPaster.paste(text: taggedForPaste(finalText))
            if pasteResult == .copiedToClipboard {
                showClipboardFallbackMessage()
            }
        }

        return true
    }

    private func taggedForPaste(_ text: String) -> String {
        guard transcriptionTagEnabled, !transcriptionTagText.isEmpty else { return text }
        return transcriptionTagIsPrefix ? "\(transcriptionTagText) \(text)" : "\(text) \(transcriptionTagText)"
    }

    private func transcribedTextForRecording(
        _ audioBuffer: [Float],
        recordingSessionCoordinator: RecordingSessionCoordinator?,
        recordingTranscriptionSession: RecordingTranscriptionSession?
    ) async -> RecordingTranscriptionResult {
        let diarizationTask = recordingSessionCoordinator.map { coordinator in
            Task {
                await coordinator.finishResult()
            }
        }
        let concurrentRecordingTranscriptionSession: RecordingTranscriptionSession?
        if let recordingTranscriptionSession,
           recordingTranscriptionSession.supportsConcurrentFinalization {
            concurrentRecordingTranscriptionSession = recordingTranscriptionSession
        } else {
            concurrentRecordingTranscriptionSession = nil
        }

        let streamedTranscriptTask = concurrentRecordingTranscriptionSession.map { session in
            Task<String?, Never> {
                await session.finishTranscription()?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var diarizationSummary: DiarizationSummary?
        if let diarizationTask {
            let diarizationResult = await diarizationTask.value
            diarizationSummary = diarizationResult.summary

            if diarizationResult.summary.usedFallback == false,
               let filteredTranscript = diarizationResult.filteredTranscript?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               filteredTranscript.isEmpty == false {
                recordingTranscriptionSession?.cancel()
                return RecordingTranscriptionResult(
                    rawTranscription: filteredTranscript,
                    speakerFilteringRan: true,
                    diarizationSummary: diarizationResult.summary
                )
            }
        }

        if let streamedTranscriptTask,
           let streamedTranscript = await streamedTranscriptTask.value,
           streamedTranscript.isEmpty == false {
            return RecordingTranscriptionResult(
                rawTranscription: streamedTranscript,
                speakerFilteringRan: recordingSessionCoordinator != nil,
                diarizationSummary: diarizationSummary
            )
        }

        if concurrentRecordingTranscriptionSession == nil,
           let recordingTranscriptionSession,
           let streamedTranscript = await recordingTranscriptionSession.finishTranscription()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           streamedTranscript.isEmpty == false {
            return RecordingTranscriptionResult(
                rawTranscription: streamedTranscript,
                speakerFilteringRan: recordingSessionCoordinator != nil,
                diarizationSummary: diarizationSummary
            )
        }

        if let recordingTranscriptionSession,
           recordingTranscriptionSession.allowsBatchFallback == false {
            return RecordingTranscriptionResult(
                rawTranscription: nil,
                speakerFilteringRan: recordingSessionCoordinator != nil,
                diarizationSummary: diarizationSummary
            )
        }

        return RecordingTranscriptionResult(
            rawTranscription: await transcribeAudioBuffer(audioBuffer),
            speakerFilteringRan: recordingSessionCoordinator != nil,
            diarizationSummary: diarizationSummary
        )
    }

    private func transcribeAudioBuffer(_ audioBuffer: [Float]) async -> String? {
        if let transcribeAudioBufferOverride {
            return transcribeAudioBufferOverride(audioBuffer)
        }

        let language = preferredLanguage == "auto" ? nil : preferredLanguage
        return await transcriber.transcribe(audioBuffer: audioBuffer, language: language)
    }

    func cleanedTranscription(_ text: String) async -> String {
        let result = await cleanedTranscriptionResult(text, windowContext: nil)
        return result.text
    }

    private func showClipboardFallbackMessage() {
        overlay.show(message: .clipboardFallback(
            appName: textPaster.lastPasteTargetApplication?.displayName
        ))
    }

    func removeAlwaysAllowedPasteApplication(bundleIdentifier: String) {
        alwaysAllowedPasteApplications.removeAll { $0.bundleIdentifier == bundleIdentifier }
        persistAlwaysAllowedPasteApplications()
    }

    private func alwaysAllowLastPasteTarget() {
        guard let application = textPaster.lastPasteTargetApplication else { return }
        if !alwaysAllowedPasteApplications.contains(where: {
            $0.bundleIdentifier == application.bundleIdentifier
        }) {
            alwaysAllowedPasteApplications.append(application)
            alwaysAllowedPasteApplications.sort {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            persistAlwaysAllowedPasteApplications()
        }
        _ = textPaster.retryLastClipboardPaste()
        overlay.dismiss()
    }

    private func persistAlwaysAllowedPasteApplications() {
        guard let data = try? JSONEncoder().encode(alwaysAllowedPasteApplications) else { return }
        cleanupSettingsDefaults.set(data, forKey: Self.alwaysAllowedPasteApplicationsDefaultsKey)
    }

    private static func loadAlwaysAllowedPasteApplications(
        defaults: UserDefaults
    ) -> [PasteTargetApplication] {
        guard let data = defaults.data(forKey: alwaysAllowedPasteApplicationsDefaultsKey),
              let applications = try? JSONDecoder().decode([PasteTargetApplication].self, from: data) else {
            return []
        }
        return applications
    }

    private let settingsController = SettingsWindowController()
    private let promptEditorController = PromptEditorController()
    private let cleanupTranscriptWindowController = CleanupTranscriptWindowController()
    private let debugLogWindowController = DebugLogWindowController()

    var canReloadAudioInput: Bool {
        Self.isLiveRecordingNoInputError(errorMessage)
    }

    func resetAudioEngine() {
        audioRecorder.targetDeviceID = selectedInputDeviceIDProvider()
        resetAudioRecorder()

        if shouldClearLiveRecordingNoInputErrorAfterAudioReset {
            errorMessage = nil
            status = .ready
            debugLogStore.record(category: .model, message: "Audio engine reset cleared stale no-input recording error.")
        }

        debugLogStore.record(category: .model, message: "Audio engine reset for device change.")
    }

    func showSettings(section: SettingsSection? = nil) {
        settingsController.show(appState: self, section: section)
    }

    func showPromptEditor() {
        promptEditorController.show(appState: self)
    }

    func showCleanupTranscript(_ transcript: TranscriptionLabCleanupTranscript) {
        cleanupTranscriptWindowController.show(transcript: transcript)
    }

    func showDebugLog() {
        debugLogWindowController.show(debugLogStore: debugLogStore)
    }





    /// Capture the current frontmost window's context (if it's a new/different window)




    // MARK: - Meeting Transcript

    /// Creates a new MeetingSession, starts recording, and returns it.
    /// Called by the window state when the user clicks "+" or auto-detection triggers.











    private func postCallSpeakerProfiles(
        _ profiles: [TranscriptionLabSpeakerProfile],
        for speakerTaggedTranscript: SpeakerTaggedTranscript
    ) -> [TranscriptionLabSpeakerProfile] {
        let speakerDisplayNames = Self.fallbackSpeakerDisplayNames(for: speakerTaggedTranscript)
        return profiles.map { profile in
            guard let fallbackName = speakerDisplayNames[profile.speakerID],
                  Self.isPlaceholderSpeakerDisplayName(profile.displayName, speakerID: profile.speakerID) else {
                return profile
            }

            var updatedProfile = profile
            updatedProfile.displayName = fallbackName
            try? transcriptionLabSpeakerProfileStore.upsert(updatedProfile)
            return updatedProfile
        }
    }

    private static func fallbackSpeakerDisplayNames(
        for speakerTaggedTranscript: SpeakerTaggedTranscript
    ) -> [String: String] {
        var orderedSpeakerIDs: [String] = []
        for segment in speakerTaggedTranscript.segments where !orderedSpeakerIDs.contains(segment.speakerID) {
            orderedSpeakerIDs.append(segment.speakerID)
        }

        return Dictionary(
            uniqueKeysWithValues: orderedSpeakerIDs.enumerated().map { offset, speakerID in
                (speakerID, "Speaker \(offset + 1)")
            }
        )
    }

    private static func isPlaceholderSpeakerDisplayName(_ displayName: String, speakerID: String) -> Bool {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ||
            normalized == speakerID ||
            normalized.hasPrefix("Recognized Voice ")
    }

    private static func truncatedSpeakerEvidence(_ text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 220 else {
            return normalized
        }

        let endIndex = normalized.index(normalized.startIndex, offsetBy: 220)
        return String(normalized[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    // MARK: - Index updates










    private func displayName(forWikiModel model: LocalCleanupModelKind) -> String {
        TextCleanupManager.cleanupModels.first(where: { $0.kind == model })?.displayName ?? model.rawValue
    }



    /// Resolves the index builder for a kind, backend-aware:
    /// - Agent backend = Claude AND an API key exists → the Claude-driven
    ///   `IndexBuilder` (higher narrative quality, costs tokens).
    /// - Otherwise → the token-free `LocalWikiEngine`.
    ///
    /// The Claude builder cache is keyed on the model — if the user changes
    /// their selection in Settings or the build sheet, the next call
    /// recreates the builder rather than returning a stale one.

    /// Re-resolves the index builders when the API key or model changes.


    /// Once enough meeting cards exist, occasionally ask the local model to
    /// propose new wiki kinds. Proposals surface in the sidebar for approval;
    /// nothing is created without the user saying yes.

    private var shortcutBindings: [ChordAction: KeyChord] {
        var bindings: [ChordAction: KeyChord] = [
            .pushToTalk: pushToTalkChord,
            .toggleToTalk: toggleToTalkChord
        ]

        return bindings
    }

    private func persistShortcutBindingsIfNeeded() {
        try? chordBindingStore.setBinding(pushToTalkChord, for: .pushToTalk)
        try? chordBindingStore.setBinding(toggleToTalkChord, for: .toggleToTalk)
    }

    private var canAttemptCleanup: Bool {
        textCleanupManager.isReady
    }

    var shouldLoadLocalCleanupModels: Bool {
        cleanupEnabled
    }

    private func cleanedTranscriptionResult(
        _ text: String,
        windowContext: OCRContext?
    ) async -> CleanupResult {
        if let cleanedTranscriptionResultOverride {
            return await cleanedTranscriptionResultOverride(text, windowContext)
        }

        guard cleanupEnabled else {
            return (text: text, prompt: cleanupPrompt, attemptedCleanup: false, cleanupUsedFallback: false)
        }

        let activeCleanupPrompt: String
        if canAttemptCleanup {
            let promptBuildStart = Date()
            activeCleanupPrompt = activeCleanupPromptComponents(windowContext: windowContext).fullPrompt
            activePerformanceTrace?.promptBuildDuration = Date().timeIntervalSince(promptBuildStart)
        } else {
            activeCleanupPrompt = languageAwareCleanupPrompt
        }

        let cleanedResult = await textCleaner.cleanWithPerformance(
            text: text,
            prompt: activeCleanupPrompt,
            modelKind: textCleanupManager.selectedCleanupModelKind
        )
        activePerformanceTrace?.modelCallDuration = cleanedResult.performance.modelCallDuration
        activePerformanceTrace?.postProcessDuration = cleanedResult.performance.postProcessDuration
        return (
            text: cleanedResult.text,
            prompt: activeCleanupPrompt,
            attemptedCleanup: canAttemptCleanup,
            cleanupUsedFallback: cleanedResult.usedFallback
        )
    }

    private var languageAwareCleanupPrompt: String {
        if preferredLanguage != "auto" && preferredLanguage != "en" {
            let langName = Locale.current.localizedString(forLanguageCode: preferredLanguage) ?? preferredLanguage
            return cleanupPrompt + "\n\nThe transcription is in \(langName). Preserve the original language — do not translate to English."
        }

        return cleanupPrompt
    }

    private func activeCleanupPromptComponents(windowContext: OCRContext?) -> CleanupPromptComponents {
        cleanupPromptBuilder.buildPromptComponents(
            basePrompt: languageAwareCleanupPrompt,
            windowContext: windowContext,
            preferredTranscriptions: correctionStore.preferredTranscriptions,
            commonlyMisheard: correctionStore.commonlyMisheard,
            includeWindowContext: frontmostWindowContextEnabled
        )
    }

    var ocrCustomWords: [String] {
        correctionStore.preferredOCRCustomWords
    }

    func recordCleanupDebugSnapshot(
        rawTranscription: String,
        windowContext: OCRContext?,
        cleanedOutput: String,
        attemptedCleanup: Bool
    ) {
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: """
            Raw transcription:
            \(rawTranscription)
            """
        )
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: "cleanupEnabled=\(cleanupEnabled) attemptedCleanup=\(attemptedCleanup) backend=\(cleanupBackend.rawValue)"
        )
        let windowContextSummary = windowContext?.windowContents.isEmpty == false ? "captured" : "none"
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: "Cleanup context summary: windowContext=\(windowContextSummary)"
        )
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: "Final cleaned output:\n\(cleanedOutput)"
        )
    }

    private func beginPerformanceTrace() {
        var trace = PerformanceTrace(sessionID: UUID().uuidString)
        trace.hotkeyDetectedAt = Date()
        activePerformanceTrace = trace
        activeCleanupAttempted = false
    }

    private func completeActivePerformanceTraceIfNeeded() {
        guard var trace = activePerformanceTrace else {
            return
        }

        if trace.pasteEndAt == nil {
            trace.pasteEndAt = Date()
        }

        debugLogStore.record(
            category: .performance,
            message: trace.summary(
                speechModelID: speechModel,
                cleanupBackend: cleanupBackend,
                cleanupAttempted: activeCleanupAttempted
            )
        )

        activePerformanceTrace = nil
        activeCleanupAttempted = false
        recordingOCRPrefetch.cancel()
    }

    func archiveRecordingForLab(
        audioBuffer: [Float],
        windowContext: OCRContext?,
        rawTranscription: String?,
        correctedTranscription: String?,
        cleanupUsedFallback: Bool,
        speakerFilteringEnabled: Bool = false,
        speakerFilteringRan: Bool = false,
        diarizationSummary: DiarizationSummary? = nil
    ) async {
        guard transcriptionLabEnabled, audioBuffer.count >= Self.minimumArchivedRecordingSampleCount else {
            return
        }

        let entryID = UUID()
        let audioFileName = "\(entryID.uuidString).wav"
        do {
            let audioData = try AudioRecorder.serializePlayableArchiveAudioBuffer(audioBuffer)
            let transcriptionDuration: TimeInterval?
            if let start = activePerformanceTrace?.transcriptionStartAt,
               let end = activePerformanceTrace?.transcriptionEndAt {
                transcriptionDuration = end.timeIntervalSince(start)
            } else {
                transcriptionDuration = nil
            }
            let cleanupDuration: TimeInterval?
            if let start = activePerformanceTrace?.cleanupStartAt,
               let end = activePerformanceTrace?.cleanupEndAt {
                cleanupDuration = end.timeIntervalSince(start)
            } else {
                cleanupDuration = nil
            }
            let entry = TranscriptionLabEntry(
                id: entryID,
                createdAt: Date(),
                audioFileName: audioFileName,
                audioDuration: Double(audioBuffer.count) / Self.archivedRecordingSampleRate,
                windowContext: windowContext,
                rawTranscription: rawTranscription,
                correctedTranscription: correctedTranscription,
                speechModelID: speechModel,
                cleanupModelName: cleanupEnabled ? textCleanupManager.selectedCleanupModelDisplayName : "Cleanup disabled",
                cleanupUsedFallback: cleanupUsedFallback,
                speakerFilteringEnabled: speakerFilteringEnabled,
                speakerFilteringRan: speakerFilteringRan,
                speakerFilteringUsedFallback: diarizationSummary?.usedFallback ?? false,
                diarizationSummary: diarizationSummary
            )
            let stageTimings = TranscriptionLabStageTimings(
                transcriptionDuration: transcriptionDuration,
                cleanupDuration: cleanupDuration
            )
            try transcriptionLabStore.insert(entry, audioData: audioData, stageTimings: stageTimings)
        } catch {
            debugLogStore.record(category: .model, message: "Failed to archive transcription lab recording: \(error.localizedDescription)")
        }
    }

    func loadTranscriptionLabEntries() throws -> [TranscriptionLabEntry] {
        try transcriptionLabStore.loadEntries()
    }

    func loadTranscriptionLabStageTimings() throws -> [UUID: TranscriptionLabStageTimings] {
        try transcriptionLabStore.loadStageTimings()
    }

    func loadRecognizedVoiceProfiles() throws -> [RecognizedVoiceProfile] {
        try recognizedVoiceStore.loadProfiles()
    }

    func upsertRecognizedVoiceProfile(_ profile: RecognizedVoiceProfile) throws {
        try recognizedVoiceStore.upsert(profile)
    }

    func loadTranscriptionLabSpeakerProfiles(
        for entryID: UUID
    ) throws -> [TranscriptionLabSpeakerProfile] {
        try transcriptionLabSpeakerProfileStore.loadProfiles(for: entryID)
    }

    func loadAllTranscriptionLabSpeakerProfiles() throws -> [TranscriptionLabSpeakerProfile] {
        try transcriptionLabSpeakerProfileStore.loadAllProfiles()
    }

    func upsertTranscriptionLabSpeakerProfile(_ profile: TranscriptionLabSpeakerProfile) throws {
        try transcriptionLabSpeakerProfileStore.upsert(profile)
    }




    func updateGlobalVoiceProfile(
        from localProfile: TranscriptionLabSpeakerProfile
    ) throws -> RecognizedVoiceProfile? {
        guard let recognizedVoiceID = localProfile.recognizedVoiceID else {
            return nil
        }

        let normalizedName = localProfile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            var recognizedVoice = try recognizedVoiceStore.loadProfiles().first(where: { $0.id == recognizedVoiceID })
        else {
            return nil
        }

        if normalizedName.isEmpty == false {
            recognizedVoice.displayName = normalizedName
        }
        recognizedVoice.isMe = localProfile.isMe
        if localProfile.evidenceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            recognizedVoice.evidenceTranscript = localProfile.evidenceTranscript
        }
        recognizedVoice.updatedAt = Date()
        try recognizedVoiceStore.upsert(recognizedVoice)
        return recognizedVoice
    }

    func transcriptionLabAudioURL(for entry: TranscriptionLabEntry) -> URL {
        transcriptionLabStore.audioURL(for: entry.audioFileName)
    }

    func rerunTranscriptionLabTranscription(
        _ entry: TranscriptionLabEntry,
        speechModelID: String,
        speakerTaggingEnabled: Bool
    ) async throws -> TranscriptionLabTranscriptionResult {
        guard acquirePipeline(for: .transcriptionLab) else {
            throw TranscriptionLabRunnerError.pipelineBusy
        }

        let preferredSpeechModelID = speechModel
        let runner = makeTranscriptionLabRunner()

        do {
            let result = try await runner.rerunTranscription(
                entry: entry,
                speechModelID: speechModelID,
                speakerTaggingEnabled: speakerTaggingEnabled,
                acquirePipeline: { true },
                releasePipeline: {}
            )
            await restorePreferredSpeechModelIfNeeded(preferredSpeechModelID)
            releasePipeline(owner: .transcriptionLab)
            return result
        } catch {
            await restorePreferredSpeechModelIfNeeded(preferredSpeechModelID)
            releasePipeline(owner: .transcriptionLab)
            throw error
        }
    }

    func rerunTranscriptionLabCleanup(
        _ entry: TranscriptionLabEntry,
        rawTranscription: String,
        cleanupModelKind: LocalCleanupModelKind,
        prompt: String,
        includeWindowContext: Bool
    ) async throws -> TranscriptionLabCleanupResult {
        guard acquirePipeline(for: .transcriptionLab) else {
            throw TranscriptionLabRunnerError.pipelineBusy
        }

        let runner = makeTranscriptionLabRunner()

        do {
            let result = try await runner.rerunCleanup(
                entry: entry,
                rawTranscription: rawTranscription,
                cleanupModelKind: cleanupModelKind,
                prompt: prompt,
                includeWindowContext: includeWindowContext,
                acquirePipeline: { true },
                releasePipeline: {}
            )
            releasePipeline(owner: .transcriptionLab)
            return result
        } catch {
            releasePipeline(owner: .transcriptionLab)
            throw error
        }
    }

    func updateShortcut(_ chord: KeyChord, for action: ChordAction) {
        let previousPushChord = pushToTalkChord
        let previousToggleChord = toggleToTalkChord
        let previousPepperChatChord = pepperChatChord

        do {
            try chordBindingStore.setBinding(chord, for: action)
            shortcutErrorMessage = nil

            switch action {
            case .pushToTalk:
                pushToTalkChord = chord
            case .toggleToTalk:
                toggleToTalkChord = chord
            case .pepperChat:
                pepperChatChord = chord
            }

            hotkeyMonitor.updateBindings(shortcutBindings)
        } catch {
            pushToTalkChord = previousPushChord
            toggleToTalkChord = previousToggleChord
            pepperChatChord = previousPepperChatChord
            shortcutErrorMessage = "That shortcut is already in use."
        }
    }

    func setShortcutCaptureActive(_ isActive: Bool) {
        hotkeyMonitor.setSuspended(isActive)
    }

    func setCleanupEnabled(_ enabled: Bool) {
        cleanupEnabled = enabled
        Task {
            await refreshCleanupModelState()
        }
    }

    func updateCleanupBackend(_ backend: CleanupBackendOption) {
        cleanupBackend = backend
        Task {
            await refreshCleanupModelState()
        }
    }

    func prepareForTermination() {
        recordingOCRPrefetch.cancel()
        textCleanupManager.shutdownBackend()
    }

    func acquirePipeline(for owner: PipelineOwner) -> Bool {
        guard pipelineOwner == nil else {
            return false
        }

        pipelineOwner = owner
        return true
    }

    func releasePipeline(owner: PipelineOwner) {
        guard pipelineOwner == owner else {
            return
        }

        pipelineOwner = nil
    }

    private func refreshCleanupModelState() async {
        guard cleanupEnabled else {
            debugLogStore.record(category: .model, message: "Cleanup disabled; unloading local cleanup models.")
            textCleanupManager.unloadModel()
            objectWillChange.send()
            return
        }

        let shouldLoadLocalModels = shouldLoadLocalCleanupModels
        debugLogStore.record(
            category: .model,
            message: "Cleanup backend is \(cleanupBackend.rawValue). shouldLoadLocalModels=\(shouldLoadLocalModels)"
        )

        if shouldLoadLocalModels {
            await textCleanupManager.loadModel()
        } else {
            textCleanupManager.unloadModel()
        }

        objectWillChange.send()
    }

    private func resolveTranscriptionLabSpeakerProfiles(
        entryID: UUID,
        audioBuffer: [Float],
        diarizationSummary: DiarizationSummary,
        speakerTaggedTranscript: SpeakerTaggedTranscript?
    ) async -> [TranscriptionLabSpeakerProfile] {
        do {
            let recognizedVoices = try recognizedVoiceStore.loadProfiles()
            let existingLocalProfiles = try transcriptionLabSpeakerProfileStore.loadProfiles(for: entryID)
            let speakerInputs = await makeSpeakerIdentityInputs(
                audioBuffer: audioBuffer,
                diarizationSummary: diarizationSummary,
                speakerTaggedTranscript: speakerTaggedTranscript
            )
            let resolution = speakerIdentityResolver.resolve(
                entryID: entryID,
                speakers: speakerInputs,
                existingLocalProfiles: existingLocalProfiles,
                recognizedVoices: recognizedVoices
            )

            for profile in resolution.recognizedVoices {
                try recognizedVoiceStore.upsert(profile)
            }
            for profile in resolution.localProfiles {
                try transcriptionLabSpeakerProfileStore.upsert(profile)
            }

            return resolution.localProfiles
        } catch {
            return []
        }
    }

    private func makeSpeakerIdentityInputs(
        audioBuffer: [Float],
        diarizationSummary: DiarizationSummary,
        speakerTaggedTranscript: SpeakerTaggedTranscript?
    ) async -> [SpeakerIdentityInput] {
        let speakerIDs = diarizationSummary.spans.reduce(into: [String]()) { orderedIDs, span in
            if orderedIDs.contains(span.speakerID) == false {
                orderedIDs.append(span.speakerID)
            }
        }

        var inputs: [SpeakerIdentityInput] = []
        inputs.reserveCapacity(speakerIDs.count)

        for speakerID in speakerIDs {
            let speakerSpans = mergedSpeakerSpans(
                from: diarizationSummary.spans.filter { $0.speakerID == speakerID }
            )
            let speakerAudio = extractSpeakerAudio(
                from: audioBuffer,
                spans: speakerSpans
            )
            let evidenceTranscript = speakerTaggedTranscript?.segments
                .filter { $0.speakerID == speakerID }
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let audioDuration = speakerSpans.reduce(into: 0.0) { total, span in
                total += span.duration
            }
            let embedding: [Float]?
            if audioDuration >= speakerIdentityResolver.minimumEmbeddingDuration,
               speakerAudio.isEmpty == false {
                embedding = try? await modelManager.extractSpeakerEmbedding(from: speakerAudio)
            } else {
                embedding = nil
            }

            inputs.append(
                SpeakerIdentityInput(
                    speakerID: speakerID,
                    audioDuration: audioDuration,
                    evidenceTranscript: evidenceTranscript,
                    embedding: embedding
                )
            )
        }

        return inputs
    }

    private func mergedSpeakerSpans(
        from spans: [DiarizationSummary.Span]
    ) -> [DiarizationSummary.MergedSpan] {
        let sortedSpans = spans.sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return lhs.endTime < rhs.endTime
            }
            return lhs.startTime < rhs.startTime
        }

        var mergedSpans: [DiarizationSummary.MergedSpan] = []
        for span in sortedSpans where span.duration > 0 {
            if let lastSpan = mergedSpans.last,
               span.startTime <= lastSpan.endTime {
                mergedSpans[mergedSpans.count - 1] = DiarizationSummary.MergedSpan(
                    startTime: lastSpan.startTime,
                    endTime: max(lastSpan.endTime, span.endTime)
                )
            } else {
                mergedSpans.append(
                    DiarizationSummary.MergedSpan(
                        startTime: span.startTime,
                        endTime: span.endTime
                    )
                )
            }
        }

        return mergedSpans
    }

    private func extractSpeakerAudio(
        from audioBuffer: [Float],
        spans: [DiarizationSummary.MergedSpan],
        sampleRate: Double = 16_000
    ) -> [Float] {
        guard audioBuffer.isEmpty == false else {
            return []
        }

        var extractedAudio: [Float] = []
        for span in spans where span.duration > 0 {
            let startIndex = max(Int((span.startTime * sampleRate).rounded(.down)), 0)
            let endIndex = min(Int((span.endTime * sampleRate).rounded(.up)), audioBuffer.count)
            guard startIndex < endIndex else {
                continue
            }

            extractedAudio.append(contentsOf: audioBuffer[startIndex..<endIndex])
        }

        return extractedAudio
    }

    private func makeTranscriptionLabRunner() -> TranscriptionLabRunner {
        TranscriptionLabRunner(
            loadAudioBuffer: { [transcriptionLabStore] entry in
                let audioData = try Data(contentsOf: transcriptionLabStore.audioURL(for: entry.audioFileName))
                return try AudioRecorder.deserializeArchivedAudioBuffer(from: audioData)
            },
            loadSpeechModel: { [weak self] modelID in
                guard let self else { return }
                await self.loadSpeechModel(name: modelID)
            },
            transcribe: { [transcriber] audioBuffer in
                await transcriber.transcribe(audioBuffer: audioBuffer)
            },
            runSpeakerTagging: { [weak self] audioBuffer in
                guard let self else { return nil }
                return await self.modelManager.transcribeWithSpeakerTagging(audioBuffer: audioBuffer)
            },
            resolveSpeakerProfiles: { [weak self] entryID, audioBuffer, diarizationSummary, speakerTaggedTranscript in
                guard let self else { return [] }
                return await self.resolveTranscriptionLabSpeakerProfiles(
                    entryID: entryID,
                    audioBuffer: audioBuffer,
                    diarizationSummary: diarizationSummary,
                    speakerTaggedTranscript: speakerTaggedTranscript
                )
            },
            clean: { [textCleaner] text, activePrompt, modelKind in
                await textCleaner.cleanWithPerformance(
                    text: text,
                    prompt: activePrompt,
                    modelKind: modelKind
                )
            },
            correctionStore: correctionStore
        )
    }

    private func restorePreferredSpeechModelIfNeeded(_ preferredSpeechModelID: String) async {
        guard modelManager.modelName != preferredSpeechModelID || !modelManager.isReady else {
            return
        }

        await loadSpeechModel(name: preferredSpeechModelID)
    }

    func loadSpeechModel(name: String) async {
        let language = preferredLanguage == "auto" ? nil : preferredLanguage
        await modelManager.loadModel(name: name, language: language)
        let nextPresentation = Self.nextSpeechModelPresentation(
            managerState: modelManager.state,
            managerError: modelManager.error,
            currentStatus: status,
            currentErrorMessage: errorMessage
        )
        status = nextPresentation.status
        errorMessage = nextPresentation.errorMessage
    }

    func reloadSpeechAnalyzerForPreferredLanguageIfNeeded() async {
        guard SpeechModelCatalog.model(named: speechModel)?.backend == .speechAnalyzer else {
            return
        }

        speechAnalyzerReloadsInFlight += 1
        let reloadGeneration = speechAnalyzerReloadsInFlight
        defer {
            speechAnalyzerReloadsInFlight = max(speechAnalyzerReloadsInFlight - 1, 0)
            if speechAnalyzerReloadsInFlight == 0,
               reloadGeneration > 0,
               !isSpeechAnalyzerSessionActive,
               status == .loading,
               modelManager.isReady {
                status = .ready
            }
        }

        await waitForSpeechAnalyzerSessionToBecomeIdle()
        guard !Task.isCancelled else { return }

        if status == .ready, !isSpeechAnalyzerSessionActive {
            status = .loading
        }

        while modelManager.state == .loading {
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(nanoseconds: Self.speechAnalyzerReloadPollIntervalNanoseconds)
            } catch {
                return
            }
        }

        guard !Task.isCancelled else { return }
        await loadSpeechModel(name: speechModel)
        if speechAnalyzerReloadsInFlight > 1, !Task.isCancelled {
            status = .loading
        }
    }

    private var isSpeechAnalyzerSessionActive: Bool {
        isRecording
            || isTranscribing
            || status == .recording
            || status == .transcribing
            || pipelineOwner != nil
    }

    private func waitForSpeechAnalyzerSessionToBecomeIdle() async {
        while isSpeechAnalyzerSessionActive {
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(nanoseconds: Self.speechAnalyzerReloadPollIntervalNanoseconds)
            } catch {
                return
            }
        }
    }

    static func nextSpeechModelPresentation(
        managerState: ModelManagerState,
        managerError: Error?,
        currentStatus: AppStatus,
        currentErrorMessage: String?
    ) -> (status: AppStatus, errorMessage: String?) {
        switch managerState {
        case .error:
            let shouldClearSpeechModelError = currentErrorMessage?.hasPrefix(speechModelErrorPrefix) == true
            let preservedErrorMessage = shouldClearSpeechModelError ? nil : currentErrorMessage
            return (
                .error,
                preservedErrorMessage
            )
        case .ready:
            let shouldClearSpeechModelError = currentErrorMessage?.hasPrefix(speechModelErrorPrefix) == true
            let nextStatus: AppStatus
            if currentStatus == .loading {
                nextStatus = .ready
            } else if shouldClearSpeechModelError && currentStatus == .error {
                nextStatus = .ready
            } else {
                nextStatus = currentStatus
            }
            return (
                nextStatus,
                shouldClearSpeechModelError ? nil : currentErrorMessage
            )
        case .idle, .loading:
            return (currentStatus, currentErrorMessage)
        }
    }

    private var shouldClearLiveRecordingNoInputErrorAfterAudioReset: Bool {
        status == .error && !isRecording && !isTranscribing && Self.isLiveRecordingNoInputError(errorMessage)
    }

    private static func isLiveRecordingNoInputError(_ message: String?) -> Bool {
        message == liveRecordingNoInputErrorMessage
    }
}
