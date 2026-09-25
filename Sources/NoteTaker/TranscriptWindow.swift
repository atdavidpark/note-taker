import SwiftUI

struct TranscriptWindow: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var keyMomentFocused: Bool
    @State private var keyMomentText = ""
    @AppStorage("transcriptionLocale") private var transcriptionLocale = "auto"

    private enum Row: Identifiable {
        case segment(TranscriptSegment)
        case moment(KeyMoment)

        var id: UUID {
            switch self {
            case .segment(let s): return s.id
            case .moment(let m): return m.id
            }
        }

        var time: TimeInterval {
            switch self {
            case .segment(let s): return s.time
            case .moment(let m): return m.time
            }
        }
    }

    private var rows: [Row] {
        (state.segments.map(Row.segment) + state.keyMoments.map(Row.moment))
            .sorted { $0.time < $1.time }
    }

    var body: some View {
        VStack(spacing: 0) {
            transcriptContent
            bottomBar
        }
        .frame(minWidth: 480, minHeight: 420)
        .containerBackground(.ultraThinMaterial, for: .window)
        .navigationTitle(L10n.t("Meeting Transcript", "회의 녹취록"))
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .onChange(of: state.focusKeyMomentField) { _, shouldFocus in
            if shouldFocus {
                keyMomentFocused = true
                state.focusKeyMomentField = false
            }
        }
    }

    private var subtitle: String {
        if let error = state.lastError { return error }
        return state.statusMessage
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Picker(selection: $transcriptionLocale) {
                Text(L10n.t("Automatic", "자동")).tag("auto")
                Text("English").tag("en_US")
                Text("한국어").tag("ko_KR")
            } label: {
                Label(L10n.t("Language", "언어"), systemImage: "globe")
            }
            .pickerStyle(.menu)
            // The on-device recognizer runs one language per session, so the
            // language can only change between recordings.
            .disabled(state.status != .idle)
            .help(L10n.t("Transcription language for the next recording", "다음 녹음의 음성 인식 언어"))

            Button {
                state.copyTranscript()
            } label: {
                Label(L10n.t("Copy Markdown", "마크다운 복사"), systemImage: "doc.on.doc")
            }
            .disabled(rows.isEmpty)
            .help(L10n.t("Copy the transcript as Markdown", "녹취록을 마크다운으로 복사"))

            Button {
                state.summarize()
            } label: {
                Label(L10n.t("Summarize", "요약"), systemImage: "sparkles")
            }
            .disabled(state.status != .idle || rows.isEmpty)
            .help("\(state.summaryProvider.displayName) · \(state.model(for: state.summaryProvider))")

            if state.status == .recording {
                Button {
                    state.togglePause()
                } label: {
                    Label(
                        state.isPaused ? L10n.t("Resume", "재개") : L10n.t("Pause", "일시정지"),
                        systemImage: state.isPaused ? "play.fill" : "pause.fill")
                }
                .help(L10n.t("Pause / resume (⌥⌘P)", "일시정지 / 재개 (⌥⌘P)"))

                Button {
                    state.stopRecording()
                } label: {
                    Label(L10n.t("Stop", "중지"), systemImage: "stop.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
            } else {
                Button {
                    state.startRecording()
                } label: {
                    Label(L10n.t("Record", "녹음"), systemImage: "record.circle")
                }
                .buttonStyle(.glassProminent)
                .disabled(state.status != .idle)
            }
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptContent: some View {
        if rows.isEmpty && state.summary == nil && state.status != .recording {
            ContentUnavailableView(
                L10n.t("No transcript yet", "아직 녹취록이 없습니다"),
                systemImage: "waveform",
                description: Text(L10n.t(
                    "Press ⌥⌘R — from any app, even mid-call — or click Record to start capturing your meeting.",
                    "어느 앱에서든 — 통화 중에도 — ⌥⌘R을 누르거나 녹음 버튼을 눌러 회의 캡처를 시작하세요."))
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if let summary = state.summary {
                            SummaryCard(summary: summary)
                        }
                        ForEach(rows) { row in
                            switch row {
                            case .segment(let segment):
                                SegmentBubble(segment: segment)
                            case .moment(let moment):
                                MomentPill(moment: moment)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: state.segments.count) {
                    withAnimation(.snappy) { proxy.scrollTo("bottom") }
                }
                .onChange(of: state.keyMoments.count) {
                    withAnimation(.snappy) { proxy.scrollTo("bottom") }
                }
            }
        }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        switch state.status {
        case .recording:
            GlassEffectContainer {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        if state.isPaused {
                            Image(systemName: "pause.circle.fill")
                                .foregroundStyle(.yellow)
                        } else {
                            Image(systemName: "record.circle.fill")
                                .foregroundStyle(.red)
                                .symbolEffect(.pulse)
                        }
                        // Manual clock — excludes paused time, matching the
                        // audio timeline the transcriber sees.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(Meeting.timestamp(state.elapsedTime))
                                .monospacedDigit()
                                .font(.callout.weight(.medium))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassEffect()

                    HStack(spacing: 8) {
                        Image(systemName: "star")
                            .foregroundStyle(.yellow)
                        TextField(L10n.t("Flag a key moment… (⌥⌘K)", "주요 순간 기록… (⌥⌘K)"), text: $keyMomentText)
                            .textFieldStyle(.plain)
                            .focused($keyMomentFocused)
                            .onSubmit(submitKeyMoment)
                        if !keyMomentText.isEmpty {
                            Button(action: submitKeyMoment) {
                                Image(systemName: "arrow.turn.down.left")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassEffect()
                }
                .padding(12)
            }
        case .preparing, .stopping, .summarizing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(state.statusMessage)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        case .idle:
            if let error = state.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(12)
            } else if let url = state.lastSavedURL {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(url.lastPathComponent)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(L10n.t("Show in Finder", "Finder에서 보기")) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.link)
                    Spacer()
                }
                .padding(12)
            }
        }
    }

    private func submitKeyMoment() {
        state.addKeyMoment(keyMomentText)
        keyMomentText = ""
    }
}

// MARK: - Row views

private struct SegmentBubble: View {
    let segment: TranscriptSegment

    private var isMe: Bool { segment.source == .me }

    var body: some View {
        HStack(alignment: .bottom) {
            if isMe { Spacer(minLength: 56) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(isMe ? L10n.t("You", "나") : L10n.t("Others", "상대방"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isMe ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(Meeting.timestamp(segment.time))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(segment.text)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isMe ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quinary),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            if !isMe { Spacer(minLength: 56) }
        }
    }
}

private struct MomentPill: View {
    let moment: KeyMoment

    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                Text(Meeting.timestamp(moment.time))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(moment.note)
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect()
            Spacer()
        }
    }
}

private struct SummaryCard: View {
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.t("AI Summary", "AI 요약"), systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.tint)
            Text(rendered)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var rendered: AttributedString {
        (try? AttributedString(
            markdown: summary,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(summary)
    }
}
