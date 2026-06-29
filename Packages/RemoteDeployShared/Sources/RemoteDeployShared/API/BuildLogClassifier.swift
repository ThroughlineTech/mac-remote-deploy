import Foundation

/// Semantic classification of a single build-log line.
///
/// The menu bar's build-log window used to recolor every line on each SwiftUI
/// body/layout pass via an inline `colorForLine` closure (lowercase + substring
/// scans), which the idle render loop re-ran constantly and which dominated the
/// app's CPU while a window was open (TKT-074). Classifying a line is pure and
/// presentation-free, so it lives here in the shared package: it is computed
/// ONCE per line (see `BuildLogClassifierCache`) and is unit-testable from
/// RemoteDeployTests, which cannot link the menu bar target. The view maps the
/// kind to a `Color`.
public enum BuildLogLineKind: String, Equatable, Sendable {
    case normal
    case error
    case warning
    case success

    /// Classifies a log line by content, mirroring the menu bar's prior
    /// `colorForLine`: an `error:`/`fatal` line is an error, a `warning:` line a
    /// warning, a "build succeeded" line a success, everything else normal.
    public static func classify(_ line: String) -> BuildLogLineKind {
        let lower = line.lowercased()
        if lower.contains("error:") || lower.contains("fatal") {
            return .error
        } else if lower.contains("warning:") {
            return .warning
        } else if lower.contains("build succeeded") {
            return .success
        } else {
            return .normal
        }
    }
}

/// Incrementally classifies an append-only build log, caching prior results so a
/// SwiftUI re-render reclassifies only newly-appended lines instead of the whole
/// buffer on every pass (TKT-074).
///
/// The live log only ever grows (a line is appended) or resets (cleared, or a new
/// build starts and the buffer is emptied); lines are never edited in place. That
/// lets the cache decide in O(1) whether the new input is an append (reuse the
/// cached prefix, classify just the tail) or a reset (reclassify everything),
/// keyed off the count and the previously-last line. The idle render loop, which
/// re-evaluates the view body with unchanged input, then returns the cached
/// result without reclassifying anything.
///
/// Not thread-safe: drive it from a single actor (the menu bar's main-actor log
/// view).
public final class BuildLogClassifierCache {

    /// A log line paired with its classification.
    public struct Entry: Equatable, Sendable {
        public let text: String
        public let kind: BuildLogLineKind

        public init(text: String, kind: BuildLogLineKind) {
            self.text = text
            self.kind = kind
        }
    }

    /// The classified lines from the most recent `classify(_:)` call. Invariant:
    /// `entries.count` equals the source-line count and `entries.last?.text`
    /// equals `lastSource`.
    public private(set) var entries: [Entry] = []

    /// The last source line seen, used to tell an append from a reset in O(1).
    private var lastSource: String?

    public init() {}

    /// Returns the classified entries for `lines`, reclassifying only what
    /// actually changed since the previous call.
    public func classify(_ lines: [String]) -> [Entry] {
        let count = lines.count
        let cached = entries.count

        // Unchanged: same length and same tail. The dominant case under the idle
        // SwiftUI render loop, where the body re-evaluates with identical input.
        if count == cached, lines.last == lastSource {
            return entries
        }

        if count > cached, cached > 0, lines[cached - 1] == lastSource {
            // Append-only growth: the previously-last line is unchanged at its
            // index, so keep the cached prefix and classify just the new tail.
            var grown = entries
            grown.reserveCapacity(count)
            for index in cached..<count {
                grown.append(Entry(text: lines[index], kind: .classify(lines[index])))
            }
            entries = grown
        } else {
            // Reset, clear, first fill, or a shrink: reclassify everything.
            entries = lines.map { Entry(text: $0, kind: .classify($0)) }
        }

        lastSource = lines.last
        return entries
    }
}
