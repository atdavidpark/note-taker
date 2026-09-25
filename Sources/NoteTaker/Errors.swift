import Foundation

enum NoteTakerError: LocalizedError {
    case microphoneAccessDenied
    case microphoneUnavailable
    case speechModelUnavailable
    case coreAudio(String, OSStatus)
    case missingAPIKey(String)
    case summarizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            return L10n.t(
                "Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone.",
                "마이크 접근이 거부되었습니다. 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 허용해 주세요.")
        case .microphoneUnavailable:
            return L10n.t(
                "No usable microphone input was found.",
                "사용 가능한 마이크 입력을 찾을 수 없습니다.")
        case .speechModelUnavailable:
            return L10n.t(
                "On-device speech transcription is not available for the selected language.",
                "선택한 언어는 온디바이스 음성 인식을 지원하지 않습니다.")
        case .coreAudio(let step, let status):
            return L10n.t(
                "System audio capture failed at \(step) (OSStatus \(status)). Check System Settings > Privacy & Security > Screen & System Audio Recording.",
                "시스템 오디오 캡처가 \(step) 단계에서 실패했습니다 (OSStatus \(status)). 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음을 확인해 주세요.")
        case .missingAPIKey(let provider):
            return L10n.t(
                "No API key saved for \(provider). Add one in Settings.",
                "\(provider)의 API 키가 저장되어 있지 않습니다. 설정에서 추가해 주세요.")
        case .summarizationFailed(let message):
            return L10n.t("Summarization failed: \(message)", "요약 실패: \(message)")
        }
    }
}
