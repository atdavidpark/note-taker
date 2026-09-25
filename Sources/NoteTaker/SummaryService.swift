import Foundation

enum SummaryProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openai
    case gemini
    case openaiCompatible
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        case .gemini: return "Google (Gemini)"
        case .openaiCompatible: return L10n.t("OpenAI-compatible (vLLM…)", "OpenAI 호환 (vLLM 등)")
        case .ollama: return "Ollama (local)"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-4-8"
        case .openai: return "gpt-4o"
        case .gemini: return "gemini-2.5-flash"
        case .openaiCompatible: return ""
        case .ollama: return "llama3.3"
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .anthropic: return ["claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5"]
        case .openai: return ["gpt-4o", "gpt-4o-mini"]
        case .gemini: return ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
        case .openaiCompatible: return []
        case .ollama: return ["llama3.3", "qwen2.5", "mistral"]
        }
    }

    /// Providers where a key is strictly required. The OpenAI-compatible
    /// provider treats the key as optional (many local servers have none).
    var needsAPIKey: Bool { self == .openai || self == .gemini }
    var keychainAccount: String { "\(rawValue)-api-key" }
}

/// How a provider request is authenticated.
enum ProviderAuth {
    case none
    case apiKey(String)
    /// Anthropic only: credentials resolved from the local config dir / ant CLI.
    case claudeLocalCredentials
}

enum SummaryService {
    private static let prompt = """
        Summarize this meeting transcript. The transcript labels the note-taker's own \
        speech as "Me" (or "나") and everyone else on the call as "Others" (or "상대방"). \
        Lines beginning with "> ⭐" are key moments the note-taker flagged live — treat \
        them as important. Write the entire summary in the transcript's primary language \
        (e.g. a Korean transcript gets a Korean summary, translating the section headings \
        too). Respond in Markdown with exactly these sections:

        ## Summary
        A few sentences on what the meeting was about and what happened.

        ## Key Points
        Bullet list of the important points discussed.

        ## Decisions
        Bullet list of decisions made (or "None recorded").

        ## Action Items
        Bullet list of follow-ups with owners where identifiable (or "None recorded").

        Transcript:

        """

    static func summarize(transcript: String, provider: SummaryProvider, model: String, auth: ProviderAuth) async throws -> String {
        switch provider {
        case .anthropic:
            return try await summarizeWithAnthropic(transcript: transcript, model: model, auth: auth)
        case .openai:
            guard case .apiKey(let key) = auth, !key.isEmpty else {
                throw NoteTakerError.missingAPIKey(provider.displayName)
            }
            return try await summarizeWithOpenAI(
                transcript: transcript, model: model, apiKey: key,
                baseURL: "https://api.openai.com/v1")
        case .openaiCompatible:
            var key: String?
            if case .apiKey(let value) = auth, !value.isEmpty { key = value }
            let base = UserDefaults.standard.string(forKey: "openaiCompatibleURL") ?? "http://localhost:8000/v1"
            guard !model.isEmpty else {
                throw NoteTakerError.summarizationFailed(L10n.t(
                    "Set a model name for the OpenAI-compatible provider in Settings.",
                    "설정에서 OpenAI 호환 제공자의 모델 이름을 입력해 주세요."))
            }
            return try await summarizeWithOpenAI(
                transcript: transcript, model: model, apiKey: key, baseURL: base)
        case .gemini:
            guard case .apiKey(let key) = auth, !key.isEmpty else {
                throw NoteTakerError.missingAPIKey(provider.displayName)
            }
            return try await summarizeWithGemini(transcript: transcript, model: model, apiKey: key)
        case .ollama:
            return try await summarizeWithOllama(transcript: transcript, model: model)
        }
    }

    // MARK: - Anthropic Messages API

    private static func summarizeWithAnthropic(transcript: String, model: String, auth: ProviderAuth) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        switch auth {
        case .apiKey(let key) where !key.isEmpty:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .claudeLocalCredentials:
            let credential = try AnthropicLocalAuth.credential()
            if credential.isOAuth {
                request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
                request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            } else {
                request.setValue(credential.token, forHTTPHeaderField: "x-api-key")
            }
        default:
            throw NoteTakerError.missingAPIKey(SummaryProvider.anthropic.displayName)
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "messages": [["role": "user", "content": prompt + transcript]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(request)
        if let type = json["type"] as? String, type == "error",
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw NoteTakerError.summarizationFailed(message)
        }
        if let stopReason = json["stop_reason"] as? String, stopReason == "refusal" {
            throw NoteTakerError.summarizationFailed("The model declined this request (refusal).")
        }
        guard let content = json["content"] as? [[String: Any]] else {
            throw NoteTakerError.summarizationFailed("Unexpected Anthropic response shape.")
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else {
            throw NoteTakerError.summarizationFailed("Anthropic returned no text.")
        }
        return text
    }

    // MARK: - OpenAI Chat Completions (OpenAI + any compatible server)

    private static func summarizeWithOpenAI(transcript: String, model: String, apiKey: String?, baseURL: String) async throws -> String {
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmedBase + "/chat/completions") else {
            throw NoteTakerError.summarizationFailed("Invalid server URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt + transcript]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(request)
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw NoteTakerError.summarizationFailed(message)
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty
        else {
            throw NoteTakerError.summarizationFailed("Unexpected chat-completions response shape.")
        }
        return text
    }

    // MARK: - Google Gemini

    private static func summarizeWithGemini(transcript: String, model: String, apiKey: String) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: urlString) else {
            throw NoteTakerError.summarizationFailed("Invalid Gemini model name.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": prompt + transcript]],
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(request)
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw NoteTakerError.summarizationFailed(message)
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else {
            throw NoteTakerError.summarizationFailed("Unexpected Gemini response shape.")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            throw NoteTakerError.summarizationFailed("Gemini returned no text.")
        }
        return text
    }

    // MARK: - Ollama (local)

    private static func summarizeWithOllama(transcript: String, model: String) async throws -> String {
        let base = UserDefaults.standard.string(forKey: "ollamaURL") ?? "http://localhost:11434"
        guard let url = URL(string: base)?.appendingPathComponent("api/chat") else {
            throw NoteTakerError.summarizationFailed("Invalid Ollama URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [["role": "user", "content": prompt + transcript]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(request)
        if let message = json["error"] as? String {
            throw NoteTakerError.summarizationFailed(message)
        }
        guard let message = json["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty
        else {
            throw NoteTakerError.summarizationFailed("Unexpected Ollama response shape. Is Ollama running?")
        }
        return text
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NoteTakerError.summarizationFailed(error.localizedDescription)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NoteTakerError.summarizationFailed("Non-JSON response (HTTP \(code)).")
        }
        return json
    }
}
