import XCTest
@testable import ResponslySDK

/// A scheduler whose time only moves when a test says so.
final class ManualScheduler: Scheduler {
    private final class Item: Cancellable {
        let fireAt: TimeInterval
        let block: () -> Void
        var isCancelled = false

        init(fireAt: TimeInterval, block: @escaping () -> Void) {
            self.fireAt = fireAt
            self.block = block
        }

        func cancel() {
            isCancelled = true
        }
    }

    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var items: [Item] = []

    /// Called after each fired block, so that follow-up timers get scheduled before time moves on.
    var afterFire: (() -> Void)?

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
        lock.lock()
        defer { lock.unlock() }
        let item = Item(fireAt: time + delay, block: block)
        items.append(item)
        return item
    }

    /// Delays of the timers that are waiting, relative to now, sorted.
    var pendingDelays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return items.filter { !$0.isCancelled }.map { $0.fireAt - time }.sorted()
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        let target = time + seconds
        lock.unlock()
        while true {
            lock.lock()
            items.removeAll { $0.isCancelled }
            // The tolerance absorbs floating-point noise from adding up small steps.
            let due = items.filter { $0.fireAt <= target + 1e-9 }.min { $0.fireAt < $1.fireAt }
            if let due = due {
                items.removeAll { $0 === due }
                time = max(time, due.fireAt)
            } else {
                time = target
            }
            lock.unlock()
            guard let item = due else { break }
            item.block()
            afterFire?()
        }
    }
}

/// Records requests and answers them from `respond`; a `nil` answer keeps the request pending.
final class FakeTransport: HTTPTransport {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var pending: [(HTTPResult) -> Void] = []
    private var responder: ((URLRequest) -> HTTPResult?)?

    var respond: ((URLRequest) -> HTTPResult?)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return responder
        }
        set {
            lock.lock()
            responder = newValue
            lock.unlock()
        }
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var configRequests: [URLRequest] {
        requests.filter { $0.url?.path.hasSuffix("/sdk/v1/config") == true }
    }

    var eventRequests: [URLRequest] {
        requests.filter { $0.url?.path.hasSuffix("/sdk/v1/events") == true }
    }

    func perform(_ request: URLRequest, completion: @escaping (HTTPResult) -> Void) {
        lock.lock()
        recorded.append(request)
        let responder = self.responder
        lock.unlock()
        if let result = responder?(request) {
            completion(result)
        } else {
            lock.lock()
            pending.append(completion)
            lock.unlock()
        }
    }

    /// Answers the oldest pending request.
    func completePending(with result: HTTPResult) {
        lock.lock()
        let completion = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        completion?(result)
    }

    static func json(_ string: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResult {
        .response(status: status, headers: headers, body: Data(string.utf8))
    }

    static func status(_ status: Int) -> HTTPResult {
        .response(status: status, headers: [:], body: Data())
    }
}

/// Stands in for the UI layer: records what the core asks for and lets a test play the page.
final class FakePresenter: SurveyPresenting {
    private let lock = NSLock()
    private var requests: [SurveyPresentationRequest] = []
    private var handlers: [UUID: (SurveyPresentationEvent) -> Void] = [:]
    private var revealedIds: [UUID] = []
    private var userCloseIds: [UUID] = []
    private var dismissals: [(id: UUID, animated: Bool)] = []
    private var clearedHostLists: [[String]] = []

    var presented: [SurveyPresentationRequest] { locked { requests } }
    var revealed: [UUID] { locked { revealedIds } }
    var userCloseEnabled: [UUID] { locked { userCloseIds } }
    var dismissed: [(id: UUID, animated: Bool)] { locked { dismissals } }
    var clearedHosts: [[String]] { locked { clearedHostLists } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func present(_ request: SurveyPresentationRequest, eventHandler: @escaping (SurveyPresentationEvent) -> Void) {
        locked {
            requests.append(request)
            handlers[request.sessionId] = eventHandler
        }
    }

    func reveal(sessionId: UUID) {
        locked { revealedIds.append(sessionId) }
    }

    func enableUserClose(sessionId: UUID) {
        locked { userCloseIds.append(sessionId) }
    }

    func dismiss(sessionId: UUID, animated: Bool) {
        locked { dismissals.append((sessionId, animated)) }
    }

    func clearWebsiteData(forHosts hosts: [String]) {
        locked { clearedHostLists.append(hosts) }
    }

    /// Delivers an event from the most recently presented survey.
    func send(_ event: SurveyPresentationEvent) {
        let handler: ((SurveyPresentationEvent) -> Void)? = locked {
            guard let last = requests.last else { return nil }
            return handlers[last.sessionId]
        }
        handler?(event)
    }

    /// Delivers a bridge message, given as `type` and a JSON payload.
    func sendMessage(_ type: String, payload: String = "{}", file: StaticString = #filePath, line: UInt = #line) {
        let raw = "{\"responsly\":1,\"type\":\"\(type)\",\"payload\":\(payload)}"
        guard let message = BridgeMessage.parse(raw) else {
            XCTFail("unparsable bridge message: \(raw)", file: file, line: line)
            return
        }
        send(.message(message, raw: raw))
    }
}

/// Collects blocks meant for the main thread; the test runs them (it is on the main thread).
final class MainStub {
    private let lock = NSLock()
    private var blocks: [() -> Void] = []

    func enqueue(_ block: @escaping () -> Void) {
        lock.lock()
        blocks.append(block)
        lock.unlock()
    }

