import Dispatch

/// Forwards system memory-pressure events (warning / critical) to a handler.
final class MemoryPressureMonitor: Sendable {
    enum Level: Sendable {
        case warning
        case critical
    }

    private let source: any DispatchSourceMemoryPressure

    init(queue: DispatchQueue = .global(qos: .utility), handler: @escaping @Sendable (Level) -> Void) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            if event.contains(.critical) {
                handler(.critical)
            } else if event.contains(.warning) {
                handler(.warning)
            }
        }
        source.activate()
        self.source = source
    }

    deinit {
        source.cancel()
    }
}
