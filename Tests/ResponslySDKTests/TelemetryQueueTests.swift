import XCTest
@testable import ResponslySDK

final class TelemetryQueueTests: XCTestCase {
    private var storage: InMemoryStorage!
    private var scheduler: ManualScheduler!
    private var enabled = true
    /// Batches handed to the sender, in order.
    private var sent: [[TelemetryEvent]] = []
    /// What the sender answers; `nil` keeps the request pending in `pendingCompletions`.
    private var answer: TelemetrySendResult? = .sent
    private var pendingCompletions: [(TelemetrySendResult) -> Void] = []

    override func setUp() {
        super.setUp()
        storage = InMemoryStorage()
        scheduler = ManualScheduler()
        enabled = true
        sent = []
        answer = .sent
        pendingCompletions = []
    }

    private func makeQueue() -> TelemetryQueue {
        TelemetryQueue(
            store: StateStore(storage: storage),
            scheduler: scheduler,
            isEnabled: { [unowned self] in self.enabled },
            send: { [unowned self] events, completion in
                self.sent.append(events)
                if let answer = self.answer {
                    completion(answer)
                } else {
                    self.pendingCompletions.append(completion)
                }
            }
        )
    }

    private func enqueue(_ count: Int, into queue: TelemetryQueue, from start: Int = 0) {
        for index in start..<(start + count) {
            queue.enqueue(type: .displayed, surveyId: "S\(index)")
        }
    }

    private var persisted: [TelemetryEvent] {
        StateStore(storage: storage).loadTelemetry()
    }

    func testASingleEventWaitsForTheThirtySecondTimer() {
        let queue = makeQueue()
        queue.enqueue(type: .displayed, surveyId: "S1")
        XCTAssertEqual(sent.count, 0)
        XCTAssertEqual(persisted, [TelemetryEvent(type: .displayed, surveyId: "S1")])
        XCTAssertEqual(scheduler.pendingDelays, [30])

        scheduler.advance(by: 29)
        XCTAssertEqual(sent.count, 0)
        scheduler.advance(by: 1)
        XCTAssertEqual(sent, [[TelemetryEvent(type: .displayed, surveyId: "S1")]])
        XCTAssertEqual(queue.events, [])
        XCTAssertEqual(persisted, [])
        XCTAssertEqual(scheduler.pendingDelays, [])
    }

    func testOnlyOneTimerRunsHoweverManyEventsWait() {
        let queue = makeQueue()
        enqueue(5, into: queue)
        XCTAssertEqual(scheduler.pendingDelays, [30])
        scheduler.advance(by: 30)
        XCTAssertEqual(sent.map { $0.count }, [5])
    }

    func testTwentyEventsFlushImmediately() {
        let queue = makeQueue()
        enqueue(19, into: queue)
        XCTAssertEqual(sent.count, 0)
        enqueue(1, into: queue, from: 19)
        XCTAssertEqual(sent.map { $0.count }, [20])
        XCTAssertEqual(sent.first?.first?.surveyId, "S0")
        XCTAssertEqual(sent.first?.last?.surveyId, "S19")
        XCTAssertEqual(queue.events, [])
        // Nothing is left to wait for.
        XCTAssertEqual(scheduler.pendingDelays, [])
    }

    func testEventsThatCannotBeSentAreKeptAndRetriedLater() {
        answer = .retry
        let queue = makeQueue()
        enqueue(20, into: queue)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(queue.events.count, 20)
        XCTAssertEqual(persisted.count, 20)

        // More events do not hammer the server: the next attempt is the timer's.
        enqueue(5, into: queue, from: 20)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(scheduler.pendingDelays, [30])

        answer = .sent
        scheduler.advance(by: 30)
        XCTAssertEqual(sent.map { $0.count }, [20, 20, 5])
        XCTAssertEqual(queue.events, [])
        XCTAssertEqual(persisted, [])
    }

    func testAtMostTwoHundredEventsAreKeptOldestDropped() {
        answer = .retry
        let queue = makeQueue()
        enqueue(250, into: queue)
        XCTAssertEqual(queue.events.count, 200)
        XCTAssertEqual(queue.events.first?.surveyId, "S50")
        XCTAssertEqual(queue.events.last?.surveyId, "S249")
        XCTAssertEqual(persisted.count, 200)
    }

