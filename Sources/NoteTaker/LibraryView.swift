import AppKit
import SwiftUI

/// One saved meeting on disk, parsed for the library.
struct MeetingFile: Identifiable, Hashable {
    struct Row: Identifiable, Hashable {
        let id: Int
        let time: TimeInterval
        let speaker: String?  // nil = key moment
        let text: String
    }

    let url: URL
    let title: String
    let modified: Date
    let sizeBytes: Int
    let durationText: String?
    let content: String
    let rows: [Row]

    var id: URL { url }

    var meta: String {
        var parts: [String] = [modified.formatted(date: .abbreviated, time: .shortened)]
        if let durationText { parts.append(durationText) }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
        return parts.joined(separator: " · ")
    }

    /// Companion audio files recorded alongside this transcript, if kept.
    /// .m4a is the current format; .wav covers earlier recordings.
    var audioURLs: [URL] {
        let base = url.deletingPathExtension().path
        return [" mic.m4a", " system.m4a", " mic.wav", " system.wav"]
            .map { URL(fileURLWithPath: base + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var snippet: String {
        rows.first { $0.speaker != nil }?.text.prefix(120).description ?? ""
    }

    /// The "## Summary" section, if one was generated.
    var summaryText: String? {
        guard let start = content.range(of: "## Summary") ?? content.range(of: "## 요약") else { return nil }
        let tail = content[start.lowerBound...]
        if let end = tail.range(of: "\n## Transcript") ?? tail.range(of: "\n## 녹취록") {
            return String(tail[..<end.lowerBound])
        }
        return String(tail)
    }

    static func load(_ url: URL) -> MeetingFile? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let title = content.split(separator: "\n")
            .first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)) }
            ?? url.deletingPathExtension().lastPathComponent
        var durationText: String?
        if let headerLine = content.split(separator: "\n").first(where: { $0.hasPrefix("*") && $0.contains("·") }) {
            durationText = headerLine.split(separator: "·").last
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " *")) }
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return MeetingFile(
            url: url,
            title: title,
            modified: values?.contentModificationDate ?? .distantPast,
            sizeBytes: values?.fileSize ?? 0,
            durationText: durationText,
            content: content,
            rows: parseRows(content)
        )
    }

    /// Parses `**Speaker** (36:28)` blocks and `> ⭐ 36:44 · note` key moments
    /// back out of the markdown, for playback-synced display.
    private static func parseRows(_ content: String) -> [Row] {
        var rows: [Row] = []
        var pendingSpeaker: String?
        var pendingTime: TimeInterval = 0
        var pendingText: [String] = []
        var nextID = 0

        func flush() {
            guard let speaker = pendingSpeaker, !pendingText.isEmpty else {
                pendingSpeaker = nil
                pendingText = []
                return
            }
            rows.append(Row(id: nextID, time: pendingTime, speaker: speaker, text: pendingText.joined(separator: " ")))
            nextID += 1
            pendingSpeaker = nil
            pendingText = []
        }

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("**"), line.hasSuffix(")"),
               let nameEnd = line.range(of: "** ("),
               let time = parseTimestamp(String(line[nameEnd.upperBound...].dropLast())) {
                flush()
                pendingSpeaker = String(line.dropFirst(2)[..<line.dropFirst(2).range(of: "**")!.lowerBound])
                pendingTime = time
            } else if line.hasPrefix("> ⭐") {
                flush()
                let body = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let parts = body.split(separator: "·", maxSplits: 1)
                let time = parts.first.flatMap { parseTimestamp($0.trimmingCharacters(in: .whitespaces)) } ?? 0
                let note = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : body
                rows.append(Row(id: nextID, time: time, speaker: nil, text: note))
                nextID += 1
            } else if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("*") || line.hasPrefix("---") {
                flush()
            } else if pendingSpeaker != nil {
                pendingText.append(line)
            }
        }
        flush()
        return rows.sorted { $0.time < $1.time }
    }

    private static func parseTimestamp(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return TimeInterval(parts[0] * 60 + parts[1])
        case 3: return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
        default: return nil
        }
    }
}

