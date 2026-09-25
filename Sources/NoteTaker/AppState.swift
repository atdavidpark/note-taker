import AppKit
import AVFoundation
import Carbon.HIToolbox
import EventKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable {
        case idle
        case preparing
        case recording
        case stopping
        case summarizing
    }

    @Published var status: Status = .idle
    @Published var isPaused = false
    @Published var statusMessage: String = ""
    @Published var lastError: String?
    @Published var segments: [TranscriptSegment] = []
    @Published var keyMoments: [KeyMoment] = []
    @Published var summary: String?
    @Published var recordingStart: Date?
    @Published var lastSavedURL: URL?
    @Published var focusKeyMomentField = false

    @AppStorage("summaryProvider") var summaryProviderRaw: String = SummaryProvider.anthropic.rawValue
    @AppStorage("summaryModel.anthropic") var anthropicModel: String = SummaryProvider.anthropic.defaultModel
    @AppStorage("summaryModel.openai") var openaiModel: String = SummaryProvider.openai.defaultModel
    @AppStorage("summaryModel.gemini") var geminiModel: String = SummaryProvider.gemini.defaultModel
    @AppStorage("summaryModel.openaiCompatible") var openaiCompatibleModel: String = ""
    @AppStorage("summaryModel.ollama") var ollamaModel: String = SummaryProvider.ollama.defaultModel
    @AppStorage("useCalendarTitles") var useCalendarTitles: Bool = false
    /// "local" = credentials from ~/.config/anthropic (ant CLI); "apiKey" = Keychain key.
    @AppStorage("anthropicAuth") var anthropicAuthMode: String = "local"
    /// "auto" = system language; otherwise a locale identifier like "en_US" / "ko_KR".
    @AppStorage("transcriptionLocale") var transcriptionLocale: String = "auto"
    /// Save mic/system audio as WAV files next to each transcript.
    @AppStorage("keepAudioFiles") var keepAudioFiles: Bool = true

    let store = MeetingStore()

    private var micRecorder: MicRecorder?
    private var systemRecorder: SystemAudioRecorder?
    private var micEngine: TranscriptionEngine?
    private var systemEngine: TranscriptionEngine?
    private var resultTasks: [Task<Void, Never>] = []
    private var meetingTitle = "Meeting"
    private var meetingDate = Date()
    private var meetingDuration: TimeInterval = 0
    private let gate = CaptureGate()
    private var micSink: AudioSink?
    private var systemSink: AudioSink?
    private var pausedAccumulated: TimeInterval = 0
    private var pauseBegan: Date?
    private var autosaveTask: Task<Void, Never>?
    let reminders = ReminderCenter()

    /// Recording time excluding pauses — this matches the audio timeline the
    /// transcriber sees, so segment and key-moment timestamps stay aligned.
    var elapsedTime: TimeInterval {
        guard let start = recordingStart else { return meetingDuration }
        var elapsed = Date().timeIntervalSince(start) - pausedAccumulated
        if let pauseBegan {
            elapsed -= Date().timeIntervalSince(pauseBegan)
        }
        return max(0, elapsed)
    }

    var summaryProvider: SummaryProvider {
        SummaryProvider(rawValue: summaryProviderRaw) ?? .anthropic
    }

    func model(for provider: SummaryProvider) -> String {
        let value: String
        switch provider {
        case .anthropic: value = anthropicModel
        case .openai: value = openaiModel
        case .gemini: value = geminiModel
        case .openaiCompatible: value = openaiCompatibleModel
        case .ollama: value = ollamaModel
        }
        return value.isEmpty ? provider.defaultModel : value
    }

    func setModel(_ model: String, for provider: SummaryProvider) {
        switch provider {
        case .anthropic: anthropicModel = model
        case .openai: openaiModel = model
        case .gemini: geminiModel = model
        case .openaiCompatible: openaiCompatibleModel = model
        case .ollama: ollamaModel = model
        }
    }

    // MARK: - Hotkeys

    func registerHotKeys() {
        // ⌥⌘R — toggle recording from anywhere.
        HotKeyCenter.shared.register(
            id: HotKeyCenter.ID.toggleRecording,
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            self?.toggleRecording()
        }
        // ⌥⌘K — flag a key moment while recording.
        HotKeyCenter.shared.register(
            id: HotKeyCenter.ID.keyMoment,
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            self?.requestKeyMomentEntry()
        }
        // ⌥⌘P — pause/resume while recording.
        HotKeyCenter.shared.register(
            id: HotKeyCenter.ID.pause,
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            self?.togglePause()
        }

        reminders.onStartRecording = { [weak self] in
            self?.startRecording()
        }
        reminders.start()
    }

    func togglePause() {
        guard status == .recording else { return }
        if isPaused {
            if let pauseBegan {
                pausedAccumulated += Date().timeIntervalSince(pauseBegan)
            }
            pauseBegan = nil
            isPaused = false
            gate.isPaused = false
            statusMessage = L10n.t("Recording “\(meetingTitle)”", "“\(meetingTitle)” 녹음 중")
        } else {
            pauseBegan = Date()
            isPaused = true
            gate.isPaused = true
            statusMessage = L10n.t("Paused — nothing is being captured", "일시정지됨 — 캡처가 중단되었습니다")
        }
    }

    func toggleRecording() {
        switch status {
        case .idle: startRecording()
        case .recording: stopRecording()
        default: break
        }
    }

    // MARK: - Recording lifecycle

    func startRecording() {
        guard status == .idle else { return }
        status = .preparing
        lastError = nil
        statusMessage = L10n.t("Requesting microphone access…", "마이크 권한 요청 중…")
        Task { await start() }
    }

    private func start() async {
        do {
            guard await MicRecorder.requestPermission() else {
                throw NoteTakerError.microphoneAccessDenied
            }

            statusMessage = L10n.t("Preparing on-device transcription…", "온디바이스 음성 인식 준비 중…")
            guard let locale = await TranscriptionEngine.resolveLocale(preference: transcriptionLocale) else {
                throw NoteTakerError.speechModelUnavailable
            }
            let micEngine = try await TranscriptionEngine(locale: locale) { [weak self] message in
                Task { @MainActor in self?.statusMessage = message }
            }
            let systemEngine = try await TranscriptionEngine(locale: locale) { _ in }
            self.micEngine = micEngine
            self.systemEngine = systemEngine

            segments = []
            keyMoments = []
            summary = nil
            lastSavedURL = nil
            meetingDate = Date()
            meetingTitle = "Meeting"
            if useCalendarTitles, let calendarTitle = await CalendarTitles.currentEventTitle() {
                meetingTitle = calendarTitle
            }

            resultTasks = [
                consumeResults(from: micEngine, source: .me),
                consumeResults(from: systemEngine, source: .others),
            ]

            statusMessage = L10n.t("Starting audio capture…", "오디오 캡처 시작 중…")
            pausedAccumulated = 0
            pauseBegan = nil
            isPaused = false
            gate.isPaused = false

            if keepAudioFiles {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH.mm"
                let base = "\(df.string(from: meetingDate)) \(meetingTitle)"
                try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
                micSink = AudioSink(url: store.directory.appendingPathComponent("\(base) mic.m4a"))
                systemSink = AudioSink(url: store.directory.appendingPathComponent("\(base) system.m4a"))
            }

            let gate = self.gate
            let micSink = self.micSink
            let systemSink = self.systemSink

            let mic = MicRecorder()
            try mic.start { buffer in
                guard !gate.isPaused else { return }
                micSink?.write(buffer)
                micEngine.ingest(buffer)
            }
            micRecorder = mic

            let system = SystemAudioRecorder()
            try system.start { buffer in
                guard !gate.isPaused else { return }
                systemSink?.write(buffer)
                systemEngine.ingest(buffer)
            }
            systemRecorder = system

            recordingStart = Date()
            status = .recording
            statusMessage = L10n.t("Recording “\(meetingTitle)”", "“\(meetingTitle)” 녹음 중")
            startAutosave()
        } catch {
            await teardownCapture()
            status = .idle
            statusMessage = ""
            lastError = error.localizedDescription
        }
    }

    func stopRecording() {
        guard status == .recording else { return }
        status = .stopping
        statusMessage = L10n.t("Finishing transcription…", "음성 인식 마무리 중…")
        Task { await stop() }
    }

    private func stop() async {
        meetingDuration = elapsedTime
        await teardownCapture()
        recordingStart = nil
        pausedAccumulated = 0
        pauseBegan = nil
        isPaused = false
        gate.isPaused = false

        let meeting = Meeting(
            title: meetingTitle,
            date: meetingDate,
            duration: meetingDuration,
            segments: segments,
            keyMoments: keyMoments,
            summary: summary
        )
        do {
            let url = try store.save(meeting)
            lastSavedURL = url
            statusMessage = L10n.t("Saved: \(url.lastPathComponent)", "저장됨: \(url.lastPathComponent)")
        } catch {
            lastError = L10n.t(
                "Could not save transcript: \(error.localizedDescription)",
                "녹취록을 저장하지 못했습니다: \(error.localizedDescription)")
            statusMessage = ""
        }
        status = .idle
    }

    /// Crash safety: while recording, the in-progress transcript is written to
    /// its final file every 20 seconds, so a crash or power loss costs at most
    /// the last few seconds — not the whole meeting.
    private func startAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.status == .recording else { continue }
                let url = self.store.fileURL(date: self.meetingDate, title: self.meetingTitle)
                try? FileManager.default.createDirectory(
                    at: self.store.directory, withIntermediateDirectories: true)
                try? self.transcriptMarkdown.data(using: .utf8)?.write(to: url, options: .atomic)
            }
        }
    }

    private func teardownCapture() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        micRecorder?.stop()
        micRecorder = nil
        systemRecorder?.stop()
        systemRecorder = nil
        micSink?.close()
        micSink = nil
        systemSink?.close()
        systemSink = nil
        if let micEngine { await micEngine.finish() }
        if let systemEngine { await systemEngine.finish() }
        // Give in-flight final results a moment to land before the tasks end.
        for task in resultTasks { _ = await task.value }
        resultTasks = []
        micEngine = nil
        systemEngine = nil
    }

    private func consumeResults(from engine: TranscriptionEngine, source: SpeakerSource) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await result in engine.transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let seconds = result.range.start.seconds
                    let time = seconds.isFinite ? seconds : 0
                    self?.integrate(TranscriptSegment(source: source, time: time, text: text))
                }
            } catch is CancellationError {
                // normal teardown
            } catch {
                self?.lastError = "\(source.rawValue) transcription: \(error.localizedDescription)"
            }
        }
    }

    /// Progressive transcription re-emits improved hypotheses for the same
    /// stretch of audio. A new result supersedes any earlier segment from the
    /// same source that starts at or after (within a small tolerance) its
    /// start time; earlier finalized segments are untouched.
    private func integrate(_ segment: TranscriptSegment) {
        segments.removeAll { $0.source == segment.source && $0.time >= segment.time - 0.25 }
        let index = segments.firstIndex { $0.time > segment.time } ?? segments.endIndex
        segments.insert(segment, at: index)
    }

    // MARK: - Key moments

    func requestKeyMomentEntry() {
        guard status == .recording else { return }
        NSApp.activate(ignoringOtherApps: true)
        openTranscriptWindow()
        focusKeyMomentField = true
    }

    func addKeyMoment(_ note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == .recording, !trimmed.isEmpty, recordingStart != nil else { return }
        keyMoments.append(KeyMoment(time: elapsedTime, note: trimmed))
    }

    // MARK: - Transcript utilities

    var transcriptMarkdown: String {
        Meeting(
            title: meetingTitle,
            date: meetingDate,
            duration: elapsedTime,
            segments: segments,
            keyMoments: keyMoments,
            summary: summary
        ).markdown
    }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptMarkdown, forType: .string)
        statusMessage = L10n.t("Transcript copied to clipboard", "녹취록이 클립보드에 복사되었습니다")
    }

    func openTranscriptWindow() {
        // Raise an existing transcript window, or ask SwiftUI to open one.
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("transcript") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?("transcript")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    var openWindowAction: ((String) -> Void)?

    // MARK: - Summarization

    func summarize() {
        guard status == .idle, !segments.isEmpty || !keyMoments.isEmpty else { return }
        status = .summarizing
        lastError = nil
        let provider = summaryProvider
        statusMessage = L10n.t("Summarizing with \(provider.displayName)…", "\(provider.displayName)(으)로 요약 중…")
        Task { await runSummarization(provider: provider) }
    }

    /// Menu entry point: summarizes the in-memory meeting if there is one,
    /// otherwise the most recently saved transcript on disk.
    func summarizeLastMeeting() {
        if !segments.isEmpty || !keyMoments.isEmpty {
            summarize()
        } else if let latest = store.recentMeetings(limit: 1).first {
            summarizeFile(latest)
        }
    }

    /// Summarizes a saved transcript file; the summary is appended to the file.
    func summarizeFile(_ url: URL) {
        guard status == .idle else { return }
        guard let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty else {
            lastError = L10n.t("Could not read \(url.lastPathComponent).", "\(url.lastPathComponent)을(를) 읽을 수 없습니다.")
            return
        }
        status = .summarizing
        lastError = nil
        let provider = summaryProvider
        statusMessage = L10n.t("Summarizing \(url.lastPathComponent)…", "\(url.lastPathComponent) 요약 중…")
        Task { await runFileSummarization(content: content, url: url, provider: provider) }
    }

    private func makeAuth(for provider: SummaryProvider) -> ProviderAuth {
        switch provider {
        case .ollama:
            return .none
        case .anthropic:
            if anthropicAuthMode == "local" {
                return .claudeLocalCredentials
            }
            return .apiKey(Keychain.get(account: provider.keychainAccount) ?? "")
        case .openai, .gemini, .openaiCompatible:
            return .apiKey(Keychain.get(account: provider.keychainAccount) ?? "")
        }
    }

    private func runFileSummarization(content: String, url: URL, provider: SummaryProvider) async {
        do {
            let text = try await SummaryService.summarize(
                transcript: content,
                provider: provider,
                model: model(for: provider),
                auth: makeAuth(for: provider)
            )
            summary = text
            lastSavedURL = url
            let updated = content + "\n\n---\n\n" + text + "\n"
            try? updated.data(using: .utf8)?.write(to: url, options: .atomic)
            statusMessage = L10n.t("Summary added to \(url.lastPathComponent)", "\(url.lastPathComponent)에 요약이 추가되었습니다")
            openTranscriptWindow()
        } catch {
            lastError = error.localizedDescription
            statusMessage = ""
        }
        status = .idle
    }

    private func runSummarization(provider: SummaryProvider) async {
        do {
            let auth = makeAuth(for: provider)
            let text = try await SummaryService.summarize(
                transcript: transcriptMarkdown,
                provider: provider,
                model: model(for: provider),
                auth: auth
            )
            summary = text
            statusMessage = L10n.t("Summary ready", "요약 완료")
            // Re-save the meeting file with the summary included.
            let meeting = Meeting(
                title: meetingTitle,
                date: meetingDate,
                duration: meetingDuration,
                segments: segments,
                keyMoments: keyMoments,
                summary: text
            )
            if let url = lastSavedURL {
                try? meeting.markdown.data(using: .utf8)?.write(to: url, options: .atomic)
            } else {
                lastSavedURL = try? store.save(meeting)
            }
        } catch {
            lastError = error.localizedDescription
            statusMessage = ""
        }
        status = .idle
    }
}

/// Optional, read-only calendar lookup used to auto-title recordings.
enum CalendarTitles {
    static func currentEventTitle() async -> String? {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted else { return nil }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-5 * 60),
            end: now.addingTimeInterval(10 * 60),
            calendars: nil)
        let event = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .first
        guard let title = event?.title, !title.isEmpty else { return nil }
        // File names can't contain path separators.
        return title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}
