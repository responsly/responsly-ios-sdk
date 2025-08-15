import XCTest
@testable import ResponslySDK

final class ConfigDecodingTests: XCTestCase {
    private func parse(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> SDKConfig {
        try XCTUnwrap(SDKConfig.parse(Data(json.utf8)), file: file, line: line)
    }

    /// The body shown in protocol section 2.
    func testFullExample() throws {
        let config = try parse("""
        {
          "version": 1,
          "ttl": 600,
          "settings": { "global_cooldown_seconds": 0 },
          "surveys": [
            {
              "id": "aBcD1234",
              "name": "NPS after purchase",
              "url": "https://acme.responsly.com/f/aBcD1234",
              "updated_at": "2026-11-10T12:00:00Z",
              "triggers": [
                { "type": "event", "name": "purchase_completed", "min_count": 1,
                  "conditions": [ { "property": "value", "op": "gte", "value": 100 } ] },
                { "type": "screen", "name": "Checkout" },
                { "type": "app_launch" }
              ],
              "delay_seconds": 0,
              "audience": {
                "platforms": [],
                "app_ids": [],
                "locales": [],
                "identified": null,
                "match": "all",
                "conditions": [ { "attribute": "plan", "op": "eq", "value": "pro" } ]
              },
              "sampling_percent": 100,
              "frequency": { "mode": "once", "recontact_seconds": 0, "max_displays": null },
              "schedule": { "starts_at": null, "ends_at": null },
              "presentation": { "style": "bottom_sheet", "size": "medium", "dismissible": true, "auto_close_seconds": 3 },
              "anonymous": false
            }
          ]
        }
        """)

        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.ttl, 600)
        XCTAssertEqual(config.globalCooldownSeconds, 0)
        XCTAssertEqual(config.surveys.count, 1)
        let survey = try XCTUnwrap(config.survey(id: "aBcD1234"))
        XCTAssertEqual(survey.name, "NPS after purchase")
        XCTAssertEqual(survey.url.absoluteString, "https://acme.responsly.com/f/aBcD1234")
        XCTAssertEqual(survey.updatedAt, "2026-11-10T12:00:00Z")
        XCTAssertEqual(survey.triggers, [
            .event(name: "purchase_completed", minCount: 1, conditions: [
                Condition(name: "value", op: .gte, value: .number(100)),
            ]),
            .screen(name: "Checkout"),
            .appLaunch,
        ])
        XCTAssertEqual(survey.audience.conditions, [Condition(name: "plan", op: .eq, value: .string("pro"))])
        XCTAssertFalse(survey.audience.matchAny)
        XCTAssertNil(survey.audience.identified)
        XCTAssertEqual(survey.frequency.mode, .once)
        XCTAssertNil(survey.frequency.maxDisplays)
        XCTAssertEqual(survey.presentation.style, .bottomSheet)
        XCTAssertEqual(survey.presentation.size, .medium)
        XCTAssertTrue(survey.presentation.dismissible)
        XCTAssertEqual(survey.presentation.autoCloseSeconds, 3)
        XCTAssertFalse(survey.anonymous)
        XCTAssertEqual(config.surveyHosts, ["acme.responsly.com"])
    }

    func testEveryFieldExceptIdAndURLMayBeMissing() throws {
        let config = try parse(#"{ "surveys": [ { "id": "S1", "url": "https://acme.responsly.com/f/S1" } ] }"#)
        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.ttl, 600)
        XCTAssertEqual(config.globalCooldownSeconds, 0)

        let survey = try XCTUnwrap(config.surveys.first)
        XCTAssertEqual(survey.name, "")
        XCTAssertNil(survey.updatedAt)
        XCTAssertEqual(survey.triggers, [])
        XCTAssertEqual(survey.delaySeconds, 0)
        XCTAssertEqual(survey.audience, AudienceConfig())
        XCTAssertEqual(survey.audience.platforms, [])
        XCTAssertEqual(survey.audience.appIds, [])
        XCTAssertEqual(survey.audience.locales, [])
        XCTAssertNil(survey.audience.identified)
        XCTAssertFalse(survey.audience.matchAny)
        XCTAssertEqual(survey.audience.conditions, [])
        XCTAssertEqual(survey.samplingPercent, 100)
        XCTAssertEqual(survey.frequency.mode, .once)
        XCTAssertEqual(survey.frequency.recontactSeconds, 0)
        XCTAssertNil(survey.frequency.maxDisplays)
        XCTAssertNil(survey.schedule.startsAt)
        XCTAssertNil(survey.schedule.endsAt)
        XCTAssertEqual(survey.presentation.style, .bottomSheet)
        XCTAssertEqual(survey.presentation.size, .medium)
        XCTAssertTrue(survey.presentation.dismissible)
        XCTAssertEqual(survey.presentation.autoCloseSeconds, 3)
        XCTAssertFalse(survey.anonymous)
    }

