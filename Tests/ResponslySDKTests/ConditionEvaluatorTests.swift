import XCTest
@testable import ResponslySDK

final class ConditionEvaluatorTests: XCTestCase {
    private func check(_ op: ConditionOperator, _ actual: StoredValue?, _ expected: StoredValue?) -> Bool {
        var values: [String: StoredValue] = [:]
        values["x"] = actual
        return ConditionEvaluator.evaluate(Condition(name: "x", op: op, value: expected), against: values)
    }

    // MARK: - Presence

    func testExistsAndNotExists() {
        XCTAssertTrue(check(.exists, .string(""), nil))
        XCTAssertTrue(check(.exists, .bool(false), nil))
        XCTAssertFalse(check(.exists, nil, nil))
        XCTAssertTrue(check(.notExists, nil, nil))
        XCTAssertFalse(check(.notExists, .number(0), nil))
    }

    func testUnknownOperatorAndMalformedConditionAreFalse() {
        XCTAssertFalse(check(.unknown, .number(5), .number(5)))
        let nameless = Condition(name: nil, op: .notExists)
        XCTAssertFalse(ConditionEvaluator.evaluate(nameless, against: [:]))
        let parsed = Condition(json: ["attribute": "x", "op": "regex", "value": ".*"], nameKeys: ["attribute"])
        XCTAssertEqual(parsed.op, .unknown)
        XCTAssertFalse(ConditionEvaluator.evaluate(parsed, against: ["x": .string("abc")]))
    }

    // MARK: - Equality

    func testEqualityOfNumbersAndBooleans() {
        XCTAssertTrue(check(.eq, .number(5), .number(5.0)))
        XCTAssertFalse(check(.eq, .number(5), .number(5.1)))
        XCTAssertTrue(check(.eq, .bool(true), .bool(true)))
        XCTAssertFalse(check(.eq, .bool(true), .bool(false)))
    }

    func testEqualityFallsBackToCaseInsensitiveText() {
        XCTAssertTrue(check(.eq, .string("pro"), .string("PRO")))
        XCTAssertTrue(check(.eq, .number(5), .string("5")))
        XCTAssertTrue(check(.eq, .string("5"), .number(5)))
        XCTAssertTrue(check(.eq, .number(5.5), .string("5.5")))
        XCTAssertTrue(check(.eq, .bool(true), .string("TRUE")))
        XCTAssertTrue(check(.eq, .string("False"), .bool(false)))
        // A boolean and a number are compared as text: "true" is not "1".
        XCTAssertFalse(check(.eq, .bool(true), .number(1)))
        // Text comparison is not numeric: "5.0" is not "5".
        XCTAssertFalse(check(.eq, .string("5.0"), .number(5)))
        XCTAssertTrue(check(.eq, .string("ZOË"), .string("zoë")))
    }

    func testEqualityWithAbsentSide() {
        XCTAssertFalse(check(.eq, nil, .string("x")))
        XCTAssertFalse(check(.eq, .string("x"), nil))
        XCTAssertTrue(check(.neq, nil, .string("x")))
        XCTAssertTrue(check(.neq, .string("y"), .string("x")))
        XCTAssertFalse(check(.neq, .string("X"), .string("x")))
        XCTAssertTrue(check(.neq, .bool(true), .bool(false)))
    }

    // MARK: - Contains

    func testContainsIsCaseInsensitiveText() {
        XCTAssertTrue(check(.contains, .string("Zoë"), .string("zo")))
        XCTAssertTrue(check(.contains, .string("Poland"), .string("LAND")))
        XCTAssertFalse(check(.contains, .string("Poland"), .string("lands")))
        XCTAssertTrue(check(.contains, .number(12345), .number(234)))
        XCTAssertTrue(check(.contains, .bool(true), .string("ru")))
        XCTAssertTrue(check(.contains, .string("abc"), .string("")))
        XCTAssertFalse(check(.contains, nil, .string("x")))
    }

    func testNotContains() {
        XCTAssertTrue(check(.notContains, nil, .string("x")))
        XCTAssertTrue(check(.notContains, .string("abc"), .string("x")))
        XCTAssertFalse(check(.notContains, .string("abc"), .string("B")))
    }

    // MARK: - Ordering

