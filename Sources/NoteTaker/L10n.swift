import Foundation

/// Lightweight English/Korean localization that follows the system language.
enum L10n {
    static let isKorean: Bool =
        Locale.preferredLanguages.first?.lowercased().hasPrefix("ko") ?? false

    /// Returns the Korean string when the Mac's preferred language is Korean.
    static func t(_ english: String, _ korean: String) -> String {
        isKorean ? korean : english
    }
}
