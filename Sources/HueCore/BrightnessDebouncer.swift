import Foundation

/// Brightness while a slider is dragged: at most one command per `interval` (150 ms, the Hue
/// bridge's comfortable rate) per slider, the latest value always sent shortly after the drag
/// pauses (trailing edge), and the final value at once when the slider is released. Values that
/// were already sent are not sent again.
///
/// Not thread safe: use it from `queue` only (the main queue in the app).
public final class BrightnessDebouncer {
    public let interval: TimeInterval
    private let queue: DispatchQueue
    private let now: () -> Date
    private let send: (String, Int) -> Void

    private var values: [String: Int] = [:]
    private var sentValue: [String: Int] = [:]
    private var lastSent: [String: Date] = [:]
    private var trailing: [String: DispatchWorkItem] = [:]

    public init(interval: TimeInterval = 0.15, queue: DispatchQueue = .main,
                now: @escaping () -> Date = Date.init, send: @escaping (String, Int) -> Void) {
        self.interval = interval
        self.queue = queue
        self.now = now
        self.send = send
    }

    /// The value being dragged for `target`, nil when that slider is not being dragged.
    public func value(for target: String) -> Int? { values[target] }

    public func update(_ target: String, _ value: Int) {
        values[target] = value
        let elapsed = lastSent[target].map { now().timeIntervalSince($0) } ?? .infinity
        if elapsed >= interval {
            trailing.removeValue(forKey: target)?.cancel()
            fire(target)
        } else if trailing[target] == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.trailing.removeValue(forKey: target)
                self?.fire(target)
            }
            trailing[target] = work
            queue.asyncAfter(deadline: .now() + (interval - elapsed), execute: work)
        }
    }

    /// Slider released: the last value now (unless it was just sent), then forget the drag.
    public func finish(_ target: String) {
        trailing.removeValue(forKey: target)?.cancel()
        fire(target)
        values.removeValue(forKey: target)
        sentValue.removeValue(forKey: target)
    }

    private func fire(_ target: String) {
        guard let value = values[target] else { return }
        lastSent[target] = now()
        if sentValue[target] != value {
            sentValue[target] = value
            send(target, value)
        }
    }
}