    func testOrderingOfNumbers() {
        XCTAssertTrue(check(.gt, .number(6), .number(5)))
        XCTAssertFalse(check(.gt, .number(5), .number(5)))
        XCTAssertTrue(check(.gte, .number(5), .number(5)))
        XCTAssertTrue(check(.lt, .number(5), .number(5.5)))
        XCTAssertTrue(check(.lte, .number(5), .number(5)))
        XCTAssertFalse(check(.lte, .number(6), .number(5)))
    }

    func testOrderingTreatsNumericStringsAsNumbers() {
        XCTAssertTrue(check(.gte, .string("250"), .number(100)))
        XCTAssertFalse(check(.gte, .string("4"), .number(5)))
        XCTAssertTrue(check(.lte, .string("5"), .string("5")))
        // Numerically 10 > 9, although "10" < "9" as text.
        XCTAssertTrue(check(.gt, .string("10"), .string("9")))
        XCTAssertTrue(check(.gt, .string("1e3"), .number(999)))
    }

    func testOrderingOfTextIsOrdinalAndCaseSensitive() {
        XCTAssertTrue(check(.gt, .string("2026-11-10T12:00:00Z"), .string("2026-01-01T00:00:00Z")))
        XCTAssertTrue(check(.lt, .string("a10"), .string("a9")))
        XCTAssertTrue(check(.lt, .string("Z"), .string("a")))
        XCTAssertTrue(check(.lte, .string("abc"), .string("abc")))
        XCTAssertFalse(check(.lt, .string("abc"), .string("abc")))
    }

    func testOrderingOfTextUsesUTF16CodeUnits() {
        // U+1F600 is the surrogate pair D83D DE00, which sorts before U+FF5E by code unit.
        XCTAssertEqual(ConditionEvaluator.order(.string("\u{1F600}"), .string("\u{FF5E}")), -1)
        XCTAssertEqual(ConditionEvaluator.order(.string("\u{FF5E}"), .string("\u{1F600}")), 1)
    }

    func testOrderingIsFalseWhenTheSidesCannotBeOrdered() {
        for op in [ConditionOperator.gt, .gte, .lt, .lte] {
            XCTAssertFalse(check(op, .number(5), .string("abc")), "\(op)")
            XCTAssertFalse(check(op, .bool(true), .bool(true)), "\(op)")
            XCTAssertFalse(check(op, .bool(true), .number(1)), "\(op)")
            XCTAssertFalse(check(op, nil, .number(1)), "\(op)")
            XCTAssertFalse(check(op, .number(1), nil), "\(op)")
        }
    }

    // MARK: - Decimal grammar

    func testParseDecimalAcceptsTheGrammar() {
        XCTAssertEqual(ConditionEvaluator.parseDecimal("5"), 5)
        XCTAssertEqual(ConditionEvaluator.parseDecimal("5."), 5)
        XCTAssertEqual(ConditionEvaluator.parseDecimal(".5"), 0.5)
        XCTAssertEqual(ConditionEvaluator.parseDecimal("+5"), 5)
        XCTAssertEqual(ConditionEvaluator.parseDecimal("-5.25"), -5.25)
        XCTAssertEqual(ConditionEvaluator.parseDecimal("1e3"), 1000)
        XCTAssertEqual(ConditionEvaluator.parseDecimal("1E-2"), 0.01)
        XCTAssertEqual(ConditionEvaluator.parseDecimal("5.e3"), 5000)
        XCTAssertEqual(ConditionEvaluator.parseDecimal("-.5e+1"), -5)
        XCTAssertEqual(ConditionEvaluator.parseDecimal("007"), 7)
        XCTAssertEqual(ConditionEvaluator.parseDecimal("1e-999"), 0)
    }

    func testParseDecimalRejectsEverythingElse() {
        let rejected = [
            "", " ", " 5", "5 ", "5f", "NaN", "nan", "inf", "Infinity", "-inf", "0x1p3", "0x10",
            "1e", "1e+", "e5", ".", "+", "-", "+.", "1.2.3", "1,5", "--5", "5-", "١٢٣", "５",
            "1e999", "-1e999", "1_000", "abc",
        ]
        for string in rejected {
            XCTAssertNil(ConditionEvaluator.parseDecimal(string), "\"\(string)\" must not parse")
        }
    }

