import ResponslySDK
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var log: EventLog

    @AppStorage("sdkKey") private var sdkKey = "rsk_demo"
    @AppStorage("apiHost") private var apiHost = "https://api.responsly.com"
    @AppStorage("surveyId") private var surveyId = ""
    @State private var force = false

    var body: some View {
        Group {
            if UserDefaults.standard.bool(forKey: "demoScreen") {
                DemoScreen()
            } else {
                controls
            }
        }
        .task { await runScript() }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            Form {
                Section("SDK") {
                    TextField("SDK key", text: $sdkKey)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    TextField("API host", text: $apiHost)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Button("Initialize", action: initialize)
                }

                Section("User") {
                    Button("Identify demo user", action: identify)
                    Button("Reset", role: .destructive) {
                        Responsly.shared.reset()
                        log.add("reset()")
                    }
                }

                Section("Triggers") {
                    Button("Track purchase_completed") {
                        Responsly.shared.track("purchase_completed", properties: ["value": 129, "currency": "EUR"])
                        log.add("track(\"purchase_completed\", value: 129, currency: EUR)")
                    }
                    Button("Screen Checkout") {
                        Responsly.shared.screen("Checkout")
                        log.add("screen(\"Checkout\")")
                    }
                }

                Section("Survey") {
                    TextField("Survey id", text: $surveyId)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Toggle("Force", isOn: $force)
                    Button("Show survey", action: showSurvey)
                        .disabled(trimmed(surveyId).isEmpty)
                    Button("Close survey") {
                        Responsly.shared.closeSurvey()
                        log.add("closeSurvey()")
                    }
                }

                Section("Targeting") {
                    Button("Pause") {
                        Responsly.shared.pause()
                        log.add("pause()")
                    }
                    Button("Resume") {
                        Responsly.shared.resume()
                        log.add("resume()")
                    }
                }
            }

            Divider()
            LogView()
                .frame(height: 220)
        }
    }

    /// Scripted run for automated checks and screenshots: launch with `-autoRun initialize,identify,track` (also
    /// `screen`, `show`, `pause`, `resume`, `close`, `reset`); steps run two seconds apart. The key,
    /// host and survey id can be given the same way: `-sdkKey rsk_… -apiHost https://… -surveyId …`.
    private func runScript() async {
        guard let script = UserDefaults.standard.string(forKey: "autoRun") else { return }

        for step in script.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch step {
            case "initialize": initialize()
            case "identify": identify()
            case "track":
                Responsly.shared.track("purchase_completed", properties: ["value": 49.9])
                log.add("track(\"purchase_completed\", value: 49.9)")
            case "screen":
                Responsly.shared.screen("Checkout")
                log.add("screen(\"Checkout\")")
            case "show": showSurvey()
            case "pause": Responsly.shared.pause()
            case "resume": Responsly.shared.resume()
            case "close": Responsly.shared.closeSurvey()
            case "reset": Responsly.shared.reset()
            default: log.add("autoRun: unknown step \"\(step)\"")
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func trimmed(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func initialize() {
        let key = trimmed(sdkKey)
        guard let host = URL(string: trimmed(apiHost)), host.scheme != nil, host.host != nil else {
            log.add("initialize: \"\(apiHost)\" is not a valid API host")
            return
        }
        Responsly.shared.initialize(sdkKey: key, options: ResponslyOptions(apiHost: host, logLevel: .debug))
        log.add("initialize(sdkKey: \(key), apiHost: \(host.absoluteString), logLevel: debug)")
    }

    private func identify() {
        Responsly.shared.identify(userId: "demo-user-1", traits: [
            "plan": "pro",
            "seats": 5,
            "beta": true,
            "signed_up": .date(Date()),
        ])
        log.add("identify(\"demo-user-1\", plan: pro, seats: 5, beta: true, signed_up: now)")
    }

    private func showSurvey() {
        let id = trimmed(surveyId)
        Responsly.shared.showSurvey(id, options: ResponslyShowOptions(force: force))
        log.add("showSurvey(\"\(id)\", force: \(force))")
    }
}

/// The scrolling log: one line per SDK call and per listener callback.
private struct LogView: View {
    @EnvironmentObject private var log: EventLog

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log")
                    .font(.footnote.weight(.semibold))
                Spacer()
                Button("Clear") { log.clear() }
                    .font(.footnote)
                    .disabled(log.entries.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(log.entries) { entry in
                            Text("\(LogView.timeFormatter.string(from: entry.time))  \(entry.text)")
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .onChange(of: log.entries.last?.id) { last in
                    guard let last = last else { return }
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .background(Color(.secondarySystemBackground))
    }
}

/// A plain order-confirmation screen shown instead of the controls when the app is launched with
/// `-demoScreen YES`: something app-like to have behind a survey in screenshots.
private struct DemoScreen: View {
    private let items = [("Trail running shoes", "$129.00"), ("Merino socks, 2 pairs", "$24.00"), ("Shipping", "Free")]

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 52))
                            .foregroundColor(.green)
                        Text("Order confirmed")
                            .font(.title2.weight(.semibold))
                        Text("Arriving Thursday")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                Section("Order #A-77") {
                    ForEach(items, id: \.0) { item in
                        HStack {
                            Text(item.0)
                            Spacer()
                            Text(item.1).foregroundColor(.secondary)
                        }
                    }
                    HStack {
                        Text("Total").fontWeight(.semibold)
                        Spacer()
                        Text("$153.00").fontWeight(.semibold)
                    }
                }
                Section {
                    Button("Track order") {}
                    Button("Continue shopping") {}
                }
            }
            .navigationTitle("Acme")
        }
        .navigationViewStyle(.stack)
    }
}
