import Foundation

/// What the receiver reports in STATS (PROTOCOL §7) and shows in the overlay.
struct VideoStatsSnapshot: Equatable {
    var fpsDecoded: Double = 0
    var fpsDropped: Double = 0
    var decodeMsP50: Double = 0
    var queued: Int = 0
    var e2eMsP50: Double?
    var codec: String = ""
    var width: Int = 0
    var height: Int = 0
}

/// Fixed-window (1 s) sample collector used for the p50 figures.
struct RollingWindow {
    private var samples: [(time: TimeInterval, value: Double)] = []
    let window: TimeInterval

    init(window: TimeInterval = 1.0) { self.window = window }

    mutating func add(_ value: Double, now: TimeInterval) {
        samples.append((now, value))
        prune(now: now)
    }

    mutating func prune(now: TimeInterval) {
        let cutoff = now - window
        if let index = samples.firstIndex(where: { $0.time >= cutoff }) {
            if index > 0 { samples.removeFirst(index) }
        } else {
            samples.removeAll(keepingCapacity: true)
        }
    }

    mutating func count(now: TimeInterval) -> Int {
        prune(now: now)
        return samples.count
    }

    mutating func percentile50(now: TimeInterval) -> Double {
        prune(now: now)
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.map(\.value).sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}