    // MARK: - Text of a value

    func testTextOfValues() {
        XCTAssertEqual(ConditionEvaluator.text(of: .string("As Is")), "As Is")
        XCTAssertEqual(ConditionEvaluator.text(of: .bool(true)), "true")
        XCTAssertEqual(ConditionEvaluator.text(of: .bool(false)), "false")
        XCTAssertEqual(ConditionEvaluator.text(of: .number(5)), "5")
        XCTAssertEqual(ConditionEvaluator.text(of: .number(-3)), "-3")
        XCTAssertEqual(ConditionEvaluator.text(of: .number(-0.0)), "0")
        XCTAssertEqual(ConditionEvaluator.text(of: .number(5.5)), "5.5")
        XCTAssertEqual(ConditionEvaluator.text(of: .number(-3.25)), "-3.25")
        XCTAssertEqual(ConditionEvaluator.text(of: .number(0.1)), "0.1")
        XCTAssertEqual(ConditionEvaluator.text(of: .number(0.1 + 0.2)), "0.30000000000000004")
        XCTAssertEqual(ConditionEvaluator.text(of: .number(1_000_000)), "1000000")
    }

    func testTextOfNumbersNeverUsesAnExponent() {
        XCTAssertEqual(ConditionEvaluator.text(of: .number(1e21)), "1000000000000000000000")
        XCTAssertEqual(ConditionEvaluator.text(of: .number(1e16)), "10000000000000000")
        XCTAssertEqual(ConditionEvaluator.text(of: .number(0.00001)), "0.00001")
        XCTAssertEqual(ConditionEvaluator.text(of: .number(1.5e-7)), "0.00000015")
        XCTAssertEqual(ConditionEvaluator.text(of: .number(-2.5e-10)), "-0.00000000025")
    }
}

final class HashAndLocaleTests: XCTestCase {
    func testFNV1aReferenceVectors() {
        XCTAssertEqual(FNV1a.hash32(""), 0x811c_9dc5)
        XCTAssertEqual(FNV1a.hash32("a"), 0xe40c_292c)
        XCTAssertEqual(FNV1a.hash32("foobar"), 0xbf9c_f968)
    }

    /// The buckets named in the fixture cases.
    func testSamplingBucketsFromTheFixtures() {
        XCTAssertEqual(TargetingEngine.samplingBucket(installId: "install-a", surveyId: "S1"), 48)
        XCTAssertEqual(TargetingEngine.samplingBucket(installId: "install-a", surveyId: "S2"), 5)
        // The hash runs over UTF-8 bytes.
        XCTAssertEqual(TargetingEngine.samplingBucket(installId: "zażółć-🙂", surveyId: "S1"), 60)
        XCTAssertEqual(TargetingEngine.samplingBucket(installId: "zażółć-🙂", surveyId: "S2"), 17)
        XCTAssertEqual(FNV1a.hash32("install-a:S1"), 0xe767_c890)
        XCTAssertEqual(FNV1a.hash32("zażółć-🙂:S2"), 0x2e45_15dd)
    }

    func testSamplingBucketIsStableAndInRange() {
        for index in 0..<200 {
            let bucket = TargetingEngine.samplingBucket(installId: "install-\(index)", surveyId: "S")
            XCTAssertTrue((0..<100).contains(bucket))
            XCTAssertEqual(bucket, TargetingEngine.samplingBucket(installId: "install-\(index)", surveyId: "S"))
        }
    }

    func testLocaleMatching() {
        XCTAssertTrue(LocaleMatcher.matches(entry: "pt", tag: "pt-BR"))
        XCTAssertTrue(LocaleMatcher.matches(entry: "pt-BR", tag: "pt_br"))
        XCTAssertTrue(LocaleMatcher.matches(entry: "PT_br", tag: "pt-BR"))
        XCTAssertFalse(LocaleMatcher.matches(entry: "pt-BR", tag: "pt-PT"))
        XCTAssertFalse(LocaleMatcher.matches(entry: "pt-BR", tag: "pt"))
        XCTAssertFalse(LocaleMatcher.matches(entry: "p", tag: "pt-BR"))
        XCTAssertFalse(LocaleMatcher.matches(entry: "", tag: "pt-BR"))
        XCTAssertTrue(LocaleMatcher.matches(entry: "zh-Hans", tag: "zh-Hans-CN"))
        XCTAssertTrue(LocaleMatcher.matches(entries: ["pl", "en"], tag: "en-US"))
        XCTAssertFalse(LocaleMatcher.matches(entries: [], tag: "en-US"))
    }
}