    func testEmptyObjectIsAValidConfiguration() throws {
        let config = try parse("{}")
        XCTAssertEqual(config, SDKConfig())
        XCTAssertEqual(config.surveys, [])
    }

    func testUnknownEnumValuesAndFields() throws {
        let config = try parse("""
        { "version": 7, "future_field": true, "surveys": [
          { "id": "S1", "url": "https://acme.responsly.com/f/S1", "new_thing": { "a": 1 },
            "triggers": [ { "type": "shake" }, { "type": "event" }, { "type": "screen" }, "nonsense",
                          { "type": "event", "name": "e", "conditions": [ { "property": "p", "op": "regex", "value": ".*" }, 5 ] } ],
            "frequency": { "mode": "sometimes" },
            "presentation": { "style": "hologram", "size": "gigantic" },
            "audience": { "match": "most", "conditions": [ { "attribute": "a", "op": "between", "value": [1, 2] } ] } }
        ] }
        """)
        XCTAssertEqual(config.version, 7)
        let survey = try XCTUnwrap(config.surveys.first)
        // An unknown trigger type never matches; a known type without its name neither.
        XCTAssertEqual(survey.triggers.prefix(4), [.unknown, .unknown, .unknown, .unknown])
        XCTAssertEqual(survey.triggers.last, .event(name: "e", minCount: 1, conditions: [
            Condition(name: "p", op: .unknown, value: .string(".*")),
            Condition(name: nil, op: .unknown, value: nil),
        ]))
        XCTAssertEqual(survey.frequency.mode, .once)
        XCTAssertEqual(survey.presentation.style, .bottomSheet)
        XCTAssertEqual(survey.presentation.size, .medium)
        XCTAssertFalse(survey.audience.matchAny)
        XCTAssertEqual(survey.audience.conditions, [Condition(name: "a", op: .unknown, value: nil)])
    }

    func testKnownEnumValues() throws {
        let config = try parse("""
        { "surveys": [
          { "id": "A", "url": "https://x.test/a", "frequency": { "mode": "until_completed", "recontact_seconds": 3600, "max_displays": 2 },
            "presentation": { "style": "dialog", "size": "small", "dismissible": false, "auto_close_seconds": 0 }, "audience": { "match": "any", "identified": true } },
          { "id": "B", "url": "https://x.test/b", "frequency": { "mode": "recurring" },
            "presentation": { "style": "fullscreen", "size": "large", "auto_close_seconds": 7.5 }, "audience": { "identified": false } },
          { "id": "C", "url": "https://x.test/c", "frequency": { "mode": "always" }, "anonymous": true,
            "delay_seconds": 2.5, "sampling_percent": 12.5 }
        ] }
        """)
        let a = try XCTUnwrap(config.survey(id: "A"))
        XCTAssertEqual(a.frequency.mode, .untilCompleted)
        XCTAssertEqual(a.frequency.recontactSeconds, 3600)
        XCTAssertEqual(a.frequency.maxDisplays, 2)
        XCTAssertEqual(a.presentation.style, .dialog)
        XCTAssertEqual(a.presentation.size, .small)
        XCTAssertFalse(a.presentation.dismissible)
        XCTAssertEqual(a.presentation.autoCloseSeconds, 0)
        XCTAssertTrue(a.audience.matchAny)
        XCTAssertEqual(a.audience.identified, true)

        let b = try XCTUnwrap(config.survey(id: "B"))
        XCTAssertEqual(b.frequency.mode, .recurring)
        XCTAssertEqual(b.presentation.style, .fullscreen)
        XCTAssertEqual(b.presentation.size, .large)
        XCTAssertEqual(b.presentation.autoCloseSeconds, 7.5)
        XCTAssertEqual(b.audience.identified, false)

        let c = try XCTUnwrap(config.survey(id: "C"))
        XCTAssertEqual(c.frequency.mode, .always)
        XCTAssertTrue(c.anonymous)
        XCTAssertEqual(c.delaySeconds, 2.5)
        XCTAssertEqual(c.samplingPercent, 12.5)
    }

