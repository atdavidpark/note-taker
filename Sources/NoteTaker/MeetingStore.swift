import Foundation

/// Saves meetings as Markdown files in ~/Documents/Meeting Notes.
struct MeetingStore {
    var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return docs.appendingPathComponent("Meeting Notes", isDirectory: true)
    }

    /// Deterministic file location for a meeting — shared by autosave (during
    /// recording) and the final save so both write the same file.
    func fileURL(date: Date, title: String) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm"
        return directory.appendingPathComponent("\(df.string(from: date)) \(title).md")
    }

    @discardableResult
    func save(_ meeting: Meeting) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(date: meeting.date, title: meeting.title)
        try meeting.markdown.data(using: .utf8)!.write(to: url, options: .atomic)
        return url
    }

    /// Moves a transcript and its companion audio files to the Trash.
    /// Checks both .m4a (current) and .wav (earlier recordings).
    func trash(_ url: URL) {
        let base = url.deletingPathExtension().path
        let related = [url] + [" mic.m4a", " system.m4a", " mic.wav", " system.wav"]
            .map { URL(fileURLWithPath: base + $0) }
        for item in related where FileManager.default.fileExists(atPath: item.path) {
            try? FileManager.default.trashItem(at: item, resultingItemURL: nil)
        }
    }

    func allMeetings() -> [URL] {
        recentMeetings(limit: Int.max)
    }

    func recentMeetings(limit: Int = 8) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        return urls
            .filter { $0.pathExtension == "md" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
            .prefix(limit)
            .map { $0 }
    }
}
