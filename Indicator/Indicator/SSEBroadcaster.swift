import Foundation
import Network

// Manages a set of open SSE connections and broadcasts messages to all of them.
class SSEBroadcaster {

    private var connections: [NWConnection] = []
    private let lock = NSLock()

    func add(_ conn: NWConnection) {
        lock.lock()
        connections.append(conn)
        lock.unlock()
        // Remove when connection dies
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.remove(conn) }
            if case .cancelled = state { self?.remove(conn) }
        }
    }

    func send(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        lock.lock()
        let active = connections
        lock.unlock()
        for conn in active {
            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.remove(conn) }
            })
        }
    }

    private func remove(_ conn: NWConnection) {
        lock.lock()
        connections.removeAll { $0 === conn }
        lock.unlock()
    }
}