/// Trace-style library: every recording in one window — searchable, with
/// synced audio playback, Transcript/Summary tabs, and file actions.
struct LibraryView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var player = PlaybackController()

    private enum DetailTab {
        case transcript
        case summary
    }

    @State private var files: [MeetingFile] = []
    @State private var query = ""
    @State private var selection: URL?
    @State private var tab: DetailTab = .transcript
    @State private var deleteCandidate: MeetingFile?

    private var filtered: [MeetingFile] {
        guard !query.isEmpty else { return files }
        return files.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.content.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { file in
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(file.meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !file.snippet.isEmpty {
                        Text(file.snippet)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 3)
                .tag(file.url)
                .contextMenu {
                    Button(L10n.t("Show in Finder", "Finder에서 보기")) {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    }
                    Button(L10n.t("Move to Trash", "휴지통으로 이동"), role: .destructive) {
                        deleteCandidate = file
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            if let file = selectedFile {
                detailView(file)
            } else {
                ContentUnavailableView(
                    L10n.t("Select a meeting", "회의를 선택하세요"),
                    systemImage: "list.bullet.rectangle",
                    description: Text(L10n.t(
                        "All transcripts saved in \(state.store.directory.lastPathComponent) appear here.",
                        "\(state.store.directory.lastPathComponent)에 저장된 모든 녹취록이 여기에 표시됩니다."))
                )
            }
        }
        .searchable(text: $query, prompt: L10n.t("Search transcripts…", "녹취록 검색…"))
        .navigationTitle(L10n.t("Library", "보관함"))
        .toolbar {
            ToolbarItem {
                Button {
                    reload()
                } label: {
                    Label(L10n.t("Refresh", "새로 고침"), systemImage: "arrow.clockwise")
                }
            }
        }
        .task { reload() }
        .onChange(of: state.status) { _, newStatus in
            if newStatus == .idle { reload() }
        }
        .onChange(of: selection) {
            player.stop()
            if let audio = selectedFile?.audioURLs, !audio.isEmpty {
                player.load(urls: audio)
            }
        }
        .confirmationDialog(
            L10n.t("Move “\(deleteCandidate?.title ?? "")” to the Trash?",
                   "“\(deleteCandidate?.title ?? "")”을(를) 휴지통으로 이동할까요?"),
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } })
        ) {
            Button(L10n.t("Move to Trash", "휴지통으로 이동"), role: .destructive) {
                if let candidate = deleteCandidate {
                    if candidate.url == selection {
                        player.stop()
                        selection = nil
                    }
                    state.store.trash(candidate.url)
                    reload()
                }
                deleteCandidate = nil
            }
            Button(L10n.t("Cancel", "취소"), role: .cancel) {
                deleteCandidate = nil
            }
        } message: {
            Text(L10n.t("The transcript and its audio files move to the Trash.",
                        "녹취록과 오디오 파일이 휴지통으로 이동합니다."))
        }
        .frame(minWidth: 640, minHeight: 400)
    }

    private var selectedFile: MeetingFile? {
        filtered.first { $0.url == selection } ?? filtered.first
    }

    private func reload() {
        files = state.store.allMeetings().compactMap(MeetingFile.load)
        if selection == nil || !files.contains(where: { $0.url == selection }) {
            selection = files.first?.url
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detailView(_ file: MeetingFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(file.title)
                    .font(.title2.bold())
                HStack(spacing: 12) {
                    Text(file.meta)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $tab) {
                        Text(L10n.t("Transcript", "녹취록")).tag(DetailTab.transcript)
                        Text(L10n.t("Summary", "요약")).tag(DetailTab.summary)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .padding()

            if player.hasAudio {
                playerBar
                    .padding(.horizontal)
                    .padding(.bottom, 10)
            }

            Divider()

            contentPane(file)

            Divider()

            actionBar(file)
        }
    }

    private var playerBar: some View {
        HStack(spacing: 10) {
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 1))
            Text("\(Meeting.timestamp(player.currentTime)) / \(Meeting.timestamp(player.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .glassEffect()
    }

    /// The row currently being spoken during playback.
    private func currentRowID(_ file: MeetingFile) -> Int? {
        guard player.hasAudio, player.currentTime > 0 else { return nil }
        return file.rows.last { $0.time <= player.currentTime }?.id
    }

    @ViewBuilder
    private func contentPane(_ file: MeetingFile) -> some View {
        if tab == .summary {
            ScrollView {
                if let summary = file.summaryText {
                    Text(summary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                } else {
                    ContentUnavailableView(
                        L10n.t("No summary yet", "아직 요약이 없습니다"),
                        systemImage: "sparkles",
                        description: Text(L10n.t(
                            "Click Summarize below to generate one with \(state.summaryProvider.displayName).",
                            "아래의 요약 버튼을 눌러 \(state.summaryProvider.displayName)(으)로 요약을 생성하세요."))
                    )
                    .padding(.top, 40)
                }
            }
        } else if file.rows.isEmpty {
            ScrollView {
                Text(file.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else {
            let highlighted = currentRowID(file)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(file.rows) { row in
                            rowView(row, highlighted: row.id == highlighted)
                                .id(row.id)
                                .onTapGesture {
                                    if player.hasAudio { player.seek(to: row.time) }
                                }
                        }
                    }
                    .padding()
                }
                .onChange(of: highlighted) { _, rowID in
                    if let rowID {
                        withAnimation(.snappy) { proxy.scrollTo(rowID, anchor: .center) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: MeetingFile.Row, highlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Meeting.timestamp(row.time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
            if let speaker = row.speaker {
                VStack(alignment: .leading, spacing: 2) {
                    Text(speaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(row.text)
                        .textSelection(.enabled)
                }
            } else {
                Label(row.text, systemImage: "star.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            highlighted ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func actionBar(_ file: MeetingFile) -> some View {
        HStack(spacing: 10) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    tab == .summary ? (file.summaryText ?? file.content) : file.content,
                    forType: .string)
            } label: {
                Label(L10n.t("Copy", "복사"), systemImage: "doc.on.doc")
            }

            Button {
                state.summarizeFile(file.url)
            } label: {
                Label(L10n.t("Summarize", "요약"), systemImage: "sparkles")
            }
            .disabled(state.status != .idle)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Label(L10n.t("Show in Finder", "Finder에서 보기"), systemImage: "folder")
            }

            Button(role: .destructive) {
                deleteCandidate = file
            } label: {
                Label(L10n.t("Delete", "삭제"), systemImage: "trash")
            }

            Spacer()

            if state.status == .summarizing {
                ProgressView()
                    .controlSize(.small)
                Text(state.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }
}
