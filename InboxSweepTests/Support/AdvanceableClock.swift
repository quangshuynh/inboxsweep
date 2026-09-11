import Foundation

/// A clock a test can move forward, for cases where *when* things happened is the point.
///
/// The session takes its `now` as a `@Sendable () -> Date`, so a plain captured `var` cannot be
/// used: the closure outlives the statement that mutates it. This is the smallest thing that is
/// both mutable and safe to capture.
nonisolated final class AdvanceableClock: @unchecked Sendable {

    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}
