import XCTest
@testable import ResponslySDK

final class ResponslyValueTests: XCTestCase {
    func testLiterals() {
        let traits: [String: ResponslyValue?] = ["plan": "pro", "seats": 5, "ratio": 0.5, "beta": true, "old": nil]
        XCTAssertEqual(traits["plan"], ResponslyValue.string("pro"))
        XCTAssertEqual(traits["seats"], ResponslyValue.number(5))
        XCTAssertEqual(traits["ratio"], ResponslyValue.number(0.5))
        XCTAssertEqual(traits["beta"], ResponslyValue.bool(true))
        XCTAssertEqual(traits["old"], .some(nil))
        XCTAssertEqual(traits.count, 5)
    }

    func testFromStringsNumbersAndDates() {
        XCTAssertEqual(ResponslyValue.from("pro"), .string("pro"))
        XCTAssertEqual(ResponslyValue.from("pro" as NSString), .string("pro"))
        XCTAssertEqual(ResponslyValue.from(5), .number(5))
        XCTAssertEqual(ResponslyValue.from(5.5), .number(5.5))
        XCTAssertEqual(ResponslyValue.from(Float(0.5)), .number(0.5))
        XCTAssertEqual(ResponslyValue.from(Int64(1) << 40), .number(1_099_511_627_776))
        XCTAssertEqual(ResponslyValue.from(NSNumber(value: 49.9)), .number(49.9))
        let date = Date(timeIntervalSince1970: 1_794_312_000)
        XCTAssertEqual(ResponslyValue.from(date), .date(date))
        XCTAssertEqual(ResponslyValue.from(date as NSDate), .date(date))
        XCTAssertEqual(ResponslyValue.from(ResponslyValue.bool(false)), .bool(false))
    }

