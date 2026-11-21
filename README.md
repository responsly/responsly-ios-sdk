# Responsly iOS SDK

Show [Responsly](https://responsly.com) surveys inside your iOS app. You choose in Responsly who should see a survey and when; the SDK downloads that configuration, decides on the device and presents the survey as a bottom sheet, a dialog or full screen.

- Swift, iOS 15+, no third-party dependencies
- Targeting runs on the device: events, screens, app launch, user traits, sampling, frequency and schedule
- No advertising identifier, no fingerprinting, no location; ships a privacy manifest

Full documentation: **https://developers.responsly.com**

## Installation

### Swift Package Manager

In Xcode choose **File › Add Package Dependencies…** and enter

```
https://github.com/responsly/responsly-ios-sdk
```

then add the `ResponslySDK` product to your app target. In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/responsly/responsly-ios-sdk", from: "1.2.3"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "ResponslySDK", package: "responsly-ios-sdk"),
    ]),
]
```

### CocoaPods

```ruby
pod 'ResponslySDK', :git => 'https://github.com/responsly/responsly-ios-sdk.git', :tag => '1.2.3'
```

## Quick start

```swift
import ResponslySDK

// 1. Start the SDK once, as early as you like (for example in your App's init
//    or in application(_:didFinishLaunchingWithOptions:)).
Responsly.shared.initialize(sdkKey: "rsk_…")

// 2. Tell it who the user is. Traits are used for targeting and sent to the survey.
Responsly.shared.identify(userId: "user-123", traits: [
    "plan": "pro",
    "seats": 5,
    "beta": true,
    "signed_up": .date(signUpDate),
])

// 3. Report what happens in the app. Surveys with a matching trigger show by themselves.
Responsly.shared.track("purchase_completed", properties: ["value": 49.9])
Responsly.shared.screen("Checkout")

// Or show a survey yourself.
Responsly.shared.showSurvey("AbCd1234")
```

The SDK key is your team's public key (`rsk_…`). There is nothing else to set up: the SDK presents surveys above whatever your app is showing, without you passing a view controller.

Every call is safe from any thread and before `initialize` — calls made earlier are remembered and applied once the SDK is initialised.

## API

All methods are on `Responsly.shared`.

| Call | What it does |
|---|---|
| `initialize(sdkKey:options:)` | Starts the SDK. `ResponslyOptions(apiHost:logLevel:)`; log levels `.none`, `.error` (default), `.info`, `.debug`. Calling it again with the same key does nothing; a different key resets the local state first. |
| `identify(userId:traits:)` | Sets the user id and merges traits. |
| `setAttributes(_:)` | Merges traits; a `nil` value removes one. |
| `track(_:properties:)` | Counts the event and evaluates event triggers. |
| `screen(_:)` | Sets the current screen and evaluates screen triggers. |
| `showSurvey(_:options:)` | Shows a survey by its Survey ID from the form's **Share → Mobile app** tab (a form with several configurations has one for each). `ResponslyShowOptions(force:hiddenFields:locale:presentation:)`. |
| `closeSurvey()` | Closes the visible survey. One that is not on screen yet (waiting or still loading) is cancelled silently. |
| `pause()` / `resume()` | Stops and resumes targeting; `showSurvey` still works. |
| `setLocale(_:)` | Overrides the locale used for targeting and the survey's language; `nil` returns to the device language. |
| `setHiddenFields(_:)` | Hidden-field values sent with every survey (replaces the previous map). |
| `setTrackingEnabled(_:)` | `false`: no network, no targeting, nothing shown. Persisted. |
| `reset()` | Clears the user, traits, counters and cached configuration, and closes a visible survey — call it on sign-out. |
| `setDisplayGuard(_:)` | Lets your app veto a survey right before it would appear. |
| `addListener(_:)` / `removeListener(_:)` | Survey lifecycle callbacks. |
| `Responsly.sdkVersion` | The SDK version, `"1.2.3"`. |

Trait and property values are `ResponslyValue`: a string, a number, a boolean or a date. Literals work directly (`"pro"`, `5`, `true`); use `.date(…)` for dates. `ResponslyValue.from(_:)` converts loosely typed values (`Any`), which is what cross-platform bridges need.

### Listening to events

Implement the methods you need — all of them are optional and are called on the main thread:

```swift
final class SurveyObserver: ResponslyListener {
    func surveyShown(_ event: ResponslySurveyShownEvent) {
        print("shown", event.survey.id, event.trigger.type)
    }

    func surveyNotShown(_ event: ResponslySurveyNotShownEvent) {
        print("not shown", event.surveyId, event.reason.rawValue)   // e.g. "frequency_limit"
    }

    func questionAnswered(_ event: ResponslyQuestionAnsweredEvent) {
        print(event.questionId, event.type, event.value)
    }

