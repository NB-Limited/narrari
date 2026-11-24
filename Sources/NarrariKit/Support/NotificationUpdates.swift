import Foundation

extension NotificationCenter {
    // Registers at once, so a post right after this call is never missed; bursts collapse into one update.
    func updates(
        of name: Notification.Name, where matches: @escaping @Sendable (Notification) -> Bool = { _ in true }
    ) -> AsyncStream<Void> {
        stream(of: name, buffering: .bufferingNewest(1)) { matches($0) ? () : nil }
    }

    // Each post's object as text, every one in order, such as the key a distributed post names.
    func objects(of name: Notification.Name) -> AsyncStream<String> {
        stream(of: name, buffering: .unbounded) { $0.object as? String }
    }

    private func stream<Value: Sendable>(
        of name: Notification.Name,
        buffering: AsyncStream<Value>.Continuation.BufferingPolicy,
        reading value: @escaping @Sendable (Notification) -> Value?
    ) -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: buffering) { continuation in
            let token = addObserver(forName: name, object: nil, queue: nil) { note in
                if let value = value(note) { continuation.yield(value) }
            }
            let registration = Registration(token: token, center: self)
            continuation.onTermination = { _ in registration.remove() }
        }
    }
}

// The token only goes back to removeObserver, which may be called from any thread.
private struct Registration: @unchecked Sendable {
    let token: any NSObjectProtocol
    let center: NotificationCenter

    func remove() {
        center.removeObserver(token)
    }
}
