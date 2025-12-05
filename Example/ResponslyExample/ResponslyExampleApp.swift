import ResponslySDK
import SwiftUI

@main
struct ResponslyExampleApp: App {
    @StateObject private var log = EventLog()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(log)
        }
    }
}

/// Collects every listener callback (and the calls made from the buttons) for the on-screen log.
@MainActor
final class EventLog: ObservableObject, ResponslyListener {
    struct Entry: Identifiable {
        let id: Int
        let time: Date
        let text: String
    }

    @Published private(set) var entries: [Entry] = []
    private var nextId = 0
    private var token: ResponslyListenerToken?

    init() {
        // Registered before `initialize`, so nothing is missed.
        token = Responsly.shared.addListener(self)
    }

    func add(_ text: String) {
        entries.append(Entry(id: nextId, time: Date(), text: text))
        nextId += 1
        if entries.count > 500 {
            entries.removeFirst(entries.count - 500)
        }
    }

    func clear() {
        entries.removeAll()
    }

    // MARK: - ResponslyListener

    func surveyShown(_ event: ResponslySurveyShownEvent) {
        add("surveyShown " + EventLog.json(event.toDictionary()))
    }

    func surveyNotShown(_ event: ResponslySurveyNotShownEvent) {
        add("surveyNotShown " + EventLog.json(event.toDictionary()))
    }

    func questionAnswered(_ event: ResponslyQuestionAnsweredEvent) {
        add("questionAnswered " + EventLog.json(event.toDictionary()))
    }

    func surveyCompleted(_ event: ResponslySurveyCompletedEvent) {
        add("surveyCompleted " + EventLog.json(event.toDictionary()))
    }

    func surveyDismissed(_ event: ResponslySurveyDismissedEvent) {
        add("surveyDismissed " + EventLog.json(event.toDictionary()))
    }

    func surveyError(_ event: ResponslySurveyErrorEvent) {
        add("surveyError " + EventLog.json(event.toDictionary()))
    }

    private static func json(_ dictionary: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "\(dictionary)" }
        return String(decoding: data, as: UTF8.self)
    }
}