    func surveyCompleted(_ event: ResponslySurveyCompletedEvent) {
        print("completed", event.responseId, event.answers.count)
    }

    func surveyDismissed(_ event: ResponslySurveyDismissedEvent) {}   // shown, then closed before completion
    func surveyError(_ event: ResponslySurveyErrorEvent) {}
}

let token = Responsly.shared.addListener(SurveyObserver())
// later
Responsly.shared.removeListener(token)
```

Or with closures:

```swift
Responsly.shared.addListener(ResponslyListenerBlock(
    surveyCompleted: { event in analytics.log("survey_completed", event.toDictionary()) }
))
```

The SDK keeps a listener until you remove it. Every event has `toDictionary()`, a JSON-compatible dictionary with snake_case keys. An answer's `value` is JSON as the survey stores it (`String`, `NSNumber`, array, dictionary or `NSNull`).

`surveyNotShown` tells you why a survey that matched a trigger, or that you asked for, did not appear: `disabled`, `not_initialized`, `config_unavailable`, `survey_not_found`, `another_survey_visible`, `another_survey_selected`, `paused`, `outside_schedule`, `platform_mismatch`, `app_mismatch`, `locale_mismatch`, `audience_mismatch`, `already_completed`, `frequency_limit`, `recontact_wait`, `global_cooldown`, `sampled_out`, `screen_changed`, `vetoed`, `load_failed`, `survey_unavailable`.

### Display guard

Keep surveys away from moments that must not be interrupted:

```swift
Responsly.shared.setDisplayGuard { survey, decide in
    decide(!checkoutInProgress)   // false vetoes the survey
}
```

The guard is called on the main thread when the survey has loaded, right before it becomes visible. If it does not answer within 2 seconds the survey is shown. It is not asked for `showSurvey(…, options: ResponslyShowOptions(force: true))`.

### Showing a survey yourself

```swift
Responsly.shared.showSurvey("AbCd1234", options: ResponslyShowOptions(
    force: false,                       // true skips audience, schedule, frequency and the display guard
    hiddenFields: ["order_id": "A-77"], // merged over setHiddenFields for this survey
    locale: "pl",
    presentation: .dialog               // .bottomSheet, .dialog or .fullscreen
))
```

## Good to know

- **Presentation.** The style (bottom sheet, dialog, full screen), its size and whether the user can dismiss it come from the survey's settings in Responsly. The container follows the keyboard, honours Reduce Motion and closes by itself shortly after the survey is completed.
- **Links** in a survey open in the system browser when the user taps them (`http`, `https`, `mailto`, `tel`, `sms`). A survey never leaves the app by itself: an automatic redirect of an ending screen does not open the browser.
- **File and photo questions** work out of the box. If a survey lets people take a photo or record a video, your app's `Info.plist` needs `NSCameraUsageDescription` (and `NSMicrophoneUsageDescription` for video), as for any camera use on iOS.
- **Debugging.** With `logLevel: .debug` the SDK logs every targeting decision with its reason, every configuration fetch and the type of every message from the survey (never the answers), prefixed `[Responsly]`, and the survey can be inspected with Safari's Web Inspector.
- **App extensions** are not supported: surveys need an app window.

## Privacy

- The SDK uses no advertising identifier, no device fingerprint and no location.
- The user id, traits and hidden fields you provide are stored on the device and are handed only to the survey itself, at the moment it is shown. A survey marked anonymous in Responsly receives none of them.
- Requests to the Responsly API carry your SDK key, the platform, the SDK version and your app's bundle identifier. The only thing the SDK reports is that a survey was displayed, dismissed or completed — no user id, no install id, no traits, no timestamps.
- `setTrackingEnabled(false)` turns off all network activity and targeting.
- The package ships `PrivacyInfo.xcprivacy`: no tracking, and `UserDefaults` access with reason `CA92.1`. Answers people give in a survey are collected by that survey; reflect them in your App Store privacy details as you would for any form in your app.

## Example app

`Example/ResponslyExample.xcodeproj` is a small SwiftUI app with a button for every call and a live log of listener callbacks. Open it in Xcode, enter your SDK key (and an API host if you are not using the default) and run it on a simulator or a device. The example allows plain-HTTP loads so that it can talk to a local backend; the SDK itself never relaxes App Transport Security.

## Development

```sh
swift test                      # unit tests and the targeting conformance fixtures (runs on macOS)
xcodebuild -scheme ResponslySDK -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Example/ResponslyExample.xcodeproj -scheme ResponslyExample \
  -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

`docs/PROTOCOL.md` is the contract the SDK implements; `Tests/ResponslySDKTests/Fixtures/targeting-fixtures.json` holds the conformance cases shared by every Responsly SDK and must not be edited here.

## License

MIT — see [LICENSE](LICENSE).
