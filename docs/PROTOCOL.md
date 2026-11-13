# Responsly Mobile SDK — protocol and behaviour (v1)

This document is the contract shared by the backend, the survey page and every SDK. The native SDKs (iOS, Android) implement it in full; React Native, Flutter and Unity wrap the native SDKs and add nothing to it. `targeting-fixtures.json` next to this file holds conformance cases that both native targeting engines must pass unchanged.

## 1. Concepts

- **SDK key** — public, per team, format `rsk_` + 40 characters. Identifies the team; it is not a secret.
- **Survey** — one configuration of a form's mobile channel: the form's address with its own targeting. A form has one configuration and may have more; each is a survey of its own, with the same `url` and its own `id`. The `id` is an opaque string: the form's public id for the first configuration, and the same id with a suffix (`aBcD1234-k3f9x2a1`) for the others. The SDK compares ids and never parses them.
- **Targeting is evaluated on the device.** The SDK downloads the configuration, keeps state locally and decides. The server only receives aggregate telemetry.
- **Rendering** — the SDK presents a native container (bottom sheet, dialog or full screen) holding a WebView that loads the survey page. The page talks to the SDK through the bridge in section 5.

## 2. HTTP API

Base URL: `options.apiHost`, default `https://api.responsly.com`.

Headers on every request:

| Header | Value |
|---|---|
| `X-Responsly-Sdk-Key` | the SDK key |
| `X-Responsly-Platform` | `ios` or `android` |
| `X-Responsly-Sdk-Version` | e.g. `1.0.0` |
| `X-Responsly-App-Id` | bundle id / application id |
| `Accept` | `application/json` |

### GET /sdk/v1/config

Sends `If-None-Match` with the last `ETag` when there is a cached copy. Responses: `200` with the body below, `304` (keep the cached copy, restart its TTL), `401` `{"error":"invalid_sdk_key"}` (drop the cache, show nothing, do not retry until the next launch), other statuses and network errors (keep the cached copy, retry on the next foreground).

```json
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
```

Every field except `id` and `url` may be missing; the defaults are the values shown above (empty `triggers` means the survey is shown only by `showSurvey`). Unknown fields and unknown enum values are ignored: an unknown trigger type never matches, an unknown `op` evaluates to false, an unknown `frequency.mode` is treated as `once`, an unknown `presentation.style` as `bottom_sheet`, an unknown `presentation.size` as `medium`. A body whose `version` is greater than 1 is still read with these rules.

A form with several configurations is in `surveys` once for each of them, next to each other, the first configuration first. They are separate surveys in everything below: the order they are selected in (4.1), state (3), sampling (4.2), telemetry and listeners. A form completed through one configuration is not completed for the others.

`ttl` is in seconds. The SDK loads the cached configuration at `initialize`, fetches when there is no cache or it is older than `ttl`, and again whenever the app returns to the foreground with a stale cache. Minimum effective TTL: 60 seconds.

### POST /sdk/v1/events

Best-effort telemetry, batched (flush at 20 events, on background, and at most every 30 seconds while events are waiting). Events that cannot be sent are kept (at most 200) and retried later. Not sent when tracking is disabled.

```json
{ "events": [ { "type": "displayed", "survey_id": "aBcD1234" } ] }
```

`type` is `displayed`, `dismissed` or `completed`. The server answers `204`. No user id, install id, traits or timestamps are sent.

## 3. Local state

Persisted per SDK key (iOS: `UserDefaults` suite `com.responsly.sdk`; Android: `SharedPreferences` `com.responsly.sdk`):

- `install_id` — random UUID v4, lower-case, created once. Never sent to the server.
- `user_id`, `traits` — from `identify` / `setAttributes`.
- `locale` — override from `setLocale`, or none.
- `hidden_fields` — from `setHiddenFields`.
- `tracking_enabled` — default true.
- `event_counts` — `{event name: number of track calls}`.
- `surveys` — per survey id: `display_count`, `last_displayed_at`, `completed_at`, `dismissed_count`.
- `last_auto_display_at` — when a survey was last shown by targeting (not by `showSurvey`).
- the cached configuration with its `ETag` and fetch time; the telemetry queue.

