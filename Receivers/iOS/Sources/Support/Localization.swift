import Foundation
import SwiftUI

/// Small helpers over the app's String Catalog (`Resources/Localizable.xcstrings`).
enum L {
    static func s(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: args)
    }
    static func key(_ key: String) -> LocalizedStringKey {
        LocalizedStringKey(key)
    }
}