    func testTheBatchBeingSentIsNotDroppedByTheLimit() {
        answer = nil
        let queue = makeQueue()
        enqueue(20, into: queue)
        XCTAssertEqual(pendingCompletions.count, 1)
        // 190 more arrive while the first 20 are in flight: the queue trims behind the batch.
        enqueue(190, into: queue, from: 20)
        XCTAssertEqual(queue.events.count, 200)
        XCTAssertEqual(queue.events.prefix(20).map { $0.surveyId }, (0..<20).map { "S\($0)" })
        XCTAssertEqual(queue.events[20].surveyId, "S30")

        answer = .retry
        pendingCompletions.removeFirst()(.sent)
        XCTAssertEqual(queue.events.count, 180)
        XCTAssertEqual(queue.events.first?.surveyId, "S30")
    }

    func testNothingIsSentWhileTrackingIsDisabled() {
        enabled = false
        let queue = makeQueue()
        enqueue(25, into: queue)
        XCTAssertEqual(sent.count, 0)
        XCTAssertEqual(scheduler.pendingDelays, [])
        var completed = false
        queue.flush { completed = true }
        XCTAssertTrue(completed)
        XCTAssertEqual(sent.count, 0)
        XCTAssertEqual(queue.events.count, 25)

        enabled = true
        queue.scheduleFlushIfNeeded()
        scheduler.advance(by: 30)
        XCTAssertEqual(sent.map { $0.count }, [20, 5])
    }

    func testFlushOnBackgroundSendsEverythingInBatchesAndReports() {
        enabled = false
        let queue = makeQueue()
        enqueue(45, into: queue)
        enabled = true

        var completions = 0
        queue.flush { completions += 1 }
        XCTAssertEqual(sent.map { $0.count }, [20, 20, 5])
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(queue.events, [])
    }

    func testFlushCompletionRunsWhenTheSendFails() {
        answer = nil
        let queue = makeQueue()
        enqueue(3, into: queue)
        var completions = 0
        queue.flush { completions += 1 }
        queue.flush { completions += 1 }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(completions, 0)

        pendingCompletions.removeFirst()(.retry)
        XCTAssertEqual(completions, 2)
        XCTAssertEqual(queue.events.count, 3)
        XCTAssertEqual(scheduler.pendingDelays, [30])
    }

    func testARejectedBatchIsDropped() {
        answer = .rejected
        let queue = makeQueue()
        enqueue(20, into: queue)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(queue.events, [])
        XCTAssertEqual(persisted, [])
    }

    func testTheQueueSurvivesARelaunch() {
        answer = .retry
        var queue: TelemetryQueue? = makeQueue()
        queue?.enqueue(type: .displayed, surveyId: "S1")
        queue?.enqueue(type: .dismissed, surveyId: "S1")
        queue = nil

        answer = .sent
        let relaunched = makeQueue()
        XCTAssertEqual(relaunched.events, [
            TelemetryEvent(type: .displayed, surveyId: "S1"),
            TelemetryEvent(type: .dismissed, surveyId: "S1"),
        ])
        relaunched.scheduleFlushIfNeeded()
        scheduler.advance(by: 30)
        XCTAssertEqual(sent.last?.count, 2)
        XCTAssertEqual(persisted, [])
    }

    func testClearDropsEverythingIncludingABatchInFlight() {
        answer = nil
        let queue = makeQueue()
        enqueue(20, into: queue)
        queue.clear()
        XCTAssertEqual(queue.events, [])
        XCTAssertEqual(persisted, [])

        // A new event arrives, then the old request finishes: the new event must stay.
        queue.enqueue(type: .completed, surveyId: "new")
        pendingCompletions.removeFirst()(.sent)
        XCTAssertEqual(queue.events, [TelemetryEvent(type: .completed, surveyId: "new")])
    }
}

final class APIClientTests: XCTestCase {
    private let transport = FakeTransport()

    private func makeClient(host: String = "https://api.responsly.com") -> APIClient {
        APIClient(
            apiHost: URL(string: host)!, sdkKey: "rsk_test", platform: "ios",
            sdkVersion: "1.0.0", appId: "com.acme.app", transport: transport
        )
    }

    private func fetch(_ client: APIClient, etag: String? = nil) -> ConfigFetchResult? {
        var result: ConfigFetchResult?
        client.fetchConfig(etag: etag) { result = $0 }
        return result
    }

