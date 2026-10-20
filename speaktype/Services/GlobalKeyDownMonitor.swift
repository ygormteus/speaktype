import AppKit

@MainActor
final class GlobalKeyDownMonitor {
    typealias Handler = (NSEvent) -> Void
    typealias Installer = (@escaping Handler) -> Any?
    static let shared = GlobalKeyDownMonitor()

    private let install: Installer
    private let remove: (Any) -> Void
    private var observer: Any?
    private var handlers: [UUID: Handler] = [:]

    init(install: Installer? = nil, remove: ((Any) -> Void)? = nil) {
        self.install = install ?? { handler in PassiveKeyDownObserver(handler: handler) }
        self.remove = remove ?? { ($0 as? PassiveKeyDownObserver)?.stop() }
    }

    deinit {
        if let observer { remove(observer) }
    }

    @discardableResult
    func addHandler(_ handler: @escaping Handler) -> UUID {
        let token = UUID()
        handlers[token] = handler
        if observer == nil {
            observer = install { [weak self] event in self?.deliver(event) }
        }
        return token
    }

    func removeHandler(_ token: UUID) {
        handlers.removeValue(forKey: token)
        if handlers.isEmpty, let observer {
            self.observer = nil
            remove(observer)
        }
    }

    private func deliver(_ event: NSEvent) {
        for handler in Array(handlers.values) { handler(event) }
    }
}
