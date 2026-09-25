import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab(L10n.t("Summaries", "요약"), systemImage: "sparkles") {
                SummarySettings()
            }
            Tab(L10n.t("Meetings", "회의"), systemImage: "calendar") {
                MeetingSettings()
            }
        }
        // Fixed width, content-driven height — the window hugs the form like
        // standard macOS settings panes, so there is no leftover margin.
        .frame(width: 440)
    }
}

private struct SummarySettings: View {
    @AppStorage("summaryProvider") private var providerRaw = SummaryProvider.anthropic.rawValue
    @AppStorage("summaryModel.anthropic") private var anthropicModel = SummaryProvider.anthropic.defaultModel
    @AppStorage("summaryModel.openai") private var openaiModel = SummaryProvider.openai.defaultModel
    @AppStorage("summaryModel.gemini") private var geminiModel = SummaryProvider.gemini.defaultModel
    @AppStorage("summaryModel.openaiCompatible") private var openaiCompatibleModel = ""
    @AppStorage("summaryModel.ollama") private var ollamaModel = SummaryProvider.ollama.defaultModel
    @AppStorage("ollamaURL") private var ollamaURL = "http://localhost:11434"
    @AppStorage("openaiCompatibleURL") private var openaiCompatibleURL = "http://localhost:8000/v1"
    @AppStorage("anthropicAuth") private var anthropicAuthMode = "local"
    @State private var apiKeyInput = ""
    @State private var keyStatus = ""

    private var provider: SummaryProvider {
        SummaryProvider(rawValue: providerRaw) ?? .anthropic
    }

    private var modelBinding: Binding<String> {
        switch provider {
        case .anthropic: return $anthropicModel
        case .openai: return $openaiModel
        case .gemini: return $geminiModel
        case .openaiCompatible: return $openaiCompatibleModel
        case .ollama: return $ollamaModel
        }
    }

    /// Whether the currently selected provider + auth mode shows a key field.
    private var showsKeyField: Bool {
        if provider == .anthropic { return anthropicAuthMode == "apiKey" }
        return provider.needsAPIKey || provider == .openaiCompatible
    }