    func testConfigRequestCarriesTheProtocolHeaders() throws {
        transport.respond = { _ in FakeTransport.status(500) }
        _ = fetch(makeClient())

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.responsly.com/sdk/v1/config")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Responsly-Sdk-Key"), "rsk_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Responsly-Platform"), "ios")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Responsly-Sdk-Version"), "1.0.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Responsly-App-Id"), "com.acme.app")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertNil(request.httpBody)
    }

    func testIfNoneMatchIsSentWithTheLastETag() throws {
        transport.respond = { _ in FakeTransport.status(304) }
        XCTAssertEqual(fetch(makeClient(), etag: "W/\"abc\""), .notModified)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "If-None-Match"), "W/\"abc\"")
    }

    func testAPIHostWithATrailingSlashOrAPathPrefix() {
        transport.respond = { _ in FakeTransport.status(500) }
        _ = fetch(makeClient(host: "http://localhost:8000/"))
        _ = fetch(makeClient(host: "https://example.test/api"))
        XCTAssertEqual(transport.requests.map { $0.url?.absoluteString }, [
            "http://localhost:8000/sdk/v1/config",
            "https://example.test/api/sdk/v1/config",
        ])
    }

    func testConfigResponses() throws {
        let body = #"{"ttl":120,"surveys":[{"id":"S1","url":"https://x.test/s"}]}"#
        transport.respond = { _ in FakeTransport.json(body, headers: ["etag": "\"v2\""]) }
        guard case .fetched(let config, let data, let etag)? = fetch(makeClient()) else {
            return XCTFail("expected a configuration")
        }
        XCTAssertEqual(config.ttl, 120)
        XCTAssertEqual(config.surveys.map { $0.id }, ["S1"])
        XCTAssertEqual(data, Data(body.utf8))
        XCTAssertEqual(etag, "\"v2\"")

        transport.respond = { _ in FakeTransport.json(#"{"error":"invalid_sdk_key"}"#, status: 401) }
        XCTAssertEqual(fetch(makeClient()), .invalidKey)

        transport.respond = { _ in FakeTransport.status(503) }
        XCTAssertEqual(fetch(makeClient()), .failed("HTTP 503"))

        for status in [301, 302, 307, 308] {
            transport.respond = { _ in FakeTransport.status(status) }
            XCTAssertEqual(fetch(makeClient()), .redirected(status: status))
        }

        transport.respond = { _ in .failure("offline") }
        XCTAssertEqual(fetch(makeClient()), .failed("offline"))

        transport.respond = { _ in FakeTransport.json("<html>maintenance</html>") }
        guard case .failed? = fetch(makeClient()) else {
            return XCTFail("an unreadable body must not replace the cached copy")
        }
    }

    func testEventsRequest() throws {
        transport.respond = { _ in FakeTransport.status(204) }
        var result: TelemetrySendResult?
        makeClient().sendEvents([
            TelemetryEvent(type: .displayed, surveyId: "aBcD1234"),
            TelemetryEvent(type: .completed, surveyId: "aBcD1234"),
        ]) { result = $0 }
        XCTAssertEqual(result, .sent)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.responsly.com/sdk/v1/events")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Responsly-Sdk-Key"), "rsk_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Responsly-Platform"), "ios")
        // Nothing but the type and the survey id: no user, install id, traits or timestamps.
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(
            String(decoding: body, as: UTF8.self),
            #"{"events":[{"survey_id":"aBcD1234","type":"displayed"},{"survey_id":"aBcD1234","type":"completed"}]}"#
        )
    }

    func testEventsResponses() {
        func send(_ result: HTTPResult) -> TelemetrySendResult? {
            transport.respond = { _ in result }
            var outcome: TelemetrySendResult?
            makeClient().sendEvents([TelemetryEvent(type: .dismissed, surveyId: "S")]) { outcome = $0 }
            return outcome
        }
        XCTAssertEqual(send(FakeTransport.status(204)), .sent)
        XCTAssertEqual(send(FakeTransport.status(200)), .sent)
        XCTAssertEqual(send(FakeTransport.status(500)), .retry)
        XCTAssertEqual(send(FakeTransport.status(429)), .retry)
        XCTAssertEqual(send(.failure("offline")), .retry)
        XCTAssertEqual(send(FakeTransport.status(400)), .rejected)
        XCTAssertEqual(send(FakeTransport.status(401)), .rejected)
    }
}
