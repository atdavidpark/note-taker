import Foundation

/// Resolves Anthropic credentials from the local machine instead of a pasted
/// API key — the OAuth profile created by `ant auth login`, stored under
/// $ANTHROPIC_CONFIG_DIR (default ~/.config/anthropic).
enum AnthropicLocalAuth {
    struct Credential {
        let token: String
        /// OAuth tokens need `anthropic-beta: oauth-2025-04-20`; API keys found
        /// in the config dir go on `x-api-key` instead.
        let isOAuth: Bool
    }

    static var configDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["ANTHROPIC_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/anthropic", isDirectory: true)
    }

    static func antBinaryPath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/ant",
            "/usr/local/bin/ant",
            "\(home)/go/bin/ant",
            "\(home)/.local/bin/ant",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var hasLocalCredentials: Bool {
        antBinaryPath() != nil || credentialFiles().isEmpty == false
    }

    /// Preferred path: ask the `ant` CLI, which refreshes expired tokens.
    /// Fallback: read the newest credentials file from the config directory.
    static func credential() throws -> Credential {
        if let ant = antBinaryPath(), let token = try? runAnt(ant), !token.isEmpty {
            return Credential(token: token, isOAuth: !token.hasPrefix("sk-ant-api"))
        }
        if let fromDisk = credentialFromDisk() {
            return fromDisk
        }
        throw NoteTakerError.summarizationFailed(L10n.t(
            "No local Claude credentials found. Install the ant CLI (brew install anthropics/tap/ant), run `ant auth login`, or switch the Anthropic provider to API-key auth in Settings.",
            "로컬 Claude 인증 정보를 찾을 수 없습니다. ant CLI를 설치하고(brew install anthropics/tap/ant) `ant auth login`을 실행하거나, 설정에서 Anthropic 인증 방식을 API 키로 변경하세요."
        ))
    }

    private static func runAnt(_ path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["auth", "print-credentials", "--access-token"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func credentialFiles() -> [URL] {
        let dir = configDirectory.appendingPathComponent("credentials", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }
    }

    private static func credentialFromDisk() -> Credential? {
        let sorted = credentialFiles().sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
        for file in sorted {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Accept the common field spellings without depending on one schema.
            let keys = ["accessToken", "access_token", "token", "apiKey", "api_key"]
            for key in keys {
                if let token = json[key] as? String, !token.isEmpty {
                    return Credential(token: token, isOAuth: !token.hasPrefix("sk-ant-api"))
                }
            }
            for value in json.values {
                if let nested = value as? [String: Any] {
                    for key in keys {
                        if let token = nested[key] as? String, !token.isEmpty {
                            return Credential(token: token, isOAuth: !token.hasPrefix("sk-ant-api"))
                        }
                    }
                }
            }
        }
        return nil
    }
}
