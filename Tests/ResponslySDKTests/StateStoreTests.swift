import XCTest
@testable import ResponslySDK

final class StateStoreTests: XCTestCase {
    func testInstallIdIsALowerCaseUUIDv4CreatedOnce() throws {
        let storage = InMemoryStorage()
        let first = StateStore(storage: storage).loadState()
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        XCTAssertNotNil(first.installId.range(of: pattern, options: .regularExpression), first.installId)

        // The same id on every later load, also from a new store over the same storage.
        XCTAssertEqual(StateStore(storage: storage).loadState().installId, first.installId)
        XCTAssertNotEqual(StateStore(storage: InMemoryStorage()).loadState().installId, first.installId)
    }

    func testDefaults() {
        let state = StateStore(storage: InMemoryStorage()).loadState()
        XCTAssertNil(state.sdkKey)
        XCTAssertNil(state.userId)
        XCTAssertEqual(state.traits, [:])
        XCTAssertNil(state.locale)
        XCTAssertEqual(state.hiddenFields, [:])
        XCTAssertTrue(state.trackingEnabled)
        XCTAssertEqual(state.eventCounts, [:])
        XCTAssertEqual(state.surveys, [:])
        XCTAssertNil(state.lastAutoDisplayAt)
    }

    private func populatedState(installId: String = "install-a") -> SDKState {
        let now = Date(timeIntervalSince1970: 1_794_312_000.25)
        var state = SDKState(installId: installId)
        state.sdkKey = "rsk_test"
        state.identify(userId: "u_123", traits: [
            "plan": .string("pro"),
            "seats": .number(5),
            "ratio": .number(0.25),
            "beta": .bool(true),
            "one": .number(1),
            "signed_up": StoredValue(.date(now)),
        ])
        state.locale = "pt-BR"
        state.hiddenFields = ["order_id": "A-77"]
        state.trackingEnabled = false
        state.incrementEventCount("purchase")
        state.incrementEventCount("purchase")
        state.recordDisplayed(surveyId: "S1", auto: true, at: now)
        state.recordDismissed(surveyId: "S1")
        state.recordDisplayed(surveyId: "S2", auto: false, at: now.addingTimeInterval(60))
        state.recordCompleted(surveyId: "S2", at: now.addingTimeInterval(120))
        return state
    }

    func testStateRoundTrip() {
        let storage = InMemoryStorage()
        let state = populatedState()
        StateStore(storage: storage).saveState(state)
        let loaded = StateStore(storage: storage).loadState()

        XCTAssertEqual(loaded, state)
        // Value types survive: a boolean stays a boolean, 1 stays a number.
        XCTAssertEqual(loaded.traits["beta"], .bool(true))
        XCTAssertEqual(loaded.traits["one"], .number(1))
        XCTAssertEqual(loaded.traits["signed_up"], .string("2026-11-10T12:00:00Z"))
        XCTAssertEqual(loaded.eventCounts, ["purchase": 2])
        XCTAssertEqual(loaded.surveys["S1"]?.displayCount, 1)
        XCTAssertEqual(loaded.surveys["S1"]?.dismissedCount, 1)
        XCTAssertNil(loaded.surveys["S1"]?.completedAt)
        XCTAssertNotNil(loaded.surveys["S2"]?.completedAt)
        // Only a display chosen by targeting moves the cooldown clock.
        XCTAssertEqual(loaded.lastAutoDisplayAt, Date(timeIntervalSince1970: 1_794_312_000.25))
    }

    func testStateIsStoredWithTheProtocolFieldNames() throws {
        let storage = InMemoryStorage()
        StateStore(storage: storage).saveState(populatedState())
        let data = try XCTUnwrap(storage.data(forKey: "responsly.state"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), [
            "sdk_key", "install_id", "user_id", "traits", "locale", "hidden_fields", "tracking_enabled",
            "event_counts", "surveys", "last_auto_display_at",
        ])
        let survey = try XCTUnwrap((json["surveys"] as? [String: Any])?["S2"] as? [String: Any])
        XCTAssertEqual(Set(survey.keys), ["display_count", "last_displayed_at", "completed_at", "dismissed_count"])
    }

