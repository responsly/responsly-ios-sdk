import XCTest
@testable import ResponslySDK

/// Runs every case of `targeting-fixtures.json` (protocol section 9) through the targeting engine.
/// The fixture file is a verbatim copy of the one next to the protocol; it must never be edited.
final class TargetingFixturesTests: XCTestCase {
    private func loadCases() throws -> [[String: Any]] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "targeting-fixtures", withExtension: "json", subdirectory: "Fixtures"),
            "targeting-fixtures.json is missing from the test bundle"
        )
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try XCTUnwrap(json as? [String: Any])
        return try XCTUnwrap(root["cases"] as? [[String: Any]])
    }

    func testEveryFixtureCase() throws {
        let cases = try loadCases()
        XCTAssertGreaterThanOrEqual(cases.count, 17, "the fixture file should hold every conformance case")

        var checkedSteps = 0
        for fixture in cases {
            let name = try XCTUnwrap(fixture["name"] as? String)
            let config = try XCTUnwrap(SDKConfig.parse(json: fixture["config"] as Any), "\(name): config")
            let contextJSON = try XCTUnwrap(fixture["context"] as? [String: Any])
            let context = TargetingContext(
                platform: try XCTUnwrap(contextJSON["platform"] as? String),
                appId: try XCTUnwrap(contextJSON["app_id"] as? String),
                deviceLocale: try XCTUnwrap(contextJSON["locale"] as? String),
                installId: try XCTUnwrap(contextJSON["install_id"] as? String)
            )
            var state = SDKState(installId: context.installId)
            var flags = TargetingFlags()

            let steps = try XCTUnwrap(fixture["steps"] as? [[String: Any]])
            for (index, step) in steps.enumerated() {
                let label = "\(name) / step \(index + 1)"
                let now = try XCTUnwrap(ISO8601.date(from: try XCTUnwrap(step["at"] as? String)), label)
                let action = try XCTUnwrap(step["action"] as? [String: Any], label)
                let type = try XCTUnwrap(action["type"] as? String, label)

                // Apply the action to the state; triggers and `show` also ask for a decision.
                var decision: TargetingDecision?
                switch type {
                case "track":
                    let eventName = try XCTUnwrap(action["name"] as? String, label)
                    let count = state.incrementEventCount(eventName)
                    var properties: [String: StoredValue] = [:]
                    for (key, value) in (action["properties"] as? [String: Any]) ?? [:] {
                        properties[key] = StoredValue(json: value)
                    }
                    decision = TargetingEngine.evaluate(
                        trigger: .event(name: eventName, properties: properties, count: count),
                        config: config, state: state, flags: flags, context: context, now: now
                    )
                case "screen":
                    decision = TargetingEngine.evaluate(
                        trigger: .screen(name: try XCTUnwrap(action["name"] as? String, label)),
                        config: config, state: state, flags: flags, context: context, now: now
                    )
                case "app_launch":
                    decision = TargetingEngine.evaluate(
                        trigger: .appLaunch,
                        config: config, state: state, flags: flags, context: context, now: now
                    )
                case "show":
                    decision = TargetingEngine.evaluateManual(
                        surveyId: try XCTUnwrap(action["survey"] as? String, label),
                        force: JSONRead.bool(action["force"]) ?? false,
                        config: config, state: state, flags: flags, context: context, now: now
                    )
                case "displayed":
                    state.recordDisplayed(
                        surveyId: try XCTUnwrap(action["survey"] as? String, label),
                        auto: JSONRead.bool(action["auto"]) ?? false,
                        at: now
                    )
                case "completed":
                    state.recordCompleted(surveyId: try XCTUnwrap(action["survey"] as? String, label), at: now)
                case "dismissed":
                    state.recordDismissed(surveyId: try XCTUnwrap(action["survey"] as? String, label))
                case "identify":
                    state.identify(
                        userId: try XCTUnwrap(action["user_id"] as? String, label),
                        traits: Self.traits(action["traits"])
                    )
                case "set_attributes":
                    state.mergeTraits(Self.traits(action["traits"]))
                case "set_locale":
                    state.locale = action["locale"] as? String
                case "pause":
                    flags.paused = true
                case "resume":
                    flags.paused = false
                case "set_tracking":
                    state.trackingEnabled = try XCTUnwrap(JSONRead.bool(action["enabled"]), label)
                case "visible":
                    flags.surveyActive = try XCTUnwrap(JSONRead.bool(action["value"]), label)
                default:
                    XCTFail("\(label): unknown action type \(type)")
                }

                guard let expect = step["expect"] as? [String: Any] else { continue }
                let actual = try XCTUnwrap(decision, "\(label): `expect` on an action that makes no decision")
                checkedSteps += 1

                XCTAssertTrue(expect.keys.contains("show"), "\(label): `expect` without `show`")
                let expectedShow = expect["show"] as? String
                XCTAssertEqual(actual.selected?.id, expectedShow, "\(label): show")

                if let expectedNotShown = expect["not_shown"] as? [String: String] {
                    var actualNotShown: [String: String] = [:]
                    for item in actual.notShown {
                        XCTAssertNil(actualNotShown[item.surveyId], "\(label): \(item.surveyId) reported twice")
                        actualNotShown[item.surveyId] = item.reason.rawValue
                    }
                    XCTAssertEqual(actualNotShown, expectedNotShown, "\(label): not_shown")
                }
            }
        }
        // Every `expect` in the file was compared, and there are plenty of them.
        let expectations = cases.reduce(0) { total, fixture in
            total + ((fixture["steps"] as? [[String: Any]]) ?? []).filter { $0["expect"] != nil }.count
        }
        XCTAssertEqual(checkedSteps, expectations)
        XCTAssertGreaterThanOrEqual(checkedSteps, 78)
    }

    func testFixtureFileDeclaresVersionOne() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "targeting-fixtures", withExtension: "json", subdirectory: "Fixtures")
        )
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(JSONRead.int(root["version"]), 1)
    }

    private static func traits(_ json: Any?) -> [String: StoredValue?] {
        var traits: [String: StoredValue?] = [:]
        for (key, value) in (json as? [String: Any]) ?? [:] {
            // JSON null removes the trait.
            traits.updateValue(StoredValue(json: value), forKey: key)
        }
        return traits
    }
}
