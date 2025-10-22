import XCTest
@testable import ResponslySDK

final class BridgeMessageTests: XCTestCase {
    private func parse(_ type: String, _ payload: String = "{}") -> BridgeMessage? {
        BridgeMessage.parse("{\"responsly\":1,\"type\":\"\(type)\",\"payload\":\(payload)}")
    }

    func testReady() {
        guard case .ready(let surveyId, let title, let color, let pages)? = parse(
            "ready", ##"{"survey_id":"aBcD1234","title":"NPS","background_color":"#FFFFFF","page_count":3}"##
        ) else { return XCTFail("expected ready") }
        XCTAssertEqual(surveyId, "aBcD1234")
        XCTAssertEqual(title, "NPS")
        XCTAssertEqual(color, "#FFFFFF")
        XCTAssertEqual(pages, 3)

        // Every payload field is optional.
        guard case .ready(nil, nil, nil, nil)? = parse("ready") else { return XCTFail("expected a bare ready") }
        guard case .ready? = BridgeMessage.parse(#"{"responsly":1,"type":"ready"}"#) else {
            return XCTFail("a message without a payload is still a message")
        }
    }

    func testResize() {
        guard case .resize(let height)? = parse("resize", #"{"height":412.5}"#) else { return XCTFail("expected resize") }
        XCTAssertEqual(height, 412.5)
        XCTAssertNil(parse("resize", "{}"))
        XCTAssertNil(parse("resize", #"{"height":"tall"}"#))
        XCTAssertNil(parse("resize", #"{"height":-5}"#))
    }

    func testPageChanged() {
        guard case .pageChanged(let index, let count)? = parse("page_changed", #"{"index":1,"count":4}"#) else {
            return XCTFail("expected page_changed")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(count, 4)
    }

    func testQuestionAnsweredPassesTheValueThroughAsJSON() throws {
        func value(_ json: String) throws -> Any {
            guard case .questionAnswered(let answer)? = parse(
                "question_answered", "{\"question_id\":\"q1\",\"type\":\"nps\",\"title\":\"How likely?\",\"value\":\(json)}"
            ) else {
                XCTFail("expected question_answered")
                throw NSError(domain: "test", code: 1)
            }
            XCTAssertEqual(answer.questionId, "q1")
            XCTAssertEqual(answer.type, "nps")
            XCTAssertEqual(answer.title, "How likely?")
            return answer.value
        }

        XCTAssertEqual(try value("\"great\"") as? String, "great")
        XCTAssertEqual(try value("9") as? NSNumber, 9)
        XCTAssertEqual(try value("true") as? NSNumber, NSNumber(value: true))
        XCTAssertEqual(try value("[\"a\",\"b\"]") as? [String], ["a", "b"])
        XCTAssertEqual(try value("{\"row\":\"col\"}") as? [String: String], ["row": "col"])
        XCTAssertTrue(try value("null") is NSNull)

        // A missing value is JSON null; a numeric id becomes its text.
        guard case .questionAnswered(let bare)? = parse("question_answered", #"{"question_id":42}"#) else {
            return XCTFail("expected question_answered")
        }
        XCTAssertEqual(bare.questionId, "42")
        XCTAssertEqual(bare.type, "")
        XCTAssertTrue(bare.value is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(bare.toDictionary()))
    }

    func testCompleted() {
        guard case .completed(let responseId, let answers)? = parse("completed", """
        {"response_id":"r_1","answers":[
          {"question_id":"q1","type":"nps","title":"How likely?","value":9},
          {"question_id":"q2","type":"multiple_choice","title":"Why?","value":["price","support"]},
          "nonsense"
        ]}
        """) else { return XCTFail("expected completed") }
        XCTAssertEqual(responseId, "r_1")
        XCTAssertEqual(answers.map { $0.questionId }, ["q1", "q2"])
        XCTAssertEqual(answers.map { $0.type }, ["nps", "multiple_choice"])
        XCTAssertEqual(answers[1].value as? [String], ["price", "support"])

        guard case .completed("", let none)? = parse("completed") else { return XCTFail("expected completed") }
        XCTAssertTrue(none.isEmpty)
    }

    func testCloseRequestedAndError() {
        guard case .closeRequested("completed"?)? = parse("close_requested", #"{"reason":"completed"}"#) else {
            return XCTFail("expected close_requested")
        }
        guard case .closeRequested(nil)? = parse("close_requested") else { return XCTFail("expected close_requested") }
        guard case .error(let code, let message)? = parse("error", #"{"code":"not_found","message":"No such survey"}"#) else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(code, "not_found")
        XCTAssertEqual(message, "No such survey")
    }

    func testUnknownTypesAreRecognisedAsSuch() {
        guard case .unknown("confetti")? = parse("confetti", #"{"amount":3}"#) else {
            return XCTFail("an unknown type is parsed and then ignored by the SDK")
        }
    }

    func testAnythingThatIsNotAResponslyMessageIsIgnored() {
        XCTAssertNil(BridgeMessage.parse(""))
        XCTAssertNil(BridgeMessage.parse("ready"))
        XCTAssertNil(BridgeMessage.parse("[1,2,3]"))
        XCTAssertNil(BridgeMessage.parse(#"{"type":"ready","payload":{}}"#))
        XCTAssertNil(BridgeMessage.parse(#"{"responsly":2,"type":"ready","payload":{}}"#))
        XCTAssertNil(BridgeMessage.parse(#"{"responsly":true,"type":"ready","payload":{}}"#))
        XCTAssertNil(BridgeMessage.parse(#"{"responsly":"1","type":"ready","payload":{}}"#))
        XCTAssertNil(BridgeMessage.parse(#"{"responsly":1,"payload":{}}"#))
        XCTAssertNil(BridgeMessage.parse(#"{"responsly":1,"type":7}"#))
    }
}

final class SurveyPageTests: XCTestCase {
    private let surveyURL = URL(string: "https://acme.responsly.com/f/aBcD1234")!

    func testURLGetsSdkAndOnlyAnExplicitLanguage() {
        XCTAssertEqual(
            SurveyPage.url(surveyURL: surveyURL, lang: nil).absoluteString,
            "https://acme.responsly.com/f/aBcD1234?sdk=1"
        )
        XCTAssertEqual(
            SurveyPage.url(surveyURL: surveyURL, lang: "pl").absoluteString,
            "https://acme.responsly.com/f/aBcD1234?sdk=1&lang=pl"
        )
        XCTAssertEqual(
            SurveyPage.url(surveyURL: surveyURL, lang: "pt-BR").absoluteString,
            "https://acme.responsly.com/f/aBcD1234?sdk=1&lang=pt-BR"
        )
        XCTAssertEqual(
            SurveyPage.url(surveyURL: surveyURL, lang: "").absoluteString,
            "https://acme.responsly.com/f/aBcD1234?sdk=1"
        )
    }

    func testURLKeepsAnExistingQueryAndEncodesTheLanguage() {
        let withQuery = URL(string: "http://form.responsly.test:8086/f/x?theme=dark")!
        XCTAssertEqual(
            SurveyPage.url(surveyURL: withQuery, lang: "a&b=c").absoluteString,
            "http://form.responsly.test:8086/f/x?theme=dark&sdk=1&lang=a%26b%3Dc"
        )
    }

    private func input(anonymous: Bool = false, userId: String? = "u_123") -> SurveyPage.ContextInput {
        SurveyPage.ContextInput(
            platform: "ios", sdkVersion: "1.0.0", appId: "com.acme.app", appVersion: "2.3.0",
            osVersion: "18.1", locale: "en-US", surveyId: "aBcD1234",
            trigger: ResponslyTrigger(type: .event, name: "purchase_completed"),
            style: .bottomSheet, dismissible: true, anonymous: anonymous, userId: userId,
            traits: ["plan": .string("pro"), "seats": .number(5), "beta": .bool(true)],
            hiddenFields: ["order_id": "A-77"]
        )
    }

    /// The object of protocol section 5.2.
    func testContext() throws {
        let context = SurveyPage.context(input())
        let expected: [String: Any] = [
            "v": 1,
            "platform": "ios",
            "sdk_version": "1.0.0",
            "app_id": "com.acme.app",
            "app_version": "2.3.0",
            "os_version": "18.1",
            "locale": "en-US",
            "survey_id": "aBcD1234",
            "trigger": ["type": "event", "name": "purchase_completed"],
            "presentation": ["style": "bottom_sheet", "dismissible": true],
            "user": ["id": "u_123", "traits": ["plan": "pro", "seats": 5, "beta": true]],
            "hidden": ["order_id": "A-77"],
        ]
        XCTAssertEqual(context as NSDictionary, expected as NSDictionary)

        // Booleans stay booleans in the JSON the page sees.
        let json = try XCTUnwrap(SurveyPage.javaScriptLiteral(context))
        XCTAssertTrue(json.contains("\"beta\":true"), json)
        XCTAssertTrue(json.contains("\"dismissible\":true"), json)
        XCTAssertTrue(json.contains("\"seats\":5"), json)
        XCTAssertTrue(json.contains("\"v\":1"), json)
    }

    func testAnonymousSurveyGetsNoUserAndNoHiddenFields() {
        let context = SurveyPage.context(input(anonymous: true))
        XCTAssertTrue(context["user"] is NSNull)
        XCTAssertEqual(context["hidden"] as? [String: String], [:])
    }

    func testUserIsNullWhenNotIdentified() {
        let context = SurveyPage.context(input(userId: nil))
        XCTAssertTrue(context["user"] is NSNull)
        // Hidden fields still travel: they do not identify anybody by themselves.
        XCTAssertEqual(context["hidden"] as? [String: String], ["order_id": "A-77"])
    }

    func testManualAndAppLaunchTriggersHaveNoName() {
        var manual = input()
        manual.trigger = ResponslyTrigger(type: .manual)
        XCTAssertEqual(SurveyPage.context(manual)["trigger"] as? [String: String], ["type": "manual"])
        manual.trigger = ResponslyTrigger(type: .appLaunch)
        XCTAssertEqual(SurveyPage.context(manual)["trigger"] as? [String: String], ["type": "app_launch"])
    }

    func testContextScriptDefinesTheGlobalOnlyForTheSurveyOrigin() throws {
        let origin = try XCTUnwrap(WebOrigin(url: surveyURL))
        let script = SurveyPage.contextScript(context: SurveyPage.context(input()), origin: origin)
        XCTAssertTrue(script.contains("window.__RESPONSLY_SDK__ = {"), script)
        XCTAssertTrue(script.contains("window.location.origin !== [\"https:\\/\\/acme.responsly.com\"][0]"), script)
        XCTAssertTrue(script.contains("\"survey_id\":\"aBcD1234\""), script)
    }

    func testScriptLiteralEscapesLineSeparators() throws {
        let literal = try XCTUnwrap(SurveyPage.javaScriptLiteral(["text": "a\u{2028}b\u{2029}c</script>"]))
        XCTAssertFalse(literal.contains("\u{2028}"))
        XCTAssertFalse(literal.contains("\u{2029}"))
        XCTAssertTrue(literal.contains("\\u2028"))
        XCTAssertFalse(literal.contains("</script>"))
    }
}

final class WebOriginAndNavigationTests: XCTestCase {
    private let surveyURL = URL(string: "https://acme.responsly.com/f/aBcD1234")!

    func testOriginNormalisesCaseAndDefaultPorts() throws {
        let origin = try XCTUnwrap(WebOrigin(url: URL(string: "HTTPS://Acme.Responsly.com/f/x")!))
        XCTAssertEqual(origin, WebOrigin(scheme: "https", host: "acme.responsly.com", port: 443))
        // WebKit reports port 0 for the default port.
        XCTAssertEqual(origin, WebOrigin(scheme: "https", host: "acme.responsly.com", port: 0))
        XCTAssertEqual(origin, WebOrigin(scheme: "https", host: "acme.responsly.com", port: nil))
        XCTAssertNotEqual(origin, WebOrigin(scheme: "http", host: "acme.responsly.com", port: nil))
        XCTAssertNotEqual(origin, WebOrigin(scheme: "https", host: "evil.responsly.com", port: nil))
        XCTAssertNotEqual(origin, WebOrigin(scheme: "https", host: "acme.responsly.com", port: 8443))
        XCTAssertEqual(origin.serialized, "https://acme.responsly.com")
    }

    func testOriginSerialisationWithPortsAndIPv6() throws {
        XCTAssertEqual(try XCTUnwrap(WebOrigin(url: URL(string: "http://form.responsly.test:8086/f/x")!)).serialized, "http://form.responsly.test:8086")
        XCTAssertEqual(try XCTUnwrap(WebOrigin(url: URL(string: "http://localhost:80/")!)).serialized, "http://localhost")
        XCTAssertEqual(WebOrigin(scheme: "http", host: "::1", port: 3000).serialized, "http://[::1]:3000")
        XCTAssertEqual(WebOrigin(scheme: "http", host: "[::1]", port: 3000), WebOrigin(scheme: "http", host: "::1", port: 3000))
        XCTAssertNil(WebOrigin(url: URL(string: "mailto:hi@example.com")!))
    }

    private func decide(_ url: String?, mainFrame: Bool = true, newWindow: Bool = false) -> NavigationDecision {
        NavigationPolicy.decide(
            url: url.flatMap(URL.init(string:)), surveyURL: surveyURL, isMainFrame: mainFrame, opensNewWindow: newWindow
        )
    }

    func testMainFrameStaysOnTheSurveyOriginAndPath() {
        XCTAssertEqual(decide("https://acme.responsly.com/f/aBcD1234?sdk=1"), .allow)
        XCTAssertEqual(decide("https://acme.responsly.com/f/aBcD1234?sdk=1&lang=pl#page-2"), .allow)
        XCTAssertEqual(decide("https://ACME.responsly.com:443/f/aBcD1234"), .allow)

        XCTAssertEqual(decide("https://acme.responsly.com/f/other"), .openExternally)
        XCTAssertEqual(decide("https://acme.responsly.com/f/aBcD1234/"), .openExternally)
        XCTAssertEqual(decide("https://acme.responsly.com/"), .openExternally)
        XCTAssertEqual(decide("http://acme.responsly.com/f/aBcD1234"), .openExternally)
        XCTAssertEqual(decide("https://other.responsly.com/f/aBcD1234"), .openExternally)
        XCTAssertEqual(decide("https://example.com/thanks"), .openExternally)
        XCTAssertEqual(decide("mailto:hello@example.com"), .openExternally)
        XCTAssertEqual(decide("tel:+48123456789"), .openExternally)
    }

    func testInertSchemesAreCancelledNotOpened() {
        for url in ["about:blank", "javascript:alert(1)", "data:text/html,hi", "file:///etc/hosts", "blob:https://acme.responsly.com/1"] {
            XCTAssertEqual(decide(url), .cancel, url)
            XCTAssertEqual(decide(url, mainFrame: false, newWindow: true), .cancel, url)
        }
        XCTAssertEqual(decide(nil), .cancel)
    }

    func testSubframesNavigateFreely() {
        XCTAssertEqual(decide("https://www.youtube.com/embed/x", mainFrame: false), .allow)
        XCTAssertEqual(decide("about:blank", mainFrame: false), .allow)
    }

    func testLinksThatAskForANewWindowOpenInTheBrowser() {
        XCTAssertEqual(decide("https://example.com/privacy", mainFrame: false, newWindow: true), .openExternally)
        // Even the survey's own URL: the WebView never opens a second window.
        XCTAssertEqual(decide("https://acme.responsly.com/f/aBcD1234", mainFrame: false, newWindow: true), .openExternally)
    }

    func testEmptyPathEqualsRoot() {
        let root = URL(string: "https://survey.example.com")!
        XCTAssertTrue(NavigationPolicy.isSurveyDocument(URL(string: "https://survey.example.com/?sdk=1")!, surveyURL: root))
        XCTAssertFalse(NavigationPolicy.isSurveyDocument(URL(string: "https://survey.example.com/x")!, surveyURL: root))
    }

    func testWebsiteDataRecordsAreMatchedByRegistrableDomain() {
        XCTAssertTrue(WebsiteDataMatcher.host("acme.responsly.com", belongsToRecordNamed: "responsly.com"))
        XCTAssertTrue(WebsiteDataMatcher.host("Responsly.com", belongsToRecordNamed: "responsly.com"))
        XCTAssertTrue(WebsiteDataMatcher.host("localhost", belongsToRecordNamed: "localhost"))
        XCTAssertFalse(WebsiteDataMatcher.host("acme.responsly.com", belongsToRecordNamed: "sly.com"))
        XCTAssertFalse(WebsiteDataMatcher.host("acme.responsly.com", belongsToRecordNamed: "example.com"))
        XCTAssertFalse(WebsiteDataMatcher.host("", belongsToRecordNamed: ""))
    }
}

final class PresentationTests: XCTestCase {
    func testHexColours() throws {
        let white = try XCTUnwrap(HexColor(css: "#FFFFFF"))
        XCTAssertEqual(white.red, 1)
        XCTAssertEqual(white.alpha, 1)
        XCTAssertFalse(white.isDark)

        let short = try XCTUnwrap(HexColor(css: " #1af "))
        XCTAssertEqual(short.red, Double(0x11) / 255, accuracy: 0.0001)
        XCTAssertEqual(short.green, Double(0xaa) / 255, accuracy: 0.0001)
        XCTAssertEqual(short.blue, 1)

        let translucent = try XCTUnwrap(HexColor(css: "#00000080"))
        XCTAssertEqual(translucent.alpha, Double(0x80) / 255, accuracy: 0.0001)
        XCTAssertTrue(translucent.isDark)
        XCTAssertEqual(try XCTUnwrap(HexColor(css: "#123f")).alpha, 1)
        XCTAssertTrue(try XCTUnwrap(HexColor(css: "#1B1F3B")).isDark)

        for invalid in ["", "#", "red", "FFFFFF", "#12", "#12345", "#1234567", "#gggggg", "rgb(0,0,0)", "#ＦＦＦ"] {
            XCTAssertNil(HexColor(css: invalid), invalid)
        }
        XCTAssertNil(HexColor(css: nil))
    }

    private func height(
        _ style: ResponslyPresentationStyle, _ size: PresentationSize,
        screen: Double = 800, requested: Double = 0, chrome: Double = 0
    ) -> Double {
        PresentationMetrics.containerHeight(
            style: style, size: size, screenHeight: screen, requestedContentHeight: requested, chrome: chrome
        )
    }

    func testBottomSheetHeightBySize() {
        XCTAssertEqual(height(.bottomSheet, .small), 360, accuracy: 0.001)
        XCTAssertEqual(height(.bottomSheet, .medium), 520, accuracy: 0.001)
        XCTAssertEqual(height(.bottomSheet, .large), 704, accuracy: 0.001)
    }

    func testDialogHeightBySize() {
        XCTAssertEqual(height(.dialog, .small), 320, accuracy: 0.001)
        XCTAssertEqual(height(.dialog, .medium), 448, accuracy: 0.001)
        XCTAssertEqual(height(.dialog, .large), 640, accuracy: 0.001)
    }

    func testNeverLessThan320() {
        XCTAssertEqual(height(.bottomSheet, .small, screen: 600), 320)
        XCTAssertEqual(height(.dialog, .small, screen: 600), 320)
        XCTAssertEqual(height(.dialog, .medium, screen: 500), 320)
        // On a very short screen the minimum wins over the percentage limit.
        XCTAssertEqual(height(.bottomSheet, .large, screen: 340), 320)
        XCTAssertEqual(height(.bottomSheet, .small, screen: 340, requested: 900), 320)
    }

    func testResizeGrowsUpToTheLimitAndNeverShrinks() {
        // Medium sheet on an 800-point screen: 520 by size, 704 at most.
        XCTAssertEqual(height(.bottomSheet, .medium, requested: 600), 600, accuracy: 0.001)
        XCTAssertEqual(height(.bottomSheet, .medium, requested: 5_000), 704, accuracy: 0.001)
        XCTAssertEqual(height(.bottomSheet, .medium, requested: 100), 520, accuracy: 0.001)
        // The page's height excludes the strip over the bottom safe area.
        XCTAssertEqual(height(.bottomSheet, .medium, requested: 600, chrome: 34), 634, accuracy: 0.001)
        XCTAssertEqual(height(.bottomSheet, .medium, requested: 500, chrome: 34), 534, accuracy: 0.001)
        XCTAssertEqual(height(.bottomSheet, .medium, requested: 400, chrome: 34), 520, accuracy: 0.001)

        // Dialog: 448 by size, 640 at most.
        XCTAssertEqual(height(.dialog, .medium, requested: 500), 500, accuracy: 0.001)
        XCTAssertEqual(height(.dialog, .medium, requested: 5_000), 640, accuracy: 0.001)
        XCTAssertEqual(height(.dialog, .large, requested: 5_000), 640, accuracy: 0.001)
    }

    func testFullscreenIgnoresSizeAndResize() {
        XCTAssertEqual(height(.fullscreen, .small), 800)
        XCTAssertEqual(height(.fullscreen, .large, requested: 100), 800)
    }
}
