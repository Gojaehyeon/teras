import Foundation
import os

/// Log categories; each maps to one `os.Logger` under the `app.teras` subsystem.
enum LogCategory: String, CaseIterable, Sendable {
    case app, display, capture, encode, transport, session, input, store
}

/// One line in the in-memory ring buffer shown in Settings → Diagnostics.
struct LogEntry: Identifiable, Sendable, Equatable {
    enum Level: String, Sendable { case debug = "DBG", info = "INF", error = "ERR" }
    let id: UInt64
    let date: Date
    let level: Level
    let category: LogCategory
    let message: String

    var line: String {
        "\(LogRing.timestampFormatter.string(from: date))  \(level.rawValue)  \(category.rawValue)  \(message)"
    }
}

/// Bounded, thread-safe ring buffer of recent log lines. Lets the Diagnostics
/// tab show what happened without asking the user to open Console.app.
final class LogRing: @unchecked Sendable {
    static let shared = LogRing()
    static let capacity = 2000

    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private var nextID: UInt64 = 0

    /// Bumped on every append so SwiftUI views can poll cheaply.
    private(set) var generation: UInt64 = 0

    func append(level: LogEntry.Level, category: LogCategory, message: String) {
        lock.lock()
        defer { lock.unlock() }
        let entry = LogEntry(id: nextID, date: Date(), level: level, category: category, message: message)
        nextID &+= 1
        generation &+= 1
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    func snapshot() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func plainText() -> String {
        snapshot().map(\.line).joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
        generation &+= 1
    }
}

/// Facade over `os.Logger` that also mirrors into `LogRing`.
enum Log {
    static let subsystem = "app.teras"

    private static let loggers: [LogCategory: Logger] = {
        var map: [LogCategory: Logger] = [:]
        for category in LogCategory.allCases {
            map[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return map
    }()

    private static func logger(_ category: LogCategory) -> Logger {
        loggers[category] ?? Logger(subsystem: subsystem, category: category.rawValue)
    }

    static func debug(_ category: LogCategory, _ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        logger(category).debug("\(text, privacy: .public)")
        LogRing.shared.append(level: .debug, category: category, message: text)
        #endif
    }

    static func info(_ category: LogCategory, _ message: @autoclosure () -> String) {
        let text = message()
        logger(category).info("\(text, privacy: .public)")
        LogRing.shared.append(level: .info, category: category, message: text)
    }

    static func error(_ category: LogCategory, _ message: @autoclosure () -> String) {
        let text = message()
        logger(category).error("\(text, privacy: .public)")
        LogRing.shared.append(level: .error, category: category, message: text)
    }
}