    var body: some View {
        Form {
            Section {
                Picker(L10n.t("Provider", "제공자"), selection: $providerRaw) {
                    ForEach(SummaryProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    TextField(
                        L10n.t("Model", "모델"),
                        text: modelBinding,
                        prompt: Text(provider.defaultModel.isEmpty
                            ? L10n.t("model name (e.g. as served by vLLM)", "모델 이름 (vLLM에 로드된 이름)")
                            : provider.defaultModel))
                    if !provider.suggestedModels.isEmpty {
                        Menu {
                            ForEach(provider.suggestedModels, id: \.self) { suggestion in
                                Button(suggestion) { modelBinding.wrappedValue = suggestion }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            } header: {
                Text(L10n.t("Provider & Model", "제공자 및 모델"))
            } footer: {
                Text(L10n.t(
                    "The transcript is sent to the selected provider only when you click Summarize. Transcription itself always stays on this Mac.",
                    "녹취록은 요약 버튼을 눌렀을 때에만 선택한 제공자에게 전송됩니다. 음성 인식 자체는 항상 이 Mac에서만 이루어집니다."))
            }

            if provider == .anthropic {
                Section {
                    Picker(L10n.t("Authentication", "인증 방식"), selection: $anthropicAuthMode) {
                        Text(L10n.t("Local Claude credentials (config dir)", "로컬 Claude 인증 정보 (설정 폴더)")).tag("local")
                        Text(L10n.t("API key", "API 키")).tag("apiKey")
                    }
                    .pickerStyle(.segmented)
                    if anthropicAuthMode == "local" {
                        Label(
                            AnthropicLocalAuth.hasLocalCredentials
                                ? L10n.t("Local credentials detected — no key needed.", "로컬 인증 정보를 찾았습니다 — 키가 필요 없습니다.")
                                : L10n.t(
                                    "No local credentials found. Install the ant CLI (brew install anthropics/tap/ant) and run `ant auth login`.",
                                    "로컬 인증 정보가 없습니다. ant CLI를 설치하고(brew install anthropics/tap/ant) `ant auth login`을 실행하세요."),
                            systemImage: AnthropicLocalAuth.hasLocalCredentials ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Anthropic")
                } footer: {
                    if anthropicAuthMode == "local" {
                        Text(L10n.t(
                            "Uses the credentials in ~/.config/anthropic created by `ant auth login` — the same login the Anthropic CLI and SDKs use.",
                            "`ant auth login`으로 ~/.config/anthropic에 생성된 인증 정보를 사용합니다 — Anthropic CLI 및 SDK와 동일한 로그인입니다."))
                    }
                }
            }

            if provider == .openaiCompatible {
                Section {
                    TextField(L10n.t("Base URL", "기본 URL"), text: $openaiCompatibleURL, prompt: Text("http://localhost:8000/v1"))
                } header: {
                    Text(L10n.t("Server", "서버"))
                } footer: {
                    Text(L10n.t(
                        "Any OpenAI-compatible /v1 endpoint: vLLM, LM Studio, llama.cpp server, LiteLLM, and similar.",
                        "OpenAI 호환 /v1 엔드포인트라면 무엇이든 사용할 수 있습니다: vLLM, LM Studio, llama.cpp 서버, LiteLLM 등."))
                }
            }

            if showsKeyField {
                Section {
                    SecureField(L10n.t("API key for \(provider.displayName)", "\(provider.displayName) API 키"), text: $apiKeyInput)
                    HStack {
                        Button(L10n.t("Save Key", "키 저장")) {
                            Keychain.set(apiKeyInput, account: provider.keychainAccount)
                            apiKeyInput = ""
                            refreshKeyStatus()
                        }
                        .disabled(apiKeyInput.isEmpty)
                        if Keychain.get(account: provider.keychainAccount) != nil {
                            Button(L10n.t("Remove Key", "키 삭제")) {
                                Keychain.set("", account: provider.keychainAccount)
                                refreshKeyStatus()
                            }
                        }
                        Text(keyStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L10n.t("API Key", "API 키"))
                } footer: {
                    if provider == .openaiCompatible {
                        Text(L10n.t(
                            "Optional — leave empty for servers that don't require authentication.",
                            "선택 사항 — 인증이 필요 없는 서버라면 비워 두세요."))
                    }
                }
            }

            if provider == .ollama {
                Section("Ollama") {
                    TextField(L10n.t("Server URL", "서버 URL"), text: $ollamaURL)
                    Text(L10n.t(
                        "Runs models locally — nothing leaves your Mac.",
                        "모델을 로컬에서 실행합니다 — 아무것도 Mac 밖으로 나가지 않습니다."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // Rebuild the whole pane when the provider changes — text fields and
        // menus otherwise keep stale content when only their bindings change.
        .id("summary-pane-\(providerRaw)")
        .task(id: providerRaw) {
            apiKeyInput = ""
            refreshKeyStatus()
        }
    }

    private func refreshKeyStatus() {
        keyStatus = Keychain.get(account: provider.keychainAccount) != nil
            ? L10n.t("✓ A key is saved in your Keychain", "✓ 키체인에 키가 저장되어 있습니다")
            : L10n.t("No key saved yet", "저장된 키가 없습니다")
    }
}

private struct MeetingSettings: View {
    @AppStorage("useCalendarTitles") private var useCalendarTitles = false
    @AppStorage("meetingReminders") private var meetingReminders = false
    @AppStorage("transcriptionLocale") private var transcriptionLocale = "auto"
    @AppStorage("keepAudioFiles") private var keepAudioFiles = true

    private let store = MeetingStore()

    var body: some View {
        Form {
            Section {
                Picker(L10n.t("Transcription language", "음성 인식 언어"), selection: $transcriptionLocale) {
                    Text(L10n.t("Automatic (system language)", "자동 (시스템 언어)")).tag("auto")
                    Text("English").tag("en_US")
                    Text("한국어").tag("ko_KR")
                }
            } footer: {
                Text(L10n.t(
                    "On-device transcription uses one language per meeting. Pick the language the meeting will be held in; the model downloads once per language.",
                    "온디바이스 음성 인식은 회의당 하나의 언어를 사용합니다. 회의에서 사용할 언어를 선택하세요. 언어별 모델은 최초 한 번만 다운로드됩니다."))
            }

            Section {
                Toggle(L10n.t("Name recordings after the current calendar event", "현재 캘린더 일정 이름으로 녹음 제목 지정"), isOn: $useCalendarTitles)
                Toggle(L10n.t("Remind me to record when a meeting starts", "회의가 시작되면 녹음 알림 표시"), isOn: $meetingReminders)
            } footer: {
                Text(L10n.t(
                    "Both are read-only and off by default. macOS will ask for calendar (and notification) access the first time. The reminder notification has a Start Recording button.",
                    "두 기능 모두 읽기 전용이며 기본적으로 꺼져 있습니다. 처음 사용할 때 macOS가 캘린더(및 알림) 접근 권한을 요청합니다. 알림에는 녹음 시작 버튼이 있습니다."))
            }

            Section {
                Toggle(L10n.t("Keep audio recordings (AAC)", "오디오 녹음 파일 보관 (AAC)"), isOn: $keepAudioFiles)
            } footer: {
                Text(L10n.t(
                    "Saves compressed mic and system audio (~40–80 MB per hour) next to each transcript, for playback in the Library.",
                    "압축된 마이크·시스템 오디오(시간당 약 40–80 MB)를 각 녹취록 옆에 저장하여 보관함에서 재생할 수 있습니다."))
            }

            Section(L10n.t("Transcripts", "녹취록")) {
                LabeledContent(L10n.t("Saved to", "저장 위치")) {
                    Text(store.directory.path)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
                Button(L10n.t("Show in Finder", "Finder에서 보기")) {
                    NSWorkspace.shared.open(store.directory)
                }
            }

            Section(L10n.t("Keyboard Shortcuts", "키보드 단축키")) {
                LabeledContent(L10n.t("Start / stop recording", "녹음 시작 / 중지"), value: "⌥⌘R")
                LabeledContent(L10n.t("Flag a key moment", "주요 순간 표시"), value: "⌥⌘K")
                LabeledContent(L10n.t("Pause / resume", "일시정지 / 재개"), value: "⌥⌘P")
                Text(L10n.t(
                    "Both work system-wide — even while you're in the meeting window.",
                    "두 단축키 모두 시스템 전역에서 작동합니다 — 회의 창을 보고 있을 때도 사용할 수 있습니다."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