`reset()` clears everything except `install_id` and `tracking_enabled`, clears the WebView's stored website data for survey hosts, closes a visible survey, and keeps the SDK initialised. `paused` and listeners are in-memory only.

Values (`traits`, event properties) are one of: string, number (double), boolean, date. Dates are stored and compared as ISO 8601 UTC strings with seconds precision, e.g. `2026-11-10T12:00:00Z`. `null` removes a trait.

## 4. Targeting

### 4.1 Triggers

| Call | Matches triggers |
|---|---|
| `track(name, properties)` | `event` with the same `name` (case-sensitive), `event_counts[name]` (after this call is counted) ≥ `min_count`, and every entry of `conditions` true against `properties` |
| `screen(name)` | `screen` with the same `name` (case-sensitive) |
| configuration first available after `initialize` in this process | `app_launch` |

Calls made before the configuration is available are queued (at most 50, oldest dropped) and evaluated in order once it is. Event counts are incremented at call time regardless.

For each trigger call the engine walks `surveys` in configuration order, keeps those with a matching trigger, and checks eligibility (4.2). The first eligible survey is selected; every other matched survey is reported as not shown with its reason (`another_survey_selected` for eligible ones after the first).

The selected survey is shown after `delay_seconds`. When the delay ends, eligibility is checked again; for a `screen` trigger the survey is not shown if the current screen is no longer that screen (`screen_changed`). A new selection while one is waiting or visible is not shown (`another_survey_visible`).

### 4.2 Eligibility

Checked in this order; the first failing check gives the reason.

| # | Check | Reason | Applies to |
|---|---|---|---|
| 1 | tracking is enabled | `disabled` | all |
| 2 | survey id exists in the configuration | `survey_not_found` | `showSurvey` |
| 3 | no survey is visible or waiting for its delay | `another_survey_visible` | all |
| 4 | `showSurvey` with `force: true` stops here: eligible | | `showSurvey` |
| 5 | not paused | `paused` | targeting |
| 6 | `schedule.starts_at` ≤ now < `schedule.ends_at` (each bound only when set) | `outside_schedule` | all |
| 7 | `audience.platforms` empty or contains the platform | `platform_mismatch` | all |
| 8 | `audience.app_ids` empty or contains the app id (case-sensitive) | `app_mismatch` | all |
| 9 | `audience.locales` empty or one entry matches the locale | `locale_mismatch` | all |
| 10 | `audience.identified` null, or equal to "a user id is set" | `audience_mismatch` | all |
| 11 | `audience.conditions` empty, or all (`match: "all"`) / at least one (`match: "any"`) true against `traits` | `audience_mismatch` | all |
| 12 | frequency, see below | `already_completed`, `frequency_limit`, `recontact_wait` | all |
| 13 | `settings.global_cooldown_seconds` is 0 or has passed since `last_auto_display_at` | `global_cooldown` | targeting |
| 14 | sampling bucket < `sampling_percent` | `sampled_out` | targeting |

Locale: the SDK's locale is the `setLocale` override or the device's preferred language as a BCP 47 tag. Comparison is case-insensitive with `_` treated as `-`; an entry matches when it equals the tag or the tag starts with the entry followed by `-` (`pt` matches `pt-BR`; `pt-BR` does not match `pt-PT`).

Frequency, with `d` = `display_count`, `last` = `last_displayed_at`, `done` = `completed_at` is set:

| `mode` | Eligible when | Reason otherwise |
|---|---|---|
| `once` | not `done` and `d` = 0 | `already_completed` if `done`, else `frequency_limit` |
| `until_completed` | not `done`, and (`max_displays` null or `d` < `max_displays`), and (`last` null or now − `last` ≥ `recontact_seconds`) | `already_completed`, `frequency_limit`, `recontact_wait` (in that order) |
| `recurring` | (`max_displays` null or `d` < `max_displays`) and (`last` null or now − `last` ≥ `recontact_seconds`) | `frequency_limit`, `recontact_wait` |
| `always` | `max_displays` null or `d` < `max_displays` | `frequency_limit` |

