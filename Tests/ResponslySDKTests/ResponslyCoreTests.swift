import XCTest
@testable import ResponslySDK

/// The SDK's behaviour end to end, with the network, the clock, timers and the UI layer faked.
final class ResponslyCoreTests: XCTestCase {
    private var harness: CoreHarness!

    private var core: ResponslyCore { harness.core }
    private var presenter: FakePresenter { harness.presenter }
    private var transport: FakeTransport { harness.transport }

    override func setUp() {
        super.setUp()
        harness = CoreHarness()
    }

    override func tearDown() {
        XCTAssertFalse(harness.listener.calledOffMainThread, "listeners must be called on the main thread")
        harness = nil
        super.tearDown()
    }

    private let eventTrigger = #"[{"type":"event","name":"purchase"}]"#
    private let always = #""frequency":{"mode":"always"}"#

    /// A configuration with one survey, S1, triggered by the event `purchase`.
    private func serveSingleSurvey(extra: String = "") {
        let extras = [always, extra].filter { !$0.isEmpty }.joined(separator: ",")
        harness.serveConfig(CoreHarness.config([CoreHarness.survey("S1", triggers: eventTrigger, extra: extras)]))
    }

    private func events() -> [String] {
        harness.settle()
        return harness.listener.takeEvents()
    }

    // MARK: - Initialisation

    func testCallsBeforeInitializeAreRememberedAndApplied() {
        core.identify(userId: "u_123", traits: ["plan": "pro", "seats": 5])
        core.setAttributes(["seats": nil, "beta": true])
        core.track("purchase", properties: [:])
        core.track("purchase", properties: [:])
        core.setLocale("pt-BR")
        core.setHiddenFields(["order_id": "A-77"])
        harness.settle()
        // Nothing is stored or sent before the SDK key is known.
        XCTAssertNil(harness.storage.data(forKey: "responsly.state"))
        XCTAssertEqual(transport.requests.count, 0)

        serveSingleSurvey()
        harness.initialize()

        let state = harness.persistedState
        XCTAssertEqual(state.sdkKey, "rsk_test")
        XCTAssertEqual(state.userId, "u_123")
        XCTAssertEqual(state.traits, ["plan": .string("pro"), "beta": .bool(true)])
        XCTAssertEqual(state.eventCounts, ["purchase": 2])
        XCTAssertEqual(state.locale, "pt-BR")
        XCTAssertEqual(state.hiddenFields, ["order_id": "A-77"])
        // The remembered trigger calls were evaluated, in order, once the configuration arrived.
        XCTAssertEqual(presenter.presented.map { $0.surveyId }, ["S1"])
        XCTAssertEqual(events(), ["notShown:S1:another_survey_visible"])
    }

    func testShowSurveyBeforeInitializeReportsNotInitialized() {
        core.showSurvey("S1", options: ResponslyShowOptions())
        XCTAssertEqual(events(), ["notShown:S1:not_initialized"])
        // It is not remembered.
        serveSingleSurvey()
        harness.initialize()
        XCTAssertEqual(presenter.presented.count, 0)
        XCTAssertEqual(events(), [])
    }

    func testAnAPIHostWithoutHTTPSIsRefused() {
        serveSingleSurvey()
        harness.initialize(apiHost: URL(string: "http://api.responsly.com")!)
        XCTAssertEqual(transport.requests.count, 0)
        core.showSurvey("S1", options: ResponslyShowOptions())
        XCTAssertEqual(events(), ["notShown:S1:not_initialized"])

        // Plain http is fine for a local development host.
        harness.initialize(apiHost: URL(string: "http://localhost:8000")!)
        XCTAssertEqual(transport.configRequests.map { $0.url?.absoluteString }, ["http://localhost:8000/sdk/v1/config"])
    }

    func testInitializeIsIdempotentForTheSameKey() {
        serveSingleSurvey()
        harness.initialize()
        harness.initialize()
        harness.initialize()
        XCTAssertEqual(transport.configRequests.count, 1)
    }

    private let apiHostA = URL(string: "https://api-a.responsly.test")!
    private let apiHostB = URL(string: "https://api-b.responsly.test")!

    private func serveConfigsByAPIHost(_ first: String, _ second: String) {
        transport.respond = { request in
            guard request.url?.path.hasSuffix("/sdk/v1/config") == true else {
                return FakeTransport.status(204)
            }
            return FakeTransport.json(request.url?.host == self.apiHostA.host ? first : second)
        }
    }

    func testChangingAPIHostCancelsLoadingSurveyAndIgnoresLateReady() throws {
        serveConfigsByAPIHost(
            CoreHarness.config([CoreHarness.survey("SA", triggers: eventTrigger, extra: always)]),
            CoreHarness.config([])
        )
        harness.initialize(apiHost: apiHostA)
        core.identify(userId: "u_1", traits: ["plan": "pro"])
        core.track("purchase", properties: [:])
        harness.settle()
        let sessionId = try XCTUnwrap(presenter.presented.first?.sessionId)
        let before = harness.persistedState

        harness.initialize(apiHost: apiHostB)

        XCTAssertEqual(presenter.dismissed.map { $0.id }, [sessionId])
        XCTAssertEqual(presenter.dismissed.first?.animated, false)
        XCTAssertEqual(transport.configRequests.map { $0.url?.host }, [apiHostA.host, apiHostB.host])
        XCTAssertEqual(harness.persistedState, before)
        XCTAssertEqual(events(), [])
        XCTAssertEqual(harness.persistedTelemetry, [])

        presenter.sendMessage("ready")
        harness.advance(by: 30)
        XCTAssertEqual(presenter.revealed, [])
        XCTAssertEqual(events(), [])
        XCTAssertEqual(harness.persistedState, before)
        XCTAssertEqual(harness.persistedTelemetry, [])
        XCTAssertEqual(transport.eventRequests.count, 0)
    }

