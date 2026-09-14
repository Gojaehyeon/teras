import Foundation

/// Look up a localized string from the app bundle.
///
/// The UI lives in the TandemCore framework but the string catalogs ship in the
/// app, so every lookup is explicitly against `Bundle.main`.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

/// Localized string with positional arguments.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: .main, comment: ""), arguments: arguments)
}