Sampling bucket: `fnv1a32(utf8(install_id + ":" + survey_id)) mod 100`, where FNV-1a 32-bit starts at `0x811c9dc5` and multiplies by `0x01000193`. The bucket is stable for an install, so a survey does not flicker in and out.

### 4.3 Conditions

`{ "attribute" | "property": name, "op": op, "value": value }`. `actual` is the trait or event property with that name.

| `op` | True when |
|---|---|
| `exists` | `actual` is present |
| `not_exists` | `actual` is absent |
| `eq` | present and equal |
| `neq` | absent, or not equal |
| `contains` | present and its text contains the text of `value` |
| `not_contains` | absent, or does not contain |
| `gt`, `gte`, `lt`, `lte` | present and ordered accordingly |

- Equality: two numbers compare numerically, two booleans as booleans; anything else compares as text, case-insensitively.
- Text of a value: a string as is; a boolean as `true` / `false`; a number without a fractional part as an integer (`5`, not `5.0`), otherwise its shortest decimal form.
- `contains` is case-insensitive.
- Ordering: when both sides are numbers, or strings that parse as finite decimals, compare numerically; otherwise when both are strings compare them as text (ordinal, case-sensitive — ISO dates order correctly); otherwise false.
- A string parses as a finite decimal only when it matches `^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$` (ASCII digits, no surrounding spaces) and the value is finite. Do not rely on the platform's lenient number parser (`5f`, `NaN`, `0x1p3` are not numbers here).
- Lower-casing for case-insensitive comparison is locale-independent.
- `audience.match` other than `any` means `all`.

### 4.4 State changes

- A survey becomes visible (after the page reported `ready`): `display_count` + 1, `last_displayed_at` = now; when it was selected by targeting also `last_auto_display_at` = now. Telemetry `displayed`.
- The page reports `completed`: `completed_at` = now. Telemetry `completed`.
- The survey is closed before `completed`: `dismissed_count` + 1. Telemetry `dismissed`.
- A survey that fails to load changes nothing.

### 4.5 Not-shown reasons

`disabled`, `not_initialized`, `config_unavailable`, `survey_not_found`, `another_survey_visible`, `another_survey_selected`, `paused`, `outside_schedule`, `platform_mismatch`, `app_mismatch`, `locale_mismatch`, `audience_mismatch`, `already_completed`, `frequency_limit`, `recontact_wait`, `global_cooldown`, `sampled_out`, `screen_changed`, `vetoed`, `load_failed`, `survey_unavailable`.

## 5. Survey page and bridge

### 5.1 URL

`survey.url` + `?sdk=1`, plus `&lang=<code>` only when a locale was set with `setLocale` or `showSurvey(locale:)`. Nothing else goes into the URL: user data travels in the context.

### 5.2 Context (SDK → page)

Before any page script runs, in the main frame only and only for the survey's origin, the SDK defines:

```js
window.__RESPONSLY_SDK__ = {
  "v": 1,
  "platform": "ios",              // or "android"
  "sdk_version": "1.0.0",
  "app_id": "com.acme.app",
  "app_version": "2.3.0",
  "os_version": "18.1",
  "locale": "en-US",
  "survey_id": "aBcD1234",
  "trigger": { "type": "event", "name": "purchase_completed" },   // or {"type":"manual"}
  "presentation": { "style": "bottom_sheet", "dismissible": true },
  "user": { "id": "u_123", "traits": { "plan": "pro" } },          // null when anonymous or not identified
  "hidden": { "order_id": "A-77" }
}
```

When the survey has `anonymous: true` the SDK sends `user: null` and an empty `hidden`.

`survey_id` is the `id` from the configuration, unchanged. The page sends it back with the response, so the response records which configuration of the form it came through.

iOS: a `WKUserScript` at document start, `forMainFrameOnly: true`. Android: `WebViewCompat.addDocumentStartJavaScript` with the survey origin as the only allowed origin rule.

### 5.3 Messages (page → SDK)

A JSON string: `{"responsly":1,"type":"<type>","payload":{...}}`.