    func testWronglyTypedFieldsFallBackToDefaults() throws {
        let config = try parse("""
        { "version": "two", "ttl": "soon", "settings": [], "surveys": [
          { "id": "S1", "url": "https://acme.responsly.com/f/S1", "name": 5, "triggers": "all",
            "delay_seconds": "3", "sampling_percent": "50", "anonymous": "yes",
            "audience": { "platforms": "ios", "app_ids": [1, "com.acme.app"], "identified": "true", "conditions": {} },
            "frequency": { "mode": 3, "recontact_seconds": true, "max_displays": "2" },
            "schedule": { "starts_at": 5, "ends_at": "tomorrow" },
            "presentation": { "style": 1, "size": 2, "dismissible": "no", "auto_close_seconds": "3" } }
        ] }
        """)
        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.ttl, 600)
        let survey = try XCTUnwrap(config.surveys.first)
        XCTAssertEqual(survey.name, "")
        XCTAssertEqual(survey.triggers, [])
        XCTAssertEqual(survey.delaySeconds, 0)
        XCTAssertEqual(survey.samplingPercent, 100)
        XCTAssertFalse(survey.anonymous)
        XCTAssertEqual(survey.audience.platforms, [])
        XCTAssertEqual(survey.audience.appIds, ["com.acme.app"])
        XCTAssertNil(survey.audience.identified)
        XCTAssertEqual(survey.audience.conditions, [])
        XCTAssertEqual(survey.frequency, FrequencyConfig())
        XCTAssertEqual(survey.schedule, ScheduleConfig())
        XCTAssertEqual(survey.presentation, PresentationConfig())
    }

    func testSurveysWithoutIdOrUsableURLAreSkipped() throws {
        let config = try parse("""
        { "surveys": [
          { "url": "https://acme.responsly.com/f/none" },
          { "id": "no-url" },
          { "id": "", "url": "https://acme.responsly.com/f/empty" },
          { "id": 12, "url": "https://acme.responsly.com/f/12" },
          { "id": "relative", "url": "/f/relative" },
          { "id": "script", "url": "javascript:alert(1)" },
          { "id": "file", "url": "file:///etc/hosts" },
          "nonsense",
          { "id": "ok", "url": "http://form.responsly.test:8086/f/ok" },
          { "id": "ok", "url": "https://acme.responsly.com/f/duplicate" }
        ] }
        """)
        XCTAssertEqual(config.surveys.map { $0.id }, ["ok"])
        XCTAssertEqual(config.surveys.first?.url.absoluteString, "http://form.responsly.test:8086/f/ok")
    }

    func testMinimumEffectiveTTL() throws {
        XCTAssertEqual(try parse(#"{ "ttl": 5 }"#).effectiveTTL, 60)
        XCTAssertEqual(try parse(#"{ "ttl": 0 }"#).effectiveTTL, 60)
        XCTAssertEqual(try parse(#"{ "ttl": -100 }"#).effectiveTTL, 60)
        XCTAssertEqual(try parse(#"{ "ttl": 60 }"#).effectiveTTL, 60)
        XCTAssertEqual(try parse(#"{ "ttl": 900 }"#).effectiveTTL, 900)
        XCTAssertEqual(try parse("{}").effectiveTTL, 600)
    }

    func testScheduleDates() throws {
        let config = try parse("""
        { "surveys": [ { "id": "S1", "url": "https://x.test/s", "schedule": {
            "starts_at": "2026-11-10T12:00:00Z", "ends_at": "2026-11-11T13:00:00.500+01:00" } } ] }
        """)
        let schedule = try XCTUnwrap(config.surveys.first).schedule
        XCTAssertEqual(schedule.startsAt, Date(timeIntervalSince1970: 1_794_312_000))
        let endsAt = try XCTUnwrap(schedule.endsAt)
        XCTAssertEqual(endsAt.timeIntervalSince1970, 1_794_312_000 + 86_400 + 0.5, accuracy: 0.001)
    }

    func testABooleanIsNeverReadAsANumberAndTheOtherWayRound() throws {
        let config = try parse("""
        { "ttl": true, "surveys": [ { "id": "S1", "url": "https://x.test/s", "anonymous": 1,
            "presentation": { "dismissible": 0 },
            "audience": { "conditions": [ { "attribute": "beta", "op": "eq", "value": true },
                                          { "attribute": "n", "op": "eq", "value": 1 } ] } } ] }
        """)
        XCTAssertEqual(config.ttl, 600)
        let survey = try XCTUnwrap(config.surveys.first)
        XCTAssertFalse(survey.anonymous)
        XCTAssertTrue(survey.presentation.dismissible)
        XCTAssertEqual(survey.audience.conditions.map { $0.value }, [.bool(true), .number(1)])
    }

    func testBodiesThatAreNotAnObject() {
        XCTAssertNil(SDKConfig.parse(Data("[]".utf8)))
        XCTAssertNil(SDKConfig.parse(Data("\"config\"".utf8)))
        XCTAssertNil(SDKConfig.parse(Data("<html>".utf8)))
        XCTAssertNil(SDKConfig.parse(Data()))
    }
}
