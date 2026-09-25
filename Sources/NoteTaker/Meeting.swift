import Foundation

enum SpeakerSource: String {
    case me = "Me"
    case others = "Others"

    var displayName: String {
        switch self {
        case .me: return L10n.t("Me", "나")
        case .others: return L10n.t("Others", "상대방")
        }
    }
}

struct TranscriptSegment: Identifiable {
    let id = UUID()
    let source: SpeakerSource
    let time: TimeInterval // seconds since recording start
    let text: String
}

/// A moment flagged live during the meeting (⌥⌘K), pinned at its timestamp.
struct KeyMoment: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let note: String
}

struct Meeting {
    var title: String
    var date: Date
    var duration: TimeInterval
    var segments: [TranscriptSegment]
    var keyMoments: [KeyMoment]
    var summary: String?

    static func timestamp(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    static func durationText(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    var markdown: String {
        var lines: [String] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("# \(title)")
        lines.append("")
        lines.append("*\(L10n.t("Recorded", "녹음")) \(df.string(from: date)) · \(Meeting.durationText(duration))*")
        lines.append("")
        if !keyMoments.isEmpty {
            lines.append("## \(L10n.t("Key Moments", "주요 순간"))")
            lines.append("")
            for moment in keyMoments.sorted(by: { $0.time < $1.time }) {
                lines.append("- ⭐ \(Meeting.timestamp(moment.time)) · \(moment.note)")
            }
            lines.append("")
        }
        if let summary, !summary.isEmpty {
            lines.append(summary)
            lines.append("")
            lines.append("---")
            lines.append("")
        }
        lines.append("## \(L10n.t("Transcript", "녹취록"))")
        lines.append("")
        if segments.isEmpty && keyMoments.isEmpty {
            lines.append(L10n.t("_No speech was detected._", "_감지된 음성이 없습니다._"))
        }
        // Interleave segments and key moments in time order.
        enum Entry {
            case segment(TranscriptSegment)
            case moment(KeyMoment)
            var time: TimeInterval {
                switch self {
                case .segment(let s): return s.time
                case .moment(let m): return m.time
                }
            }
        }
        let entries: [Entry] = (segments.map(Entry.segment) + keyMoments.map(Entry.moment))
            .sorted { $0.time < $1.time }
        for entry in entries {
            switch entry {
            case .segment(let segment):
                lines.append("**\(segment.source.displayName)** (\(Meeting.timestamp(segment.time)))")
                lines.append(segment.text)
                lines.append("")
            case .moment(let moment):
                lines.append("> ⭐ \(Meeting.timestamp(moment.time)) · \(moment.note)")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }
}