- iOS: `window.webkit.messageHandlers.responsly.postMessage(string)`; the SDK ignores messages that are not from the main frame of the survey origin.
- Android: `window.ResponslyAndroid.postMessage(string)`, registered with `WebViewCompat.addWebMessageListener` for the survey origin only. Never `addJavascriptInterface`.

| `type` | `payload` | SDK reaction |
|---|---|---|
| `ready` | `{ "survey_id", "title", "background_color", "page_count" }` | make the container visible; use `background_color` (CSS hex) for the container |
| `resize` | `{ "height" }` — the height the page needs, in CSS pixels | bottom sheet and dialog grow to it, within their limits (section 6); a smaller value is ignored |
| `page_changed` | `{ "index", "count" }` | none |
| `question_answered` | `{ "question_id", "type", "title", "value" }` | `questionAnswered` listener |
| `completed` | `{ "response_id", "answers": [ { "question_id", "type", "title", "value" } ] }` | state change, `surveyCompleted` listener; start the auto-close timer and show the close button (section 6) |
| `close_requested` | `{ "reason": "completed" \| "user" }` | close the container |
| `error` | `{ "code", "message" }` | before `ready`: do not show, report `survey_unavailable`; after: `surveyError` listener |

`value` is JSON: string, number, boolean, array or object, as the survey stores the answer. Unknown message types are ignored.

### 5.4 Loading and navigation

- The WebView is created and loaded while the container is hidden. It becomes visible on `ready`. If `ready` does not arrive within 15 seconds, or the main-frame load fails, the survey is not shown (`load_failed`).
- Once the survey is visible, main-frame navigation to anything other than the survey URL's origin and path opens in the system browser and is cancelled in the WebView. Links that ask for a new window do the same. Before `ready` such a navigation (a redirect of the survey URL included) does not open anything: the survey is not shown (`load_failed`).
- JavaScript, DOM storage and persistent cookies are enabled. File inputs (photo, file upload questions) must work: Android implements `onShowFileChooser`.
- The user agent gets the suffix ` ResponslySDK/<version> (<platform>)`.

## 6. Presentation

| Style | Layout |
|---|---|
| `bottom_sheet` | attached to the bottom, full width (max 640 pt/dp, centred on tablets), top corners rounded 16; dimmed backdrop. Height by `presentation.size`: `small` 45%, `medium` 65%, `large` 88% of the screen height, never less than 320 |
| `dialog` | centred card, width min(screen − 32, 480), corners 16; dimmed backdrop. Height by `presentation.size`: `small` 40%, `medium` 56%, `large` 80% of the screen height, never less than 320 |
| `fullscreen` | covers the screen; the page handles safe areas; `size` is ignored |

- The page lays itself out for the height it is given, like in a mobile browser, and scrolls inside when it needs more. When it reports a larger height with `resize`, the sheet or dialog grows to it (animated), up to 88% (sheet) or 80% (dialog) of the screen height. It never shrinks while visible.
- After `completed` the SDK closes the survey by itself after `presentation.auto_close_seconds` (default 3; 0 = stays until closed), and from that moment shows the close button and accepts a backdrop tap / system back even when `dismissible` is false. A `close_requested` or a navigation away (5.4) closes it earlier.

- `dismissible: true`: a close button (24 pt/dp icon, 44 pt/dp touch target) in the top trailing corner of the container, drawn by the SDK above the WebView, plus tap on the backdrop, plus system back on Android. `false`: none of these; the survey closes only by `close_requested` or `closeSurvey()`.
- The container follows the keyboard: the sheet stays above it and the WebView resizes.
- Appears and disappears with a short animation (slide for the sheet, fade for the others); honours reduced motion.
- Presented above the app's current top view controller / activity without requiring the host to pass one.

## 7. Public API

Names are the same on every platform, in the platform's idiom. All calls are safe from any thread and before `initialize` (they are remembered and applied; `showSurvey` before `initialize` reports `not_initialized`).

