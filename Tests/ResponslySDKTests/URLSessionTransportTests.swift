import Network
import XCTest
@testable import ResponslySDK

final class URLSessionTransportTests: XCTestCase {
    func testRedirectsNeverForwardSDKHeadersOrTelemetry() throws {
        for status in [301, 302, 303, 307, 308] {
            let server = try RedirectServer(status: status)
            defer { server.stop() }
            let ready = expectation(description: "HTTP listener ready")
            server.start { ready.fulfill() }
            wait(for: [ready], timeout: 5)
            let port = try XCTUnwrap(server.port)

            let completed = expectation(description: "HTTP request completed")
            let transport = URLSessionTransport()
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/sdk/v1/events")!)
            request.httpMethod = "POST"
            request.setValue("rsk_test", forHTTPHeaderField: "X-Responsly-Sdk-Key")
            request.httpBody = Data(#"{"events":[{"type":"displayed","survey_id":"S1"}]}"#.utf8)
            transport.perform(request) { result in
                guard case .response(let actualStatus, _, _) = result else {
                    XCTFail("expected the original redirect response, got \(result)")
                    completed.fulfill()
                    return
                }
                XCTAssertEqual(actualStatus, status)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 5)
            XCTAssertEqual(server.requests.count, 1, "HTTP \(status) followed the redirect")
            XCTAssertFalse(server.requests.dropFirst().contains { $0.contains("X-Responsly-Sdk-Key: rsk_test") },
                           "HTTP \(status) forwarded the SDK key to a different origin")
            XCTAssertTrue(server.requests.first?.contains("X-Responsly-Sdk-Key: rsk_test") == true)
        }
    }
}

/// A loopback HTTP server exercises URLSession's real redirect handling, including POSTs.
private final class RedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.responsly.tests.redirect-server")
    private let status: Int
    private let lock = NSLock()
    private var recorded: [String] = []

    init(status: Int) throws {
        self.status = status
        listener = try NWListener(using: .tcp, on: .any)
    }

    var port: UInt16? { listener.port?.rawValue }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func start(ready: @escaping () -> Void) {
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self = self else { return }
            var buffer = buffer
            buffer.append(data ?? Data())
            let text = String(decoding: buffer, as: UTF8.self)
            guard text.contains("\r\n\r\n") else {
                if !complete, error == nil { self.receive(connection, buffer: buffer) }
                return
            }
            self.lock.lock()
            self.recorded.append(text)
            self.lock.unlock()
            let captured = text.hasPrefix("GET /capture ") || text.hasPrefix("POST /capture ")
            let response = captured
                ? "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                : "HTTP/1.1 \(self.status) Redirect\r\nLocation: http://localhost:\(self.port!)/capture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