    func testPersistenceInUserDefaults() {
        let suite = "com.responsly.sdk.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let state = populatedState()
        StateStore(storage: UserDefaultsStorage(suiteName: suite)).saveState(state)
        // A new storage object reads what the first one wrote.
        XCTAssertEqual(StateStore(storage: UserDefaultsStorage(suiteName: suite)).loadState(), state)

        let storage = UserDefaultsStorage(suiteName: suite)
        storage.setData(nil, forKey: "responsly.state")
        XCTAssertNil(storage.data(forKey: "responsly.state"))
    }

    func testUnreadableStateIsReplacedByAFreshOne() {
        let storage = InMemoryStorage()
        storage.setData(Data("not json".utf8), forKey: "responsly.state")
        let state = StateStore(storage: storage).loadState()
        XCTAssertFalse(state.installId.isEmpty)
        XCTAssertEqual(StateStore(storage: storage).loadState(), state)
    }

    func testOlderStateWithoutNewerFieldsStillLoads() throws {
        let storage = InMemoryStorage()
        storage.setData(Data(#"{"install_id":"abc","unknown_field":1}"#.utf8), forKey: "responsly.state")
        let state = StateStore(storage: storage).loadState()
        XCTAssertEqual(state.installId, "abc")
        XCTAssertTrue(state.trackingEnabled)
        XCTAssertEqual(state.eventCounts, [:])
    }

    func testResetKeepsInstallIdTrackingSettingAndKey() {
        var state = populatedState()
        state.reset()

        var expected = SDKState(installId: "install-a")
        expected.sdkKey = "rsk_test"
        expected.trackingEnabled = false
        XCTAssertEqual(state, expected)
    }

    func testTraitMergeAndRemoval() {
        var state = SDKState(installId: "i")
        state.mergeTraits(["a": .string("1"), "b": .number(2)])
        state.mergeTraits(["a": nil, "c": .bool(false), "missing": nil])
        XCTAssertEqual(state.traits, ["b": .number(2), "c": .bool(false)])
        XCTAssertNil(state.userId)

        state.identify(userId: "u1", traits: ["b": .number(3)])
        XCTAssertEqual(state.userId, "u1")
        XCTAssertEqual(state.traits, ["b": .number(3), "c": .bool(false)])
    }

    func testCachedConfigRoundTrip() throws {
        let storage = InMemoryStorage()
        let store = StateStore(storage: storage)
        XCTAssertNil(store.loadCachedConfig())

        let body = Data(#"{"ttl":120,"future":1,"surveys":[{"id":"S1","url":"https://x.test/s"}]}"#.utf8)
        let fetchedAt = Date(timeIntervalSince1970: 1_794_312_000)
        store.saveCachedConfig(CachedConfig(
            body: body, etag: "\"v1\"", fetchedAt: fetchedAt, apiHost: "https://api.responsly.com",
            config: try XCTUnwrap(SDKConfig.parse(body))
        ))

        let loaded = try XCTUnwrap(StateStore(storage: storage).loadCachedConfig())
        XCTAssertEqual(loaded.body, body)
        XCTAssertEqual(loaded.etag, "\"v1\"")
        XCTAssertEqual(loaded.fetchedAt, fetchedAt)
        XCTAssertEqual(loaded.apiHost, "https://api.responsly.com")
        XCTAssertEqual(loaded.config.ttl, 120)
        XCTAssertEqual(loaded.config.surveys.map { $0.id }, ["S1"])

        store.touchCachedConfig(fetchedAt: fetchedAt.addingTimeInterval(500))
        XCTAssertEqual(store.loadCachedConfig()?.fetchedAt, fetchedAt.addingTimeInterval(500))
        XCTAssertEqual(store.loadCachedConfig()?.etag, "\"v1\"")

        store.clearCachedConfig()
        XCTAssertNil(store.loadCachedConfig())
    }

    func testTelemetryQueueIsPersisted() {
        let storage = InMemoryStorage()
        let events = [
            TelemetryEvent(type: .displayed, surveyId: "S1"),
            TelemetryEvent(type: .completed, surveyId: "S1"),
        ]
        StateStore(storage: storage).saveTelemetry(events)
        XCTAssertEqual(StateStore(storage: storage).loadTelemetry(), events)
        StateStore(storage: storage).saveTelemetry([])
        XCTAssertEqual(StateStore(storage: storage).loadTelemetry(), [])
        XCTAssertNil(storage.data(forKey: "responsly.telemetry"))
    }
}
