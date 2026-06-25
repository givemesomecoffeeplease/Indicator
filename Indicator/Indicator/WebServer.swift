import Foundation
import Network

// Minimal HTTP server using Network.framework.
// Serves index.html on GET / and SSE stream on GET /events.
class WebServer {

    private var listener: NWListener?
    private let broadcaster = SSEBroadcaster()
    private var htmlContent: String = ""

    func start(port: UInt16) {
        loadHTML()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        listener = try? NWListener(using: params, on: nwPort)
        listener?.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener?.start(queue: .global(qos: .utility))
        print("[WebServer] Listening on port \(port)")
    }

    func stop() {
        listener?.cancel()
    }

    func broadcast(state: IndicatorState) {
        guard let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else { return }
        broadcaster.send("data: \(json)\n\n")
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        receiveRequest(conn)
    }

    private func receiveRequest(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, let data, error == nil else { conn.cancel(); return }
            let request = String(data: data, encoding: .utf8) ?? ""
            let firstLine = request.split(separator: "\n").first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count >= 2 ? String(parts[1]) : "/"

            if path == "/events" {
                self.handleSSE(conn)
            } else {
                self.handleHTML(conn)
            }
        }
    }

    private func handleHTML(_ conn: NWConnection) {
        let body = htmlContent.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = header.data(using: .utf8)!
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func handleSSE(_ conn: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        conn.send(content: header.data(using: .utf8), completion: .contentProcessed { _ in })
        broadcaster.add(conn)
    }

    // MARK: - HTML loading

    private func loadHTML() {
        // Try bundle resource first, fall back to embedded string
        if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            htmlContent = content
        } else {
            htmlContent = embeddedHTML
        }
    }

    private let embeddedHTML = """
    <!DOCTYPE html><html><body><h1>Indicator</h1><p>index.html not found in bundle.</p></body></html>
    """
}