    func testChangingAPIHostCancelsDelayedSurvey() {
        serveConfigsByAPIHost(
            CoreHarness.config([CoreHarness.survey("SA", triggers: eventTrigger,
                                                 extra: always + #", "delay_seconds":5"#)]),
            CoreHarness.config([])
        )
        harness.initialize(apiHost: apiHostA)
        core.track("purchase", properties: [:])
        harness.settle()
        let before = harness.persistedState

        harness.initialize(apiHost: apiHostB)
        harness.advance(by: 10)

        XCTAssertEqual(presenter.presented.count, 0)
        XCTAssertEqual(presenter.dismissed.count, 0)
        XCTAssertEqual(presenter.revealed, [])
        XCTAssertEqual(events(), [])
        XCTAssertEqual(harness.persistedState, before)
        XCTAssertEqual(harness.persistedTelemetry, [])
    }

    func testChangingAPIHostCancelsSurveyWaitingForDisplayGuard() throws {
        serveConfigsByAPIHost(
            CoreHarness.config([CoreHarness.survey("SA", triggers: eventTrigger, extra: always)]),
            CoreHarness.config([])
        )
        harness.initialize(apiHost: apiHostA)
        var decide: ((Bool) -> Void)?
        core.setDisplayGuard { _, answer in decide = answer }
        core.track("purchase", properties: [:])
        harness.settle()
        let sessionId = try XCTUnwrap(presenter.presented.first?.sessionId)
        presenter.sendMessage("ready")
        harness.settle()
        let answer = try XCTUnwrap(decide)
        let before = harness.persistedState

        harness.initialize(apiHost: apiHostB)
        answer(true)
        harness.advance(by: 30)

        XCTAssertEqual(presenter.dismissed.map { $0.id }, [sessionId])
        XCTAssertEqual(presenter.dismissed.first?.animated, false)
        XCTAssertEqual(presenter.revealed, [])
        XCTAssertEqual(events(), [])
        XCTAssertEqual(harness.persistedState, before)
        XCTAssertEqual(harness.persistedTelemetry, [])
        XCTAssertEqual(transport.eventRequests.count, 0)
    }

    func testChangingAPIHostLeavesVisibleSurveyAlone() throws {
        serveConfigsByAPIHost(
            CoreHarness.config([CoreHarness.survey("SA", triggers: eventTrigger, extra: always)]),
            CoreHarness.config([])
        )
        harness.initialize(apiHost: apiHostA)
        core.track("purchase", properties: [:])
        harness.settle()
        let sessionId = try XCTUnwrap(presenter.presented.first?.sessionId)
        presenter.sendMessage("ready")
        XCTAssertEqual(events(), ["shown:SA:event:purchase"])
        let before = harness.persistedState

        harness.initialize(apiHost: apiHostB)

        XCTAssertEqual(presenter.dismissed.count, 0)
        XCTAssertEqual(presenter.revealed, [sessionId])
        XCTAssertEqual(harness.persistedState, before)
        XCTAssertEqual(events(), [])

        core.closeSurvey()
        XCTAssertEqual(events(), ["dismissed:SA"])
    }

    func testChangingAPIHostEvaluatesAppLaunchAgainstNewConfiguration() {
        serveConfigsByAPIHost(
            CoreHarness.config([]),
            CoreHarness.config([CoreHarness.survey("SB", triggers: #"[{"type":"app_launch"}]"#,
                                                 extra: always)])
        )
        harness.initialize(apiHost: apiHostA)
        core.identify(userId: "u_1", traits: ["plan": "pro"])
        harness.settle()
        let before = harness.persistedState
        XCTAssertEqual(presenter.presented.count, 0)

        harness.initialize(apiHost: apiHostB)

        XCTAssertEqual(presenter.presented.map { $0.surveyId }, ["SB"])
        XCTAssertEqual(harness.persistedState, before)
        XCTAssertEqual(events(), [])

        // Repeating the same key and host neither refetches nor repeats app_launch.
        harness.initialize(apiHost: apiHostB)
        XCTAssertEqual(transport.configRequests.map { $0.url?.host }, [apiHostA.host, apiHostB.host])
        XCTAssertEqual(presenter.presented.map { $0.surveyId }, ["SB"])

        presenter.sendMessage("ready")
        XCTAssertEqual(events(), ["shown:SB:app_launch"])
        XCTAssertEqual(harness.persistedState.surveys["SB"]?.displayCount, 1)
    }

    func testAnEmptyKeyDoesNotInitialize() {
        harness.initialize(key: "  ")
        XCTAssertEqual(transport.requests.count, 0)
        core.showSurvey("S1", options: ResponslyShowOptions())
        XCTAssertEqual(events(), ["notShown:S1:not_initialized"])
    }

    func testADifferentKeyResetsStateFirst() {
        serveSingleSurvey()
        harness.initialize(key: "rsk_one")
        core.identify(userId: "u_1", traits: ["plan": "pro"])
        core.setTrackingEnabled(false)
        core.setTrackingEnabled(true)
        core.track("purchase", properties: [:])
        harness.settle()
        let installId = harness.persistedState.installId
        XCTAssertEqual(presenter.presented.count, 1)
        _ = events()

        harness.initialize(key: "rsk_two")
        let state = harness.persistedState
        XCTAssertEqual(state.sdkKey, "rsk_two")
        XCTAssertEqual(state.installId, installId)
        XCTAssertNil(state.userId)
        XCTAssertEqual(state.traits, [:])
        XCTAssertEqual(state.eventCounts, [:])
        // The survey that was loading for the old key is gone, and the new key fetched its own configuration.
        XCTAssertEqual(presenter.dismissed.count, 1)
        XCTAssertEqual(transport.configRequests.last?.value(forHTTPHeaderField: "X-Responsly-Sdk-Key"), "rsk_two")
        XCTAssertEqual(presenter.clearedHosts, [["acme.responsly.com"]])
    }

    func testADifferentKeyOnTheNextLaunchResetsStateToo() {
        serveSingleSurvey()
        harness.initialize(key: "rsk_one")
        core.identify(userId: "u_1", traits: [:])
        core.setTrackingEnabled(false)
        harness.settle()
        let installId = harness.persistedState.installId

        harness.relaunch()
        harness.initialize(key: "rsk_two")
        let state = harness.persistedState
        XCTAssertEqual(state.sdkKey, "rsk_two")
        XCTAssertEqual(state.installId, installId)
        XCTAssertNil(state.userId)
        // The tracking setting survives a reset.
        XCTAssertFalse(state.trackingEnabled)
    }

    // MARK: - Configuration

    func testConfigRequestAndAppLaunchTrigger() throws {
        harness.serveConfig(CoreHarness.config([
            CoreHarness.survey("S1", triggers: #"[{"type":"app_launch"}]"#),
        ]))
        harness.initialize()

        let request = try XCTUnwrap(transport.configRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.responsly.com/sdk/v1/config")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Responsly-Sdk-Key"), "rsk_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Responsly-Platform"), "ios")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Responsly-Sdk-Version"), "1.0.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Responsly-App-Id"), "com.acme.app")

        // The survey loads hidden; nothing is counted or announced until the page is ready.
        let presented = try XCTUnwrap(presenter.presented.first)
        XCTAssertEqual(presented.surveyId, "S1")
        XCTAssertEqual(presented.loadURL.absoluteString, "https://acme.responsly.com/f/S1?sdk=1")
        XCTAssertEqual(presenter.revealed, [])
        XCTAssertEqual(events(), [])
        XCTAssertNil(harness.persistedState.surveys["S1"])

        presenter.sendMessage("ready", payload: ##"{"survey_id":"S1","background_color":"#ffffff"}"##)
        XCTAssertEqual(events(), ["shown:S1:app_launch"])
        XCTAssertEqual(presenter.revealed, [presented.sessionId])
        let state = harness.persistedState
        XCTAssertEqual(state.surveys["S1"]?.displayCount, 1)
        XCTAssertEqual(state.surveys["S1"]?.lastDisplayedAt, CoreHarness.start)
        XCTAssertEqual(state.lastAutoDisplayAt, CoreHarness.start)
        XCTAssertEqual(harness.persistedTelemetry, [TelemetryEvent(type: .displayed, surveyId: "S1")])
    }

    func testTriggerCallsMadeBeforeTheConfigurationAreQueuedAndEvaluatedInOrder() {
        transport.respond = nil // keep the fetch pending
        harness.initialize()
        core.track("purchase", properties: [:])
        core.screen("Checkout")
        core.track("purchase", properties: [:])
        harness.settle()
        XCTAssertEqual(presenter.presented.count, 0)
        // Counted at call time, regardless.
        XCTAssertEqual(harness.persistedState.eventCounts, ["purchase": 2])

        // S1 needs the second purchase; S2 is on the Checkout screen. In call order the screen wins.
        transport.completePending(with: FakeTransport.json(CoreHarness.config([
            CoreHarness.survey("S1", triggers: #"[{"type":"event","name":"purchase","min_count":2}]"#, extra: always),
            CoreHarness.survey("S2", triggers: #"[{"type":"screen","name":"Checkout"}]"#, extra: always),
        ])))
        XCTAssertEqual(events(), ["notShown:S1:another_survey_visible"])
        XCTAssertEqual(presenter.presented.map { $0.surveyId }, ["S2"])
    }

    func testAtMostFiftyCallsAreQueuedOldestDropped() {
        transport.respond = nil
        harness.initialize()
        // 60 calls; survey S1 fires on the 5th purchase only if that call is still queued.
        for _ in 0..<60 {
            core.track("purchase", properties: [:])
        }
        harness.settle()
        transport.completePending(with: FakeTransport.json(CoreHarness.config([
            CoreHarness.survey("S1", triggers: #"[{"type":"event","name":"purchase","min_count":5}]"#, extra: always),
        ])))
        harness.settle()
        // Calls 1–10 were dropped; call 11 (count 11 ≥ 5) selects the survey, the other 49 find it busy.
        XCTAssertEqual(presenter.presented.count, 1)
        XCTAssertEqual(events(), Array(repeating: "notShown:S1:another_survey_visible", count: 49))
    }

    func testCachedConfigurationIsUsedAtLaunchAndRefreshedOnForegroundWhenStale() throws {
        harness.serveConfig(CoreHarness.config([CoreHarness.survey("S1", triggers: #"[{"type":"app_launch"}]"#, extra: always)], ttl: 600), etag: "\"v1\"")
        harness.initialize()
        XCTAssertEqual(transport.configRequests.count, 1)
        XCTAssertNil(transport.configRequests[0].value(forHTTPHeaderField: "If-None-Match"))
        presenter.sendMessage("ready")
        presenter.send(.closedByUser)
        harness.settle()

        // Next launch, five minutes later: the cache is fresh, so no request, and `app_launch`
        // is evaluated straight from it.
        harness.clock.advance(by: 300)
        harness.relaunch()
        harness.initialize()
        XCTAssertEqual(transport.configRequests.count, 1)
        XCTAssertEqual(presenter.presented.count, 2)

        // Foreground while still fresh: nothing.
        core.applicationWillEnterForeground()
        harness.settle()
        XCTAssertEqual(transport.configRequests.count, 1)

        // Foreground with a stale cache: a conditional request.
        harness.clock.advance(by: 301)
        transport.respond = { _ in FakeTransport.status(304) }
        core.applicationWillEnterForeground()
        harness.settle()
        XCTAssertEqual(transport.configRequests.count, 2)
        XCTAssertEqual(transport.configRequests[1].value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")

        // 304 restarted the TTL: no further request until it runs out again.
        harness.clock.advance(by: 599)
        core.applicationWillEnterForeground()
        harness.settle()
        XCTAssertEqual(transport.configRequests.count, 2)
        harness.clock.advance(by: 2)
        core.applicationWillEnterForeground()
        harness.settle()
        XCTAssertEqual(transport.configRequests.count, 3)
    }

    func testTheMinimumEffectiveTTLIsSixtySeconds() {
        harness.serveConfig(CoreHarness.config([], ttl: 1))
        harness.initialize()
        harness.clock.advance(by: 59)
        core.applicationWillEnterForeground()
        harness.settle()
        XCTAssertEqual(transport.configRequests.count, 1)
        harness.clock.advance(by: 1)
        core.applicationWillEnterForeground()
        harness.settle()
        XCTAssertEqual(transport.configRequests.count, 2)
    }

    func testAFailedFetchKeepsTheCachedCopyAndRetriesOnTheNextForeground() {
        serveSingleSurvey()
        harness.initialize()
        harness.clock.advance(by: 601)
        harness.relaunch()
        transport.respond = { _ in FakeTransport.status(500) }
        harness.initialize()
        XCTAssertEqual(transport.configRequests.count, 2)

        // The cached copy still drives targeting.
        core.track("purchase", properties: [:])
        harness.settle()
        XCTAssertEqual(presenter.presented.map { $0.surveyId }, ["S1"])

        transport.respond = { _ in .failure("offline") }
        core.applicationWillEnterForeground()
        harness.settle()
        XCTAssertEqual(transport.configRequests.count, 3)
        XCTAssertNotNil(StateStore(storage: harness.storage).loadCachedConfig())
    }

    func testInvalidKeyDropsTheCacheAndStopsUntilTheNextLaunch() {
        serveSingleSurvey()
        harness.initialize()
        XCTAssertNotNil(StateStore(storage: harness.storage).loadCachedConfig())

        harness.clock.advance(by: 601)
        harness.relaunch()
        transport.respond = { _ in FakeTransport.json(#"{"error":"invalid_sdk_key"}"#, status: 401) }
        harness.initialize()
        XCTAssertEqual(transport.configRequests.count, 2)
        XCTAssertNil(StateStore(storage: harness.storage).loadCachedConfig())
        _ = events()

        // Nothing is shown and nothing is fetched again in this process.
        core.track("purchase", properties: [:])
        core.showSurvey("S1", options: ResponslyShowOptions(force: true))
        harness.clock.advance(by: 3_600)
        core.applicationWillEnterForeground()
        XCTAssertEqual(events(), ["notShown:S1:config_unavailable"])
        XCTAssertEqual(transport.configRequests.count, 2)
        XCTAssertEqual(presenter.presented.count, 0)

        // The next launch tries again.
        harness.relaunch()
        serveSingleSurvey()
        harness.initialize()
        XCTAssertEqual(transport.configRequests.count, 3)
    }

    func testShowSurveyWaitsForTheFirstConfigurationAndReportsWhenItCannotBeFetched() {
        transport.respond = nil
        harness.initialize()
        core.showSurvey("S1", options: ResponslyShowOptions())
        XCTAssertEqual(events(), [])

        transport.completePending(with: .failure("offline"))
        XCTAssertEqual(events(), ["notShown:S1:config_unavailable"])

        // No fetch in flight and no configuration: the answer is immediate.
        core.showSurvey("S1", options: ResponslyShowOptions())
        XCTAssertEqual(events(), ["notShown:S1:config_unavailable"])

        // A trigger call from the same period is still waiting and is evaluated after the retry.
        core.track("purchase", properties: [:])
        serveSingleSurvey()
        core.applicationWillEnterForeground()
        harness.settle()
        XCTAssertEqual(presenter.presented.map { $0.surveyId }, ["S1"])
    }

    func testShowSurveyIsAnsweredWhenTheFirstConfigurationArrives() {
        transport.respond = nil
        harness.initialize()
        core.showSurvey("S1", options: ResponslyShowOptions())
        core.showSurvey("nope", options: ResponslyShowOptions())
        harness.settle()
        transport.completePending(with: FakeTransport.json(CoreHarness.config([CoreHarness.survey("S1")])))
        XCTAssertEqual(events(), ["notShown:nope:survey_not_found"])
        XCTAssertEqual(presenter.presented.map { $0.surveyId }, ["S1"])
    }

    func testShowSurveyForAnIdMissingFromAStaleCacheWaitsForTheRefreshInFlight() {
        serveSingleSurvey()
        harness.initialize()
        harness.clock.advance(by: 601)
        harness.relaunch()
        transport.respond = nil // the refresh of the stale cache stays in flight
        harness.initialize()
        XCTAssertEqual(transport.configRequests.count, 2)

        // A survey the cached copy knows is answered from the cache right away…
        core.showSurvey("S1", options: ResponslyShowOptions())
        harness.settle()
        XCTAssertEqual(presenter.presented.map { $0.surveyId }, ["S1"])
        presenter.sendMessage("ready")
        presenter.send(.closedByUser)
        _ = events()

        // …one it does not know waits for the refresh.
        core.showSurvey("S2", options: ResponslyShowOptions())
        core.showSurvey("S3", options: ResponslyShowOptions())
        XCTAssertEqual(events(), [])
        transport.completePending(with: FakeTransport.json(CoreHarness.config([
            CoreHarness.survey("S1", triggers: eventTrigger), CoreHarness.survey("S2"),
        ])))
        XCTAssertEqual(events(), ["notShown:S3:survey_not_found"])
        XCTAssertEqual(presenter.presented.map { $0.surveyId }, ["S1", "S2"])
    }

    func testShowSurveyWaitingForARefreshIsAnsweredFromTheCacheWhenTheRefreshFailsOrIsNotModified() {
        serveSingleSurvey()
        harness.initialize()
        harness.clock.advance(by: 601)
        transport.respond = nil
        core.applicationWillEnterForeground()
        core.showSurvey("S2", options: ResponslyShowOptions())
        XCTAssertEqual(events(), [])
        transport.completePending(with: .failure("offline"))
        XCTAssertEqual(events(), ["notShown:S2:survey_not_found"])

        core.applicationWillEnterForeground()
        core.showSurvey("S2", options: ResponslyShowOptions())
        XCTAssertEqual(events(), [])
        transport.completePending(with: FakeTransport.status(304))
        XCTAssertEqual(events(), ["notShown:S2:survey_not_found"])
    }

    // MARK: - Targeting flow

    func testEventTriggerShowsOnceAndReportsWhy() {
        harness.serveConfig(CoreHarness.config([CoreHarness.survey("S1", triggers: eventTrigger)]))
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        XCTAssertEqual(events(), ["shown:S1:event:purchase"])

        core.track("purchase", properties: [:])
        XCTAssertEqual(events(), ["notShown:S1:another_survey_visible"])

        presenter.send(.closedByUser)
        XCTAssertEqual(events(), ["dismissed:S1"])
        core.track("purchase", properties: [:])
        XCTAssertEqual(events(), ["notShown:S1:frequency_limit"])
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testEventPropertiesIncludingDatesReachTheConditions() {
        harness.serveConfig(CoreHarness.config([
            CoreHarness.survey("S1", triggers: #"[{"type":"event","name":"purchase","conditions":[{"property":"value","op":"gte","value":100},{"property":"at","op":"gt","value":"2026-01-01T00:00:00Z"}]}]"#, extra: always),
        ]))
        harness.initialize()
        core.track("purchase", properties: ["value": 99, "at": .date(CoreHarness.start)])
        core.track("purchase", properties: ["value": 100, "at": .date(Date(timeIntervalSince1970: 0))])
        harness.settle()
        XCTAssertEqual(presenter.presented.count, 0)
        core.track("purchase", properties: ["value": "250", "at": .date(CoreHarness.start)])
        harness.settle()
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testDelayThenShow() throws {
        harness.serveConfig(CoreHarness.config([
            CoreHarness.survey("S1", triggers: #"[{"type":"screen","name":"Checkout"}]"#, extra: #""delay_seconds":5"#),
        ]))
        harness.initialize()
        core.screen("Checkout")
        harness.settle()
        XCTAssertEqual(presenter.presented.count, 0)

        // A second selection while one is waiting is not shown.
        core.screen("Checkout")
        XCTAssertEqual(events(), ["notShown:S1:another_survey_visible"])

        harness.advance(by: 4.9)
        XCTAssertEqual(presenter.presented.count, 0)
        harness.advance(by: 0.1)
        XCTAssertEqual(presenter.presented.map { $0.surveyId }, ["S1"])
        presenter.sendMessage("ready")
        XCTAssertEqual(events(), ["shown:S1:screen:Checkout"])
    }

    func testScreenChangedDuringTheDelay() {
        harness.serveConfig(CoreHarness.config([
            CoreHarness.survey("S1", triggers: #"[{"type":"screen","name":"Checkout"}]"#, extra: #""delay_seconds":5"#),
        ]))
        harness.initialize()
        core.screen("Checkout")
        core.screen("Home")
        harness.advance(by: 5)
        XCTAssertEqual(presenter.presented.count, 0)
        XCTAssertEqual(events(), ["notShown:S1:screen_changed"])

        // The slot is free again.
        core.screen("Checkout")
        harness.advance(by: 5)
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testEligibilityIsCheckedAgainWhenTheDelayEnds() {
        harness.serveConfig(CoreHarness.config([
            CoreHarness.survey("S1", triggers: eventTrigger, extra: #""delay_seconds":10,"audience":{"identified":false}"#),
        ]))
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.advance(by: 5)
        core.identify(userId: "u_1", traits: [:])
        harness.advance(by: 5)
        XCTAssertEqual(presenter.presented.count, 0)
        XCTAssertEqual(events(), ["notShown:S1:audience_mismatch"])

        core.reset()
        harness.settle()
        core.track("purchase", properties: [:])
        harness.advance(by: 5)
        core.pause()
        harness.advance(by: 5)
        XCTAssertEqual(events(), ["notShown:S1:paused"])
        XCTAssertEqual(presenter.presented.count, 0)
    }

    func testShowSurveyHasNoDelay() {
        harness.serveConfig(CoreHarness.config([CoreHarness.survey("S1", extra: #""delay_seconds":30"#)]))
        harness.initialize()
        core.showSurvey("S1", options: ResponslyShowOptions())
        harness.settle()
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testPauseStopsTargetingButNotShowSurvey() {
        serveSingleSurvey()
        harness.initialize()
        core.pause()
        core.track("purchase", properties: [:])
        XCTAssertEqual(events(), ["notShown:S1:paused"])
        core.showSurvey("S1", options: ResponslyShowOptions())
        harness.settle()
        XCTAssertEqual(presenter.presented.count, 1)
        presenter.sendMessage("ready")
        presenter.send(.closedByUser)
        _ = events()

        core.resume()
        core.track("purchase", properties: [:])
        harness.settle()
        XCTAssertEqual(presenter.presented.count, 2)
    }

    func testOnlyADisplayChosenByTargetingStartsTheGlobalCooldown() {
        harness.serveConfig(CoreHarness.config(
            [CoreHarness.survey("S1", triggers: eventTrigger, extra: always)],
            settings: #"{"global_cooldown_seconds":600}"#
        ))
        harness.initialize()
        core.showSurvey("S1", options: ResponslyShowOptions())
        harness.settle()
        presenter.sendMessage("ready")
        presenter.send(.closedByUser)
        harness.settle()
        XCTAssertNil(harness.persistedState.lastAutoDisplayAt)

        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        presenter.send(.closedByUser)
        _ = events()
        XCTAssertEqual(harness.persistedState.lastAutoDisplayAt, CoreHarness.start)

        harness.clock.advance(by: 599)
        core.track("purchase", properties: [:])
        XCTAssertEqual(events(), ["notShown:S1:global_cooldown"])
        harness.clock.advance(by: 1)
        core.track("purchase", properties: [:])
        harness.settle()
        XCTAssertEqual(presenter.presented.count, 3)
    }

    // MARK: - Display guard

    func testDisplayGuardIsAskedWhenThePageIsReadyAndCanVeto() throws {
        serveSingleSurvey()
        harness.initialize()
        var asked: [ResponslySurvey] = []
        var askedOnMainThread = true
        core.setDisplayGuard { survey, decide in
            asked.append(survey)
            askedOnMainThread = askedOnMainThread && Thread.isMainThread
            decide(false)
        }

        // The page loads first; the guard is not asked until it reports `ready`.
        core.track("purchase", properties: [:])
        harness.settle()
        let sessionId = try XCTUnwrap(presenter.presented.first?.sessionId)
        XCTAssertEqual(asked, [])
        XCTAssertEqual(events(), [])

        presenter.sendMessage("ready")
        XCTAssertEqual(events(), ["notShown:S1:vetoed"])
        XCTAssertEqual(asked, [ResponslySurvey(id: "S1", name: "Survey S1")])
        XCTAssertTrue(askedOnMainThread)
        // The loaded page is discarded and nothing was counted.
        XCTAssertEqual(presenter.dismissed.map { $0.id }, [sessionId])
        XCTAssertEqual(presenter.dismissed.first?.animated, false)
        XCTAssertEqual(presenter.revealed, [])
        XCTAssertNil(harness.persistedState.surveys["S1"])
        XCTAssertEqual(harness.persistedTelemetry, [])

        // Also asked for a `showSurvey` that is not forced…
        core.showSurvey("S1", options: ResponslyShowOptions())
        harness.settle()
        presenter.sendMessage("ready")
        XCTAssertEqual(events(), ["notShown:S1:vetoed"])
        XCTAssertEqual(asked.count, 2)

        // …but not for a forced one.
        core.showSurvey("S1", options: ResponslyShowOptions(force: true))
        harness.settle()
        presenter.sendMessage("ready")
        XCTAssertEqual(events(), ["shown:S1:manual"])
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(presenter.revealed.count, 1)
    }

    func testDisplayGuardAllowsFromAnyThread() throws {
        serveSingleSurvey()
        harness.initialize()
        let answered = expectation(description: "the guard answered")
        core.setDisplayGuard { _, decide in
            DispatchQueue.global().async {
                decide(true)
                decide(false) // only the first answer counts
                answered.fulfill()
            }
        }
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        harness.settle()
        wait(for: [answered], timeout: 2)
        XCTAssertEqual(events(), ["shown:S1:event:purchase"])
        XCTAssertEqual(presenter.revealed, [try XCTUnwrap(presenter.presented.first?.sessionId)])
        XCTAssertEqual(presenter.dismissed.count, 0)
        XCTAssertEqual(harness.persistedState.surveys["S1"]?.displayCount, 1)
    }

    func testNoAnswerFromTheDisplayGuardWithinTwoSecondsCountsAsAllow() {
        serveSingleSurvey()
        harness.initialize()
        var late: ((Bool) -> Void)?
        core.setDisplayGuard { _, decide in late = decide }
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        harness.advance(by: 1.9)
        XCTAssertNotNil(late)
        XCTAssertEqual(presenter.revealed.count, 0)
        XCTAssertEqual(events(), [])
        harness.advance(by: 0.1)
        XCTAssertEqual(presenter.revealed.count, 1)
        XCTAssertEqual(events(), ["shown:S1:event:purchase"])

        // A veto that arrives too late changes nothing.
        late?(false)
        XCTAssertEqual(events(), [])
        XCTAssertEqual(presenter.dismissed.count, 0)

        // Removing the guard.
        presenter.send(.closedByUser)
        core.setDisplayGuard(nil)
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        XCTAssertEqual(events(), ["dismissed:S1", "shown:S1:event:purchase"])
    }

    func testTheLoadTimeoutDoesNotCountTheTimeSpentWaitingForTheGuard() {
        serveSingleSurvey()
        harness.initialize()
        var decide: ((Bool) -> Void)?
        core.setDisplayGuard { _, answer in decide = answer }
        core.track("purchase", properties: [:])
        // `ready` arrives one second before the load timeout…
        harness.advance(by: 14)
        presenter.sendMessage("ready")
        harness.settle()
        XCTAssertNotNil(decide)
        // …and the guard takes its time: 15 seconds after the load started nothing has failed.
        harness.advance(by: 1.5)
        XCTAssertEqual(events(), [])
        XCTAssertEqual(presenter.dismissed.count, 0)

        decide?(true)
        XCTAssertEqual(events(), ["shown:S1:event:purchase"])
        // No timer from the loading phase is left to fire while the survey is visible.
        harness.advance(by: 20)
        XCTAssertEqual(events(), [])
        XCTAssertEqual(presenter.dismissed.count, 0)
    }

    func testThePageCanStillFailWhileTheGuardIsDeciding() {
        serveSingleSurvey()
        harness.initialize()
        var decide: ((Bool) -> Void)?
        core.setDisplayGuard { _, answer in decide = answer }

        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        presenter.sendMessage("error", payload: #"{"code":"closed","message":"This survey is closed"}"#)
        XCTAssertEqual(events(), ["notShown:S1:survey_unavailable"])
        XCTAssertEqual(presenter.dismissed.count, 1)
        // The guard's answer for the discarded page is ignored.
        decide?(true)
        XCTAssertEqual(events(), [])
        XCTAssertEqual(presenter.revealed, [])

        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        presenter.send(.loadFailed("the web content process terminated"))
        XCTAssertEqual(events(), ["notShown:S1:load_failed"])
        XCTAssertEqual(presenter.dismissed.count, 2)
        XCTAssertNil(harness.persistedState.surveys["S1"])
    }

    // MARK: - Loading

    func testNoReadyWithinFifteenSecondsIsALoadFailureThatChangesNothing() throws {
        serveSingleSurvey()
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.advance(by: 14.9)
        XCTAssertEqual(events(), [])
        harness.advance(by: 0.1)
        XCTAssertEqual(events(), ["notShown:S1:load_failed"])

        let sessionId = try XCTUnwrap(presenter.presented.first?.sessionId)
        XCTAssertEqual(presenter.dismissed.map { $0.id }, [sessionId])
        XCTAssertEqual(presenter.dismissed.first?.animated, false)
        XCTAssertEqual(presenter.revealed, [])
        XCTAssertNil(harness.persistedState.surveys["S1"])
        XCTAssertEqual(harness.persistedTelemetry, [])

        // A `ready` that arrives after the timeout is ignored.
        presenter.sendMessage("ready")
        XCTAssertEqual(events(), [])
        XCTAssertEqual(presenter.revealed, [])

        // The survey can be tried again.
        core.track("purchase", properties: [:])
        harness.settle()
        XCTAssertEqual(presenter.presented.count, 2)
    }

    func testMainFrameLoadFailure() {
        serveSingleSurvey()
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.send(.loadFailed("The Internet connection appears to be offline."))
        XCTAssertEqual(events(), ["notShown:S1:load_failed"])
        XCTAssertEqual(presenter.dismissed.count, 1)
        XCTAssertNil(harness.persistedState.surveys["S1"])
        // The timeout that was running is gone.
        harness.advance(by: 30)
        XCTAssertEqual(events(), [])
    }

    func testPageErrorBeforeReadyMeansSurveyUnavailable() {
        serveSingleSurvey()
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("error", payload: #"{"code":"closed","message":"This survey is closed"}"#)
        XCTAssertEqual(events(), ["notShown:S1:survey_unavailable"])
        XCTAssertEqual(presenter.dismissed.count, 1)
        XCTAssertEqual(presenter.revealed, [])
        XCTAssertNil(harness.persistedState.surveys["S1"])
    }

    func testPageErrorAfterReadyGoesToTheListenerAndTheSurveyStays() {
        serveSingleSurvey()
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        presenter.sendMessage("error", payload: #"{"code":"submit_failed","message":"Try again"}"#)
        XCTAssertEqual(events(), ["shown:S1:event:purchase", "error:S1:submit_failed"])
        XCTAssertEqual(presenter.dismissed.count, 0)
    }

    // MARK: - A visible survey

    func testAnswersCompletionAndAutoClose() throws {
        serveSingleSurvey()
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        let sessionId = try XCTUnwrap(presenter.presented.first?.sessionId)
        presenter.sendMessage("ready")
        presenter.sendMessage("resize", payload: #"{"height":480}"#)
        presenter.sendMessage("page_changed", payload: #"{"index":1,"count":2}"#)
        presenter.sendMessage("sparkles", payload: #"{"amount":3}"#)
        presenter.sendMessage("question_answered", payload: #"{"question_id":"q1","type":"nps","title":"How likely?","value":9}"#)
        XCTAssertEqual(events(), ["shown:S1:event:purchase", "answered:S1:q1"])
        let answer = try XCTUnwrap(harness.listener.answers.first)
        XCTAssertEqual(answer.type, "nps")
        XCTAssertEqual(answer.title, "How likely?")
        XCTAssertEqual(answer.value as? NSNumber, 9)
        XCTAssertEqual(presenter.userCloseEnabled, [])

        harness.clock.advance(by: 20)
        presenter.sendMessage("completed", payload: #"{"response_id":"r_1","answers":[{"question_id":"q1","type":"nps","title":"How likely?","value":9},{"question_id":"q2","type":"multiple_choice","title":"Why?","value":["price"]}]}"#)
        XCTAssertEqual(events(), ["completed:S1:r_1"])
        let completion = try XCTUnwrap(harness.listener.completions.first)
        XCTAssertEqual(completion.answers.map { $0.questionId }, ["q1", "q2"])
        XCTAssertEqual(completion.answers.map { $0.type }, ["nps", "multiple_choice"])
        XCTAssertEqual(harness.persistedState.surveys["S1"]?.completedAt, CoreHarness.start.addingTimeInterval(20))
        XCTAssertEqual(harness.persistedTelemetry.map { $0.type }, [.displayed, .completed])
        // From `completed` on the user can always close it…
        XCTAssertEqual(presenter.userCloseEnabled, [sessionId])
        XCTAssertEqual(presenter.dismissed.count, 0)

        // …and it closes by itself after `auto_close_seconds` (3 by default), not as a dismissal.
        harness.advance(by: 2.9)
        XCTAssertEqual(presenter.dismissed.count, 0)
        harness.advance(by: 0.1)
        XCTAssertEqual(presenter.dismissed.map { $0.id }, [sessionId])
        XCTAssertEqual(presenter.dismissed.first?.animated, true)
        XCTAssertEqual(events(), [])
        XCTAssertEqual(harness.persistedState.surveys["S1"]?.dismissedCount, 0)
        XCTAssertEqual(harness.persistedTelemetry.map { $0.type }, [.displayed, .completed])

        // A second `completed` or anything else from the closed page is ignored.
        presenter.sendMessage("completed", payload: #"{"response_id":"r_2"}"#)
        XCTAssertEqual(events(), [])
    }

    func testAutoCloseSecondsFromTheConfiguration() {
        serveSingleSurvey(extra: #""presentation":{"auto_close_seconds":10}"#)
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        presenter.sendMessage("completed", payload: #"{"response_id":"r_1"}"#)
        harness.advance(by: 9.9)
        XCTAssertEqual(presenter.dismissed.count, 0)
        harness.advance(by: 0.1)
        XCTAssertEqual(presenter.dismissed.count, 1)
    }

    func testAutoCloseZeroKeepsTheSurveyUntilItIsClosed() {
        serveSingleSurvey(extra: #""presentation":{"auto_close_seconds":0,"dismissible":false}"#)
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        presenter.sendMessage("completed", payload: #"{"response_id":"r_1"}"#)
        harness.advance(by: 3_600)
        XCTAssertEqual(presenter.dismissed.count, 0)
        // The close button is offered all the same.
        XCTAssertEqual(presenter.userCloseEnabled.count, 1)

        presenter.send(.closedByUser)
        XCTAssertEqual(events(), ["shown:S1:event:purchase", "completed:S1:r_1"])
        XCTAssertEqual(harness.persistedState.surveys["S1"]?.dismissedCount, 0)

        // The slot is free.
        core.track("purchase", properties: [:])
        harness.settle()
        XCTAssertEqual(presenter.presented.count, 2)
    }

    func testCloseRequestedClosesEarlierThanTheAutoClose() {
        serveSingleSurvey()
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        presenter.sendMessage("completed", payload: #"{"response_id":"r_1"}"#)
        harness.advance(by: 1)
        presenter.sendMessage("close_requested", payload: #"{"reason":"completed"}"#)
        harness.settle()
        XCTAssertEqual(presenter.dismissed.count, 1)
        // The auto-close timer is gone with the survey.
        harness.advance(by: 10)
        XCTAssertEqual(presenter.dismissed.count, 1)
        XCTAssertEqual(events(), ["shown:S1:event:purchase", "completed:S1:r_1"])
    }

    func testNavigationAwayClosesOnlyACompletedSurvey() {
        serveSingleSurvey(extra: #""presentation":{"auto_close_seconds":0}"#)
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        presenter.send(.navigatedAway(URL(string: "https://example.com/privacy")!))
        harness.settle()
        XCTAssertEqual(presenter.dismissed.count, 0)

        presenter.sendMessage("completed", payload: #"{"response_id":"r_1"}"#)
        presenter.send(.navigatedAway(URL(string: "https://example.com/thanks")!))
        harness.settle()
        XCTAssertEqual(presenter.dismissed.count, 1)
        XCTAssertEqual(events(), ["shown:S1:event:purchase", "completed:S1:r_1"])
    }

    func testClosingBeforeCompletionCountsAsDismissed() {
        serveSingleSurvey()
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        presenter.send(.closedByUser)
        XCTAssertEqual(events(), ["shown:S1:event:purchase", "dismissed:S1"])
        XCTAssertEqual(harness.persistedState.surveys["S1"]?.dismissedCount, 1)
        XCTAssertNil(harness.persistedState.surveys["S1"]?.completedAt)
        XCTAssertEqual(harness.persistedTelemetry.map { $0.type }, [.displayed, .dismissed])
        // The container closed itself; the core does not ask for it again.
        XCTAssertEqual(presenter.dismissed.count, 0)
    }

    func testCloseRequestedByThePageBeforeCompletionIsADismissal() {
        serveSingleSurvey()
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        presenter.sendMessage("close_requested", payload: #"{"reason":"user"}"#)
        XCTAssertEqual(events(), ["shown:S1:event:purchase", "dismissed:S1"])
        XCTAssertEqual(presenter.dismissed.count, 1)
        XCTAssertEqual(presenter.dismissed.first?.animated, true)
    }

    func testCloseSurveyClosesAVisibleSurvey() {
        serveSingleSurvey()
        harness.initialize()
        core.closeSurvey() // nothing to close
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        core.closeSurvey()
        XCTAssertEqual(events(), ["shown:S1:event:purchase", "dismissed:S1"])
        XCTAssertEqual(presenter.dismissed.count, 1)
        XCTAssertEqual(harness.persistedState.surveys["S1"]?.dismissedCount, 1)
    }

    func testCloseSurveyCancelsASurveyThatIsNotVisibleYetSilently() {
        serveSingleSurvey(extra: #""delay_seconds":5"#)
        harness.initialize()
        var decide: ((Bool) -> Void)?
        core.setDisplayGuard { _, answer in decide = answer }

        // Waiting for its delay.
        core.track("purchase", properties: [:])
        harness.settle()
        core.closeSurvey()
        XCTAssertEqual(events(), [])
        harness.advance(by: 10)
        XCTAssertEqual(presenter.presented.count, 0)

        // Loading.
        core.track("purchase", properties: [:])
        harness.advance(by: 5)
        XCTAssertEqual(presenter.presented.count, 1)
        core.closeSurvey()
        XCTAssertEqual(events(), [])
        XCTAssertEqual(presenter.dismissed.count, 1)
        XCTAssertEqual(presenter.dismissed.first?.animated, false)
        // The page it was loading reports `ready` too late; the load timeout is gone as well.
        presenter.sendMessage("ready")
        harness.advance(by: 30)
        XCTAssertEqual(events(), [])

        // Waiting for the display guard.
        core.track("purchase", properties: [:])
        harness.advance(by: 5)
        presenter.sendMessage("ready")
        harness.settle()
        XCTAssertNotNil(decide)
        core.closeSurvey()
        XCTAssertEqual(events(), [])
        XCTAssertEqual(presenter.dismissed.count, 2)
        decide?(true)
        harness.advance(by: 5)
        XCTAssertEqual(events(), [])

        // It was never shown: no callback, no state change, no telemetry.
        XCTAssertEqual(presenter.revealed, [])
        XCTAssertNil(harness.persistedState.surveys["S1"])
        XCTAssertEqual(harness.persistedTelemetry, [])

        // And the slot is free.
        core.setDisplayGuard(nil)
        core.track("purchase", properties: [:])
        harness.advance(by: 5)
        presenter.sendMessage("ready")
        XCTAssertEqual(events(), ["shown:S1:event:purchase"])
    }

    func testResetAndDisablingTrackingCancelASurveyThatIsNotVisibleYetSilently() {
        serveSingleSurvey()
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        XCTAssertEqual(presenter.presented.count, 1)
        core.reset()
        XCTAssertEqual(events(), [])
        XCTAssertEqual(presenter.dismissed.count, 1)

        core.track("purchase", properties: [:])
        harness.settle()
        XCTAssertEqual(presenter.presented.count, 2)
        core.setTrackingEnabled(false)
        XCTAssertEqual(events(), [])
        XCTAssertEqual(presenter.dismissed.count, 2)
        XCTAssertEqual(presenter.dismissed.map { $0.animated }, [false, false])

        XCTAssertNil(harness.persistedState.surveys["S1"])
        XCTAssertEqual(harness.persistedTelemetry, [])
        XCTAssertEqual(presenter.revealed, [])
    }

    func testAFailureAfterTheSurveyIsVisibleReportsAnErrorAndCloses() {
        serveSingleSurvey()
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        presenter.send(.loadFailed("the web content process terminated"))
        XCTAssertEqual(events(), ["shown:S1:event:purchase", "error:S1:load_failed", "dismissed:S1"])
        XCTAssertEqual(presenter.dismissed.count, 1)
    }

    // MARK: - What the page receives

    func testThePageGetsTheContextAndOnlySdkAndLangInTheURL() throws {
        harness.serveConfig(CoreHarness.config([
            CoreHarness.survey("S1", triggers: eventTrigger, extra: #""presentation":{"style":"dialog","size":"large","dismissible":false}"#),
        ]))
        harness.initialize()
        core.identify(userId: "u_123", traits: ["plan": "pro", "seats": 5, "beta": true])
        core.setHiddenFields(["order_id": "A-77", "campaign": "spring"])
        core.track("purchase", properties: ["value": 49.9])
        harness.settle()

        let request = try XCTUnwrap(presenter.presented.first)
        XCTAssertEqual(request.loadURL.absoluteString, "https://acme.responsly.com/f/S1?sdk=1")
        XCTAssertEqual(request.surveyURL.absoluteString, "https://acme.responsly.com/f/S1")
        XCTAssertEqual(request.style, .dialog)
        XCTAssertEqual(request.size, .large)
        XCTAssertFalse(request.dismissible)
        XCTAssertEqual(request.userAgentSuffix, " ResponslySDK/1.0.0 (ios)")

        let context = try contextObject(in: request.contextScript)
        let expected: [String: Any] = [
            "v": 1,
            "platform": "ios",
            "sdk_version": "1.0.0",
            "app_id": "com.acme.app",
            "app_version": "2.3.0",
            "os_version": "18.1",
            "locale": "en-US",
            "survey_id": "S1",
            "trigger": ["type": "event", "name": "purchase"],
            "presentation": ["style": "dialog", "dismissible": false],
            "user": ["id": "u_123", "traits": ["plan": "pro", "seats": 5, "beta": true]],
            "hidden": ["order_id": "A-77", "campaign": "spring"],
        ]
        XCTAssertEqual(context as NSDictionary, expected as NSDictionary)
        XCTAssertTrue(request.contextScript.contains("window.location.origin !== [\"https:\\/\\/acme.responsly.com\"][0]"))
    }

    func testShowOptionsOverrideLocaleHiddenFieldsAndStyle() throws {
        harness.serveConfig(CoreHarness.config([CoreHarness.survey("S1")]))
        harness.initialize()
        core.setHiddenFields(["order_id": "A-77", "campaign": "spring"])
        core.showSurvey("S1", options: ResponslyShowOptions(
            hiddenFields: ["order_id": "B-1", "step": "2"], locale: "pl", presentation: .fullscreen
        ))
        harness.settle()

        let request = try XCTUnwrap(presenter.presented.first)
        XCTAssertEqual(request.loadURL.absoluteString, "https://acme.responsly.com/f/S1?sdk=1&lang=pl")
        XCTAssertEqual(request.style, .fullscreen)
        XCTAssertEqual(request.size, .medium)
        let context = try contextObject(in: request.contextScript)
        XCTAssertEqual(context["locale"] as? String, "pl")
        XCTAssertEqual(context["trigger"] as? [String: String], ["type": "manual"])
        XCTAssertEqual(context["hidden"] as? [String: String], ["order_id": "B-1", "campaign": "spring", "step": "2"])
        XCTAssertEqual((context["presentation"] as? [String: Any])?["style"] as? String, "fullscreen")
        XCTAssertTrue(context["user"] is NSNull)

        presenter.sendMessage("ready")
        XCTAssertEqual(events(), ["shown:S1:manual"])
    }

    func testSetLocaleAddsLangAndDrivesLocaleTargeting() throws {
        harness.serveConfig(CoreHarness.config([
            CoreHarness.survey("S1", triggers: eventTrigger, extra: always + #","audience":{"locales":["pt"]}"#),
        ]))
        harness.initialize()
        core.track("purchase", properties: [:])
        XCTAssertEqual(events(), ["notShown:S1:locale_mismatch"])

        core.setLocale("pt_BR")
        core.track("purchase", properties: [:])
        harness.settle()
        let request = try XCTUnwrap(presenter.presented.first)
        XCTAssertEqual(request.loadURL.absoluteString, "https://acme.responsly.com/f/S1?sdk=1&lang=pt_BR")
        XCTAssertEqual(try contextObject(in: request.contextScript)["locale"] as? String, "pt_BR")

        presenter.sendMessage("ready")
        presenter.send(.closedByUser)
        core.setLocale(nil)
        core.track("purchase", properties: [:])
        XCTAssertEqual(events().last, "notShown:S1:locale_mismatch")
    }

    func testAnAnonymousSurveyGetsNoUserAndNoHiddenFields() throws {
        harness.serveConfig(CoreHarness.config([CoreHarness.survey("S1", extra: #""anonymous":true"#)]))
        harness.initialize()
        core.identify(userId: "u_123", traits: ["plan": "pro"])
        core.setHiddenFields(["order_id": "A-77"])
        core.showSurvey("S1", options: ResponslyShowOptions(hiddenFields: ["step": "2"]))
        harness.settle()

        let request = try XCTUnwrap(presenter.presented.first)
        let context = try contextObject(in: request.contextScript)
        XCTAssertTrue(context["user"] is NSNull)
        XCTAssertEqual(context["hidden"] as? [String: String], [:])
        XCTAssertFalse(request.contextScript.contains("u_123"))
        XCTAssertFalse(request.contextScript.contains("A-77"))
        XCTAssertFalse(request.loadURL.absoluteString.contains("u_123"))
    }

    /// Pulls the object literal out of the document-start script.
    private func contextObject(in script: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let marker = "window.__RESPONSLY_SDK__ = "
        let start = try XCTUnwrap(script.range(of: marker), file: file, line: line).upperBound
        let end = try XCTUnwrap(script.range(of: ";\n", range: start..<script.endIndex), file: file, line: line).lowerBound
        let json = try JSONSerialization.jsonObject(with: Data(script[start..<end].utf8))
        return try XCTUnwrap(json as? [String: Any], file: file, line: line)
    }

    // MARK: - Tracking, reset, listeners

    func testDisabledTrackingMeansNoNetworkNoTargetingNothingShown() {
        core.setTrackingEnabled(false)
        serveSingleSurvey()
        harness.initialize()
        XCTAssertEqual(transport.requests.count, 0)
        XCTAssertFalse(harness.persistedState.trackingEnabled)

        core.track("purchase", properties: [:])
        core.showSurvey("S1", options: ResponslyShowOptions(force: true))
        core.applicationWillEnterForeground()
        XCTAssertEqual(events(), ["notShown:S1:disabled"])
        XCTAssertEqual(transport.requests.count, 0)
        XCTAssertEqual(presenter.presented.count, 0)

        // The setting is persisted; enabling it brings the network back.
        harness.relaunch()
        harness.initialize()
        XCTAssertEqual(transport.requests.count, 0)
        core.setTrackingEnabled(true)
        harness.settle()
        XCTAssertEqual(transport.configRequests.count, 1)
        core.track("purchase", properties: [:])
        harness.settle()
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testDisablingTrackingWithACachedConfigurationReportsDisabledAndClosesTheSurvey() {
        serveSingleSurvey()
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        _ = events()

        core.setTrackingEnabled(false)
        XCTAssertEqual(events(), ["dismissed:S1"])
        XCTAssertEqual(presenter.dismissed.count, 1)

        core.track("purchase", properties: [:])
        XCTAssertEqual(events(), ["notShown:S1:disabled"])
        // The telemetry that is waiting is not sent while tracking is disabled.
        harness.advance(by: 120)
        var flushed = false
        core.applicationDidEnterBackground { flushed = true }
        harness.settle()
        XCTAssertTrue(flushed)
        XCTAssertEqual(transport.eventRequests.count, 0)
    }

    func testResetClearsEverythingButTheInstallIdAndTheTrackingSetting() {
        serveSingleSurvey()
        harness.initialize()
        core.identify(userId: "u_123", traits: ["plan": "pro"])
        core.setLocale("pl")
        core.setHiddenFields(["order_id": "A-77"])
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        harness.settle()
        let before = harness.persistedState
        XCTAssertEqual(before.userId, "u_123")
        XCTAssertEqual(transport.configRequests.count, 1)
        _ = events()

        core.reset()
        XCTAssertEqual(events(), ["dismissed:S1"])
        let after = harness.persistedState
        var expected = SDKState(installId: before.installId)
        expected.sdkKey = "rsk_test"
        XCTAssertEqual(after, expected)
        XCTAssertEqual(harness.persistedTelemetry, [])
        XCTAssertEqual(presenter.dismissed.count, 1)
        XCTAssertEqual(presenter.clearedHosts, [["acme.responsly.com"]])

        // Still initialised: the configuration is fetched again and targeting works.
        XCTAssertEqual(transport.configRequests.count, 2)
        core.track("purchase", properties: [:])
        harness.settle()
        XCTAssertEqual(presenter.presented.count, 2)
    }

    func testListenersCanBeRemoved() {
        serveSingleSurvey()
        harness.initialize()
        let second = RecordingListener()
        let token = core.addListener(second)
        core.pause()
        core.track("purchase", properties: [:])
        harness.settle()
        XCTAssertEqual(second.events, ["notShown:S1:paused"])

        core.removeListener(token)
        core.track("purchase", properties: [:])
        harness.settle()
        XCTAssertEqual(second.events, ["notShown:S1:paused"])
        XCTAssertEqual(harness.listener.events.count, 2)
    }

    func testAttributesDriveAudienceTargeting() {
        harness.serveConfig(CoreHarness.config([
            CoreHarness.survey("S1", triggers: eventTrigger, extra: always + #","audience":{"identified":true,"conditions":[{"attribute":"plan","op":"eq","value":"pro"}]}"#),
        ]))
        harness.initialize()
        core.track("purchase", properties: [:])
        XCTAssertEqual(events(), ["notShown:S1:audience_mismatch"])
        core.identify(userId: "u_1", traits: ["plan": "free"])
        core.track("purchase", properties: [:])
        XCTAssertEqual(events(), ["notShown:S1:audience_mismatch"])
        core.setAttributes(["plan": "PRO"])
        core.track("purchase", properties: [:])
        harness.settle()
        XCTAssertEqual(presenter.presented.count, 1)
    }

    // MARK: - Telemetry

    func testTelemetryIsFlushedOnBackground() throws {
        serveSingleSurvey()
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        presenter.send(.closedByUser)
        harness.settle()
        XCTAssertEqual(transport.eventRequests.count, 0)

        var flushed = false
        core.applicationDidEnterBackground { flushed = true }
        harness.settle()
        XCTAssertTrue(flushed)
        let request = try XCTUnwrap(transport.eventRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self),
            #"{"events":[{"survey_id":"S1","type":"displayed"},{"survey_id":"S1","type":"dismissed"}]}"#
        )
        XCTAssertEqual(harness.persistedTelemetry, [])
    }

    func testTelemetryIsFlushedAfterThirtySeconds() {
        serveSingleSurvey()
        harness.initialize()
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        harness.advance(by: 29)
        XCTAssertEqual(transport.eventRequests.count, 0)
        harness.advance(by: 1)
        XCTAssertEqual(transport.eventRequests.count, 1)
    }

    // MARK: - Logging

    func testDebugLoggingCoversDecisionsFetchesAndBridgeMessages() {
        serveSingleSurvey()
        harness.initialize(logLevel: .debug)
        core.pause()
        core.track("purchase", properties: [:])
        core.resume()
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        harness.settle()

        let logs = harness.logs
        XCTAssertTrue(logs.allSatisfy { $0.hasPrefix("[Responsly] ") })
        XCTAssertTrue(logs.contains { $0.contains("config: fetching") })
        XCTAssertTrue(logs.contains { $0.contains("config: 200") })
        XCTAssertTrue(logs.contains { $0.contains("survey S1 not shown: paused") })
        XCTAssertTrue(logs.contains { $0.contains("survey S1 selected by event \"purchase\"") })
        XCTAssertTrue(logs.contains { $0.hasSuffix("bridge: ready") })
    }

    func testBridgeMessagesAreLoggedWithoutTheAnswers() {
        serveSingleSurvey()
        harness.initialize(logLevel: .debug)
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        presenter.sendMessage("question_answered", payload: #"{"question_id":"q1","type":"text","value":"my secret answer"}"#)
        harness.settle()

        XCTAssertTrue(harness.logs.contains { $0.hasSuffix("bridge: question_answered") })
        XCTAssertFalse(harness.logs.contains { $0.contains("my secret answer") })
    }

    func testErrorLevelIsQuietInNormalOperation() {
        serveSingleSurvey()
        harness.initialize(logLevel: .error)
        core.track("purchase", properties: [:])
        harness.settle()
        presenter.sendMessage("ready")
        harness.settle()
        XCTAssertEqual(harness.logs, [])
    }
}