final class TargetingEngineTests: XCTestCase {
    private let context = TargetingContext(platform: "ios", appId: "com.acme.app", deviceLocale: "en-US", installId: "install-a")
    private let now = Date(timeIntervalSince1970: 1_794_312_000)

    private func survey(_ id: String = "S1", _ configure: (inout SurveyConfig) -> Void = { _ in }) -> SurveyConfig {
        var survey = SurveyConfig(id: id, url: URL(string: "https://acme.responsly.com/f/\(id)")!)
        survey.triggers = [.event(name: "e", minCount: 1, conditions: [])]
        survey.frequency.mode = .always
        configure(&survey)
        return survey
    }

    private func reason(
        _ survey: SurveyConfig,
        mode: TargetingEngine.Mode = .targeting,
        state: SDKState = SDKState(installId: "install-a"),
        flags: TargetingFlags = TargetingFlags(),
        cooldown: TimeInterval = 0
    ) -> ResponslyNotShownReason? {
        var config = SDKConfig()
        config.globalCooldownSeconds = cooldown
        config.surveys = [survey]
        return TargetingEngine.ineligibilityReason(
            for: survey, mode: mode, config: config, state: state, flags: flags, context: context, now: now
        )
    }

    func testTheEngineIsDeterministic() {
        var config = SDKConfig()
        config.surveys = [survey("S1"), survey("S2")]
        let state = SDKState(installId: "install-a")
        let trigger = TriggerCall.event(name: "e", properties: [:], count: 1)
        let first = TargetingEngine.evaluate(trigger: trigger, config: config, state: state, flags: TargetingFlags(), context: context, now: now)
        let second = TargetingEngine.evaluate(trigger: trigger, config: config, state: state, flags: TargetingFlags(), context: context, now: now)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.selected?.id, "S1")
        XCTAssertEqual(first.notShown, [.init(surveyId: "S2", reason: .anotherSurveySelected)])
    }

    func testChecksRunInTheSpecifiedOrder() {
        // A survey that fails every check: the first failing check names the reason.
        var state = SDKState(installId: "install-a")
        state.trackingEnabled = false
        state.surveys["S1"] = { var s = SurveyState(); s.displayCount = 1; return s }()
        let failing = survey { survey in
            survey.schedule.endsAt = self.now
            survey.audience.platforms = ["android"]
            survey.audience.appIds = ["com.other"]
            survey.audience.locales = ["pl"]
            survey.audience.identified = true
            survey.frequency.mode = .once
            survey.samplingPercent = 0
        }
        let flags = TargetingFlags(paused: true, surveyActive: true)

        XCTAssertEqual(reason(failing, state: state, flags: flags), .disabled)
        state.trackingEnabled = true
        XCTAssertEqual(reason(failing, state: state, flags: flags), .anotherSurveyVisible)
        XCTAssertEqual(reason(failing, state: state, flags: TargetingFlags(paused: true)), .paused)
        XCTAssertEqual(reason(failing, state: state), .outsideSchedule)

        var next = failing
        next.schedule.endsAt = nil
        XCTAssertEqual(reason(next, state: state), .platformMismatch)
        next.audience.platforms = []
        XCTAssertEqual(reason(next, state: state), .appMismatch)
        next.audience.appIds = []
        XCTAssertEqual(reason(next, state: state), .localeMismatch)
        next.audience.locales = []
        XCTAssertEqual(reason(next, state: state), .audienceMismatch)
        next.audience.identified = nil
        XCTAssertEqual(reason(next, state: state), .frequencyLimit)
        next.frequency.mode = .always
        XCTAssertEqual(reason(next, state: state), .sampledOut)
        next.samplingPercent = 100
        XCTAssertNil(reason(next, state: state))
    }

    func testForceSkipsEverythingAfterTheVisibleCheck() {
        let failing = survey { survey in
            survey.audience.platforms = ["android"]
            survey.frequency.mode = .once
        }
        var state = SDKState(installId: "install-a")
        state.surveys["S1"] = { var s = SurveyState(); s.displayCount = 3; s.completedAt = self.now; return s }()
        XCTAssertNil(reason(failing, mode: .manual(force: true), state: state, flags: TargetingFlags(paused: true)))
        XCTAssertEqual(reason(failing, mode: .manual(force: true), state: state, flags: TargetingFlags(surveyActive: true)), .anotherSurveyVisible)
        XCTAssertEqual(reason(failing, mode: .manual(force: false), state: state), .platformMismatch)
    }

    func testManualShowIgnoresPauseCooldownAndSampling() {
        var state = SDKState(installId: "install-a")
        state.lastAutoDisplayAt = now.addingTimeInterval(-10)
        let sampled = survey { $0.samplingPercent = 0 }
        XCTAssertEqual(reason(sampled, state: state, cooldown: 600), .globalCooldown)
        XCTAssertEqual(reason(sampled, state: state), .sampledOut)
        XCTAssertNil(reason(sampled, mode: .manual(force: false), state: state, flags: TargetingFlags(paused: true), cooldown: 600))
    }

    func testFrequencyModes() {
        var shownOnce = SurveyState()
        shownOnce.displayCount = 1
        shownOnce.lastDisplayedAt = now.addingTimeInterval(-100)
        var done = shownOnce
        done.completedAt = now.addingTimeInterval(-50)

        var frequency = FrequencyConfig()
        frequency.mode = .once
        XCTAssertNil(TargetingEngine.frequencyReason(frequency, state: SurveyState(), now: now))
        XCTAssertEqual(TargetingEngine.frequencyReason(frequency, state: shownOnce, now: now), .frequencyLimit)
        XCTAssertEqual(TargetingEngine.frequencyReason(frequency, state: done, now: now), .alreadyCompleted)

        frequency.mode = .untilCompleted
        frequency.recontactSeconds = 100
        XCTAssertNil(TargetingEngine.frequencyReason(frequency, state: shownOnce, now: now))
        frequency.recontactSeconds = 101
        XCTAssertEqual(TargetingEngine.frequencyReason(frequency, state: shownOnce, now: now), .recontactWait)
        frequency.maxDisplays = 1
        XCTAssertEqual(TargetingEngine.frequencyReason(frequency, state: shownOnce, now: now), .frequencyLimit)
        XCTAssertEqual(TargetingEngine.frequencyReason(frequency, state: done, now: now), .alreadyCompleted)

        frequency.mode = .recurring
        XCTAssertEqual(TargetingEngine.frequencyReason(frequency, state: done, now: now), .frequencyLimit)
        frequency.maxDisplays = nil
        XCTAssertEqual(TargetingEngine.frequencyReason(frequency, state: done, now: now), .recontactWait)
        frequency.recontactSeconds = 0
        XCTAssertNil(TargetingEngine.frequencyReason(frequency, state: done, now: now))

        frequency.mode = .always
        frequency.recontactSeconds = 9_999
        XCTAssertNil(TargetingEngine.frequencyReason(frequency, state: done, now: now))
        frequency.maxDisplays = 1
        XCTAssertEqual(TargetingEngine.frequencyReason(frequency, state: done, now: now), .frequencyLimit)
    }

    func testEventTriggerUsesTheCountCarriedByTheCall() {
        let third = survey { $0.triggers = [.event(name: "e", minCount: 3, conditions: [])] }
        XCTAssertFalse(TargetingEngine.matches(survey: third, trigger: .event(name: "e", properties: [:], count: 2)))
        XCTAssertTrue(TargetingEngine.matches(survey: third, trigger: .event(name: "e", properties: [:], count: 3)))
        XCTAssertFalse(TargetingEngine.matches(survey: third, trigger: .event(name: "E", properties: [:], count: 3)))
        XCTAssertFalse(TargetingEngine.matches(survey: third, trigger: .screen(name: "e")))
        XCTAssertFalse(TargetingEngine.matches(trigger: .unknown, call: .appLaunch))
    }
}