| Call | Behaviour |
|---|---|
| `initialize(sdkKey, options)` | options: `apiHost`, `logLevel` (`none`, `error`, `info`, `debug`). Idempotent for the same key and host; a different key resets state first (keeping `install_id` and `tracking_enabled`); the same key with a different `apiHost` switches to it, drops the cached configuration and fetches again. |
| `identify(userId, traits)` | sets the user id and merges traits |
| `setAttributes(traits)` | merges traits; `null` removes |
| `track(event, properties)` | counts the event, evaluates event triggers |
| `screen(name)` | sets the current screen, evaluates screen triggers |
| `showSurvey(surveyId, options)` | options: `force`, `hiddenFields` (merged over `setHiddenFields`, per-call values win), `locale`, `presentation` (style override). Shown at once: `delay_seconds` applies to targeting only. Without a configuration it waits for a fetch already in flight, otherwise reports `config_unavailable`. |
| `closeSurvey()` | closes a visible survey (counts as dismissed unless completed). A survey that is still waiting for its delay or loading is cancelled silently: no state change, no telemetry, no callback, because it was never shown. The same holds when `reset()` or `setTrackingEnabled(false)` cancels one. |
| `pause()` / `resume()` | stops / resumes targeting; `showSurvey` still works |
| `setLocale(tag or null)` | locale override |
| `setHiddenFields(map)` | hidden-field values sent with every survey (replaces the previous map) |
| `setTrackingEnabled(bool)` | false: no network, no targeting, nothing shown; persisted |
| `reset()` | see section 3 |
| `setDisplayGuard(guard or null)` | asked when the page has reported `ready`, right before the survey becomes visible: `guard(survey, decide)`; `decide(false)` vetoes (`vetoed`) and the loaded page is discarded. No answer within 2 seconds counts as allow. Not asked for `force`. |
| `addListener(listener)` / `removeListener` | see below |

Listener callbacks (all optional, delivered on the main thread):

| Callback | Payload |
|---|---|
| `surveyShown` | `survey { id, name }`, `trigger { type, name }` |
| `surveyNotShown` | `surveyId`, `reason` (4.5) |
| `questionAnswered` | `surveyId`, `questionId`, `type`, `title`, `value` |
| `surveyCompleted` | `surveyId`, `responseId`, `answers[]` |
| `surveyDismissed` | `surveyId` |
| `surveyError` | `surveyId`, `code`, `message` |

With `logLevel: debug` the SDK logs every targeting decision with the survey id and reason, every configuration fetch and every bridge message, prefixed `[Responsly]`.

## 8. Privacy

- No advertising identifier, no device fingerprint, no location. The install id never leaves the device.
- User id, traits and hidden fields are sent only to the survey page, inside the WebView, when a survey is shown.
- The iOS SDK ships `PrivacyInfo.xcprivacy` declaring `UserDefaults` access (reason `CA92.1`) and no tracking.

## 9. Conformance fixtures

`targeting-fixtures.json`: `{ "cases": [ { "name", "config", "context", "steps": [...] } ] }`.

- `context`: `platform`, `app_id`, `locale`, `install_id`.
- Each step has `at` (ISO time used as "now"), `action`, and optionally `expect`.
- Actions: `{"type":"track","name","properties"}`, `{"type":"screen","name"}`, `{"type":"app_launch"}`, `{"type":"show","survey","force"}`, `{"type":"displayed","survey","auto"}`, `{"type":"completed","survey"}`, `{"type":"dismissed","survey"}`, `{"type":"identify","user_id","traits"}`, `{"type":"set_attributes","traits"}`, `{"type":"set_locale","locale"}`, `{"type":"pause"}`, `{"type":"resume"}`, `{"type":"set_tracking","enabled"}`, `{"type":"visible","value"}` (a survey is on screen or waiting).
- `expect`: `{"show": "<survey id>" | null, "not_shown": {"<survey id>": "<reason>"}}`. `not_shown` lists every matched survey that was not selected; when omitted it is not checked.
- The harness applies the action to the engine's state, asks the engine for a decision when the action is a trigger or `show`, and compares. It does not apply `displayed` by itself: fixtures do that with explicit steps. Delays are not simulated.