    func testFromDetectsBooleansCorrectly() {
        XCTAssertEqual(ResponslyValue.from(true), .bool(true))
        XCTAssertEqual(ResponslyValue.from(false), .bool(false))
        XCTAssertEqual(ResponslyValue.from(NSNumber(value: true)), .bool(true))
        XCTAssertEqual(ResponslyValue.from(kCFBooleanFalse as Any), .bool(false))
        // 0 and 1 are numbers, not booleans.
        XCTAssertEqual(ResponslyValue.from(NSNumber(value: 1)), .number(1))
        XCTAssertEqual(ResponslyValue.from(NSNumber(value: 0)), .number(0))
        XCTAssertEqual(ResponslyValue.from(1), .number(1))
        XCTAssertEqual(ResponslyValue.from(UInt8(1)), .number(1))

        // The way values arrive from a JSON bridge.
        let json = try? JSONSerialization.jsonObject(with: Data(#"{"flag":true,"one":1,"zero":0,"no":false}"#.utf8))
        let object = json as? [String: Any]
        XCTAssertEqual(ResponslyValue.from(object?["flag"]), .bool(true))
        XCTAssertEqual(ResponslyValue.from(object?["no"]), .bool(false))
        XCTAssertEqual(ResponslyValue.from(object?["one"]), .number(1))
        XCTAssertEqual(ResponslyValue.from(object?["zero"]), .number(0))
    }

    func testAnISO8601StringStaysAString() {
        XCTAssertEqual(ResponslyValue.from("2026-11-10T12:00:00Z"), .string("2026-11-10T12:00:00Z"))
    }

    func testFromRejectsEverythingElse() {
        XCTAssertNil(ResponslyValue.from(nil))
        XCTAssertNil(ResponslyValue.from(NSNull()))
        XCTAssertNil(ResponslyValue.from(["a"]))
        XCTAssertNil(ResponslyValue.from(["a": 1]))
        XCTAssertNil(ResponslyValue.from(Double.nan))
        XCTAssertNil(ResponslyValue.from(Double.infinity))
        XCTAssertNil(ResponslyValue.from(URL(string: "https://example.com")!))
    }

    func testMapsFromABridge() {
        let raw: [String: Any?] = ["plan": "pro", "seats": 5, "beta": true, "gone": NSNull(), "also_gone": nil, "list": [1, 2]]
        let traits = ResponslyValue.traits(from: raw)
        XCTAssertEqual(traits.count, 5)
        XCTAssertEqual(traits["plan"], ResponslyValue.string("pro"))
        XCTAssertEqual(traits["seats"], ResponslyValue.number(5))
        XCTAssertEqual(traits["beta"], ResponslyValue.bool(true))
        XCTAssertEqual(traits["gone"], .some(nil))
        XCTAssertEqual(traits["also_gone"], .some(nil))
        XCTAssertFalse(traits.keys.contains("list"))

        let properties = ResponslyValue.properties(from: raw)
        XCTAssertEqual(properties, ["plan": .string("pro"), "seats": .number(5), "beta": .bool(true)])
    }

    func testDatesAreStoredAsISO8601UTCWithSecondsPrecision() {
        let date = Date(timeIntervalSince1970: 1_794_312_000.987)
        XCTAssertEqual(StoredValue(.date(date)), .string("2026-11-10T12:00:00Z"))
        XCTAssertEqual(ISO8601.string(from: Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00Z")
        XCTAssertEqual(ISO8601.date(from: "2026-11-10T13:00:00+01:00"), Date(timeIntervalSince1970: 1_794_312_000))
        XCTAssertNil(ISO8601.date(from: "10 November"))
        XCTAssertNil(StoredValue(.number(.nan)))
        XCTAssertEqual(StoredValue(.number(2)), .number(2))
        XCTAssertEqual(StoredValue(.bool(true)), .bool(true))
    }
}

final class PublicEventTests: XCTestCase {
    func testNotShownReasonsAreExactlyTheProtocolList() {
        let expected = [
            "disabled", "not_initialized", "config_unavailable", "survey_not_found", "another_survey_visible",
            "another_survey_selected", "paused", "outside_schedule", "platform_mismatch", "app_mismatch",
            "locale_mismatch", "audience_mismatch", "already_completed", "frequency_limit", "recontact_wait",
            "global_cooldown", "sampled_out", "screen_changed", "vetoed", "load_failed", "survey_unavailable",
        ]
        XCTAssertEqual(ResponslyNotShownReason.allCases.map { $0.rawValue }, expected)
    }

    func testEnumsUseTheProtocolNames() {
        XCTAssertEqual(ResponslyPresentationStyle.allCases.map { $0.rawValue }, ["bottom_sheet", "dialog", "fullscreen"])
        XCTAssertEqual(ResponslyTriggerType.allCases.map { $0.rawValue }, ["event", "screen", "app_launch", "manual"])
        XCTAssertEqual(ResponslyLogLevel.allCases.map { $0.name }, ["none", "error", "info", "debug"])
        XCTAssertEqual(ResponslyLogLevel(name: "DEBUG"), .debug)
        XCTAssertNil(ResponslyLogLevel(name: "verbose"))
        XCTAssertTrue(ResponslyLogLevel.error < ResponslyLogLevel.debug)
    }

    func testDefaults() {
        let options = ResponslyOptions()
        XCTAssertEqual(options.apiHost.absoluteString, "https://api.responsly.com")
        XCTAssertEqual(options.logLevel, .error)

        let show = ResponslyShowOptions()
        XCTAssertFalse(show.force)
        XCTAssertEqual(show.hiddenFields, [:])
        XCTAssertNil(show.locale)
        XCTAssertNil(show.presentation)

        XCTAssertEqual(Responsly.sdkVersion, "0.9.2")
    }

    private func json(_ dictionary: [String: Any]) throws -> String {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(dictionary))
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    func testEventDictionariesUseSnakeCaseKeys() throws {
        let shown = ResponslySurveyShownEvent(
            survey: ResponslySurvey(id: "aBcD1234", name: "NPS"),
            trigger: ResponslyTrigger(type: .event, name: "purchase_completed")
        )
        XCTAssertEqual(
            try json(shown.toDictionary()),
            #"{"survey":{"id":"aBcD1234","name":"NPS"},"trigger":{"name":"purchase_completed","type":"event"}}"#
        )
        let manual = ResponslySurveyShownEvent(survey: ResponslySurvey(id: "S", name: ""), trigger: ResponslyTrigger(type: .manual))
        XCTAssertEqual(try json(manual.toDictionary()), #"{"survey":{"id":"S","name":""},"trigger":{"type":"manual"}}"#)

        XCTAssertEqual(
            try json(ResponslySurveyNotShownEvent(surveyId: "S", reason: .frequencyLimit).toDictionary()),
            #"{"reason":"frequency_limit","survey_id":"S"}"#
        )
        XCTAssertEqual(
            try json(ResponslyQuestionAnsweredEvent(surveyId: "S", questionId: "q1", type: "nps", title: "How likely?", value: 9).toDictionary()),
            #"{"question_id":"q1","survey_id":"S","title":"How likely?","type":"nps","value":9}"#
        )
        let completed = ResponslySurveyCompletedEvent(surveyId: "S", responseId: "r_1", answers: [
            ResponslyAnswer(questionId: "q1", type: "nps", title: "How likely?", value: 9),
            ResponslyAnswer(questionId: "q2", type: "multiple_choice", title: "Why?", value: ["price", "support"]),
            ResponslyAnswer(questionId: "q3", type: "text", title: "More?", value: NSNull()),
        ])
        XCTAssertEqual(
            try json(completed.toDictionary()),
            #"{"answers":[{"question_id":"q1","title":"How likely?","type":"nps","value":9},"#
                + #"{"question_id":"q2","title":"Why?","type":"multiple_choice","value":["price","support"]},"#
                + #"{"question_id":"q3","title":"More?","type":"text","value":null}],"response_id":"r_1","survey_id":"S"}"#
        )
        XCTAssertEqual(try json(ResponslySurveyDismissedEvent(surveyId: "S").toDictionary()), #"{"survey_id":"S"}"#)
        XCTAssertEqual(
            try json(ResponslySurveyErrorEvent(surveyId: "S", code: "expired", message: "Closed").toDictionary()),
            #"{"code":"expired","message":"Closed","survey_id":"S"}"#
        )
    }

    func testListenerBlockForwardsOnlyWhatWasGiven() {
        var seen: [String] = []
        let block = ResponslyListenerBlock(
            surveyShown: { seen.append("shown:\($0.survey.id)") },
            surveyCompleted: { seen.append("completed:\($0.responseId)") }
        )
        MainActor.assumeIsolated {
            block.surveyShown(ResponslySurveyShownEvent(survey: ResponslySurvey(id: "S", name: ""), trigger: ResponslyTrigger(type: .manual)))
            block.surveyNotShown(ResponslySurveyNotShownEvent(surveyId: "S", reason: .paused))
            block.surveyDismissed(ResponslySurveyDismissedEvent(surveyId: "S"))
            block.surveyCompleted(ResponslySurveyCompletedEvent(surveyId: "S", responseId: "r", answers: []))
        }
        XCTAssertEqual(seen, ["shown:S", "completed:r"])
    }

    func testAListenerNeedsToImplementNothing() {
        struct Silent: ResponslyListener {}
        let listener: ResponslyListener = Silent()
        MainActor.assumeIsolated {
            listener.surveyShown(ResponslySurveyShownEvent(survey: ResponslySurvey(id: "S", name: ""), trigger: ResponslyTrigger(type: .manual)))
            listener.surveyNotShown(ResponslySurveyNotShownEvent(surveyId: "S", reason: .paused))
            listener.questionAnswered(ResponslyQuestionAnsweredEvent(surveyId: "S", questionId: "q", type: "t", title: "", value: 1))
            listener.surveyCompleted(ResponslySurveyCompletedEvent(surveyId: "S", responseId: "r", answers: []))
            listener.surveyDismissed(ResponslySurveyDismissedEvent(surveyId: "S"))
            listener.surveyError(ResponslySurveyErrorEvent(surveyId: "S", code: "c", message: "m"))
        }
    }
}

/// The call shapes documented for app developers and used by the cross-platform wrappers.
/// Compiled, never run: it would start the real SDK.
private enum PublicAPIShape {
    final class MyListener: ResponslyListener {
        func surveyShown(_ event: ResponslySurveyShownEvent) {}
        func surveyNotShown(_ event: ResponslySurveyNotShownEvent) {}
    }

    static func everyCall(checkoutInProgress: Bool) {
        Responsly.shared.initialize(sdkKey: "rsk_…")
        Responsly.shared.initialize(sdkKey: "rsk_…", options: ResponslyOptions(apiHost: URL(string: "https://api.responsly.com")!, logLevel: .debug))
        Responsly.shared.identify(userId: "user-123")
        Responsly.shared.identify(userId: "user-123", traits: ["plan": "pro", "seats": 5, "beta": true, "signed_up": .date(Date())])
        Responsly.shared.setAttributes(["plan": "team", "beta": nil])
        Responsly.shared.track("purchase_completed")
        Responsly.shared.track("purchase_completed", properties: ["value": 49.9])
        Responsly.shared.screen("Checkout")
        Responsly.shared.showSurvey("AbCd1234")
        Responsly.shared.showSurvey("AbCd1234", options: ResponslyShowOptions(force: false, hiddenFields: ["order_id": "A-77"], locale: "pl", presentation: .dialog))
        Responsly.shared.closeSurvey()
        Responsly.shared.pause()
        Responsly.shared.resume()
        Responsly.shared.setLocale("pl")
        Responsly.shared.setLocale(nil)
        Responsly.shared.setHiddenFields(["order_id": "A-77"])
        Responsly.shared.setTrackingEnabled(false)
        Responsly.shared.reset()
        Responsly.shared.setDisplayGuard { survey, decide in decide(!checkoutInProgress && !survey.id.isEmpty) }
        Responsly.shared.setDisplayGuard(nil)
        let token: ResponslyListenerToken = Responsly.shared.addListener(MyListener())
        Responsly.shared.removeListener(token)
        Responsly.shared.addListener(ResponslyListenerBlock(surveyCompleted: { event in _ = event.toDictionary() }))
        let version: String = Responsly.sdkVersion
        _ = version
        // What a bridge does with loosely typed input.
        let loose: [String: Any?] = ["plan": "pro", "beta": NSNumber(value: true), "old": NSNull()]
        Responsly.shared.setAttributes(ResponslyValue.traits(from: loose))
        Responsly.shared.track("event", properties: ResponslyValue.properties(from: loose))
        _ = ResponslyPresentationStyle(rawValue: "bottom_sheet")
        _ = ResponslyLogLevel(name: "debug")
    }
}
