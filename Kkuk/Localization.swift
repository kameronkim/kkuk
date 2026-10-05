import Foundation

/// Interface language follows macOS, including the app-specific language preference.
enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
    static func presetName(_ dictionaryMiB: Int) -> String {
        let key: String
        switch dictionaryMiB {
        case ...64: key = "Small high compression"
        case ...128: key = "Standard high compression"
        case ...256: key = "Large high compression"
        case ...512: key = "Extra-large high compression"
        default: key = "Maximum high compression"
        }
        return text(key)
    }
}
