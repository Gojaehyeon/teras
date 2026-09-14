import Foundation
import TandemProtocol

/// This Mac's stable identity on the wire. The id is generated once and kept in
/// user defaults; receivers file their pairing secret under it.
enum HostIdentity {
    private static let idKey = "host.id"

    static var hostId: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: idKey), UUID(uuidString: existing) != nil {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: idKey)
        Log.info(.store, "Generated host id \(fresh)")
        return fresh
    }

    static var hostName: String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return name.isEmpty ? "Mac" : name
    }

    static var appInfo: AppInfo {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Int(info?["CFBundleVersion"] as? String ?? "1") ?? 1
        return AppInfo(name: "Tandem", version: version, build: build)
    }
}
