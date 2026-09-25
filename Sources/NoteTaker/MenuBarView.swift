import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("transcriptionLocale") private var transcriptionLocale = "auto"

    var body: some View {
        if !statusLine.isEmpty {
            Text(statusLine)
        }

        Button(recordButtonTitle) {
            state.toggleRecording()
        }
        .keyboardShortcut("r", modifiers: [.command, .option])
        .disabled(state.status != .idle && state.status != .recording)

        if state.status == .recording {
            Button(state.isPaused
                ? L10n.t("Resume Recording", "녹음 재개")
                : L10n.t("Pause Recording", "녹음 일시정지")) {
                state.togglePause()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            Button(L10n.t("Add Key Moment", "주요 순간 추가")) {
                state.requestKeyMomentEntry()
            }
            .keyboardShortcut("k", modifiers: [.command, .option])
        }

        Button(L10n.t("Open Transcript Window", "녹취록 창 열기")) {
            openWindow(id: "transcript")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button(L10n.t("Library", "보관함")) {
            openWindow(id: "library")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("l", modifiers: [.command, .option])

        if state.status == .idle {
            if !state.segments.isEmpty {
                Button(L10n.t("Copy Last Transcript", "최근 녹취록 복사")) { state.copyTranscript() }
            }
            let recents = state.store.recentMeetings()
            Button(L10n.t("Summarize Last Meeting", "최근 회의 요약")) {
                state.summarizeLastMeeting()
            }
            .disabled(state.segments.isEmpty && state.keyMoments.isEmpty && recents.isEmpty)
            if !recents.isEmpty {
                Menu(L10n.t("Summarize Meeting…", "회의 선택 요약…")) {
                    ForEach(recents, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            state.summarizeFile(url)
                        }
                    }
                }
            }
        }

        Divider()

        Picker(L10n.t("Transcription Language", "음성 인식 언어"), selection: $transcriptionLocale) {
            Text(L10n.t("Automatic (system)", "자동 (시스템 언어)")).tag("auto")
            Text("English").tag("en_US")
            Text("한국어").tag("ko_KR")
        }
        .pickerStyle(.menu)
        .disabled(state.status != .idle)

        Menu(L10n.t("Recent Meetings", "최근 회의")) {
            let recents = state.store.recentMeetings()
            if recents.isEmpty {
                Text(L10n.t("No meetings yet", "아직 회의가 없습니다"))
            }
            ForEach(recents, id: \.self) { url in
                Button(url.deletingPathExtension().lastPathComponent) {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Button(L10n.t("Show All in Finder", "Finder에서 모두 보기")) {
                NSWorkspace.shared.open(state.store.directory)
            }
        }

        Divider()

        Button(L10n.t("Settings…", "설정…")) {
            // Menu bar (LSUIElement) apps don't activate on their own, which
            // left the Settings window buried behind other apps.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Button(L10n.t("Quit NoteTaker", "NoteTaker 종료")) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var recordButtonTitle: String {
        switch state.status {
        case .recording: return L10n.t("Stop Recording", "녹음 중지")
        case .preparing: return L10n.t("Starting…", "시작 중…")
        case .stopping: return L10n.t("Stopping…", "중지 중…")
        default: return L10n.t("Start Recording", "녹음 시작")
        }
    }

    private var statusLine: String {
        if let error = state.lastError { return "⚠️ \(error)" }
        return state.statusMessage
    }
}