    @discardableResult
    func drain() -> Int {
        lock.lock()
        let pending = blocks
        blocks = []
        lock.unlock()
        pending.forEach { $0() }
        return pending.count
    }
}

final class TestClock {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Records every listener callback as a short string.
final class RecordingListener: ResponslyListener {
    private(set) var events: [String] = []
    private(set) var answers: [ResponslyQuestionAnsweredEvent] = []
    private(set) var completions: [ResponslySurveyCompletedEvent] = []
    private(set) var calledOffMainThread = false

    private func record(_ event: String) {
        if !Thread.isMainThread {
            calledOffMainThread = true
        }
        events.append(event)
    }

    func surveyShown(_ event: ResponslySurveyShownEvent) {
        record("shown:\(event.survey.id):\(event.trigger.type.rawValue)\(event.trigger.name.map { ":" + $0 } ?? "")")
    }

    func surveyNotShown(_ event: ResponslySurveyNotShownEvent) {
        record("notShown:\(event.surveyId):\(event.reason.rawValue)")
    }

    func questionAnswered(_ event: ResponslyQuestionAnsweredEvent) {
        answers.append(event)
        record("answered:\(event.surveyId):\(event.questionId)")
    }

    func surveyCompleted(_ event: ResponslySurveyCompletedEvent) {
        completions.append(event)
        record("completed:\(event.surveyId):\(event.responseId)")
    }

    func surveyDismissed(_ event: ResponslySurveyDismissedEvent) {
        record("dismissed:\(event.surveyId)")
    }

    func surveyError(_ event: ResponslySurveyErrorEvent) {
        record("error:\(event.surveyId):\(event.code)")
    }

    func takeEvents() -> [String] {
        let taken = events
        events = []
        return taken
    }
}

/// A core wired to fakes. Storage outlives the core, so a second core simulates the next launch.
final class CoreHarness {
    static let start = Date(timeIntervalSince1970: 1_794_312_000) // 2026-11-10T12:00:00Z

    let storage = InMemoryStorage()
    let transport = FakeTransport()
    let presenter = FakePresenter()
    let scheduler = ManualScheduler()
    let main = MainStub()
    let clock = TestClock(CoreHarness.start)
    let listener = RecordingListener()
    var deviceLocale = "en-US"
    private let logLock = NSLock()
    private var logLines: [String] = []

    private(set) var core: ResponslyCore!

    init() {
        relaunch()
    }

    var logs: [String] {
        logLock.lock()
        defer { logLock.unlock() }
        return logLines
    }

    /// Creates a fresh core over the same storage, transport and presenter: the next app launch.
    func relaunch() {
        let deviceLocale = self.deviceLocale
        let environment = ResponslyCore.Environment(
            platform: "ios",
            sdkVersion: "1.0.0",
            appId: "com.acme.app",
            appVersion: "2.3.0",
            osVersion: "18.1",
            deviceLocale: { deviceLocale },
            now: { [clock] in clock.now },
            storage: storage,
            transport: transport,
            presenter: presenter,
            scheduler: scheduler,
            onMain: { [main] block in main.enqueue(block) },
            logSink: { [weak self] line in
                guard let self = self else { return }
                self.logLock.lock()
                self.logLines.append(line)
                self.logLock.unlock()
            }
        )
        core = ResponslyCore(environment: environment)
        _ = core.addListener(listener)
        scheduler.afterFire = { [weak self] in self?.settle() }
    }

    /// Lets everything that is queued (core queue, main-thread callbacks) run to completion.
    func settle() {
        for _ in 0..<12 {
            core.waitUntilIdle()
            main.drain()
        }
        core.waitUntilIdle()
    }

    /// Moves the clock and the timers forward.
    func advance(by seconds: TimeInterval) {
        // Timers asked for by calls that are still queued must exist before time moves.
        settle()
        clock.advance(by: seconds)
        scheduler.advance(by: seconds)
        settle()
    }

    func initialize(key: String = "rsk_test", logLevel: ResponslyLogLevel = .debug, apiHost: URL = ResponslyOptions.defaultAPIHost) {
        core.initialize(sdkKey: key, options: ResponslyOptions(apiHost: apiHost, logLevel: logLevel))
        settle()
    }

    /// Answers every configuration request with this body.
    func serveConfig(_ json: String, etag: String? = nil) {
        transport.respond = { request in
            if request.url?.path.hasSuffix("/sdk/v1/config") == true {
                return FakeTransport.json(json, headers: etag.map { ["ETag": $0] } ?? [:])
            }
            return FakeTransport.status(204)
        }
    }

    var persistedState: SDKState {
        StateStore(storage: storage).loadState()
    }

    var persistedTelemetry: [TelemetryEvent] {
        StateStore(storage: storage).loadTelemetry()
    }

    static func survey(
        _ id: String,
        triggers: String = "[]",
        extra: String = ""
    ) -> String {
        "{\"id\":\"\(id)\",\"name\":\"Survey \(id)\",\"url\":\"https://acme.responsly.com/f/\(id)\",\"triggers\":\(triggers)\(extra.isEmpty ? "" : "," + extra)}"
    }

    static func config(_ surveys: [String], ttl: Int = 600, settings: String = "{}") -> String {
        "{\"version\":1,\"ttl\":\(ttl),\"settings\":\(settings),\"surveys\":[\(surveys.joined(separator: ","))]}"
    }
}
