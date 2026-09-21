import AppIntents
import Foundation

/// Opening the book the reader was last in, from outside the app.
///
/// The one thing a long-form reader does every single time they pick up the phone, and
/// until now it took a launch, a glance at the history, and a tap. From here it is the
/// Action Button, a Shortcut, or a tap on a Focus automation — and it lands on the
/// sentence they stopped at rather than on the shelf.
///
/// Deliberately parameterless. "Which book" is a question the app can already answer
/// better than the reader can phrase it: the history is ordered, and the top openable
/// entry *is* what continuing means. An intent that asked would be an intent nobody
/// could use from a button.
struct ContinueReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.continueReading"
    // Spelled out rather than left as a bare literal: `IntentDescription` takes a string
    // literal of its own, and that path puts the key itself in front of the reader
    // instead of looking it up.
    static let description = IntentDescription(
        LocalizedStringResource("intent.continueReading.description")
    )

    /// The whole point: the reader is asking to read, and reading happens on screen.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Two launches, one intent. A running app has the history loaded and can be aimed
        // at a book immediately; a cold one has no object graph yet — the same condition
        // `AppDelegate` handles for a background download, and for the same reason: no
        // scene has built one. So the ask is written down and `RootView` picks it up.
        //
        // Only written down when it could not be honoured, because a flag left behind
        // after a successful hand-off would open a book on the *next* launch, which the
        // reader did not ask for and could not explain.
        if AppEnvironment.live?.continueReading(deferred: false) != true {
            ContinueReadingRequest.raise()
        }
        return .result()
    }
}

/// A "continue reading" that arrived before there was anywhere to put it.
///
/// `UserDefaults` rather than memory because the two sides may be in different launches
/// of the process: the intent can run against a cold app, and the thing that honours it
/// is the first view tree to come up afterwards.
enum ContinueReadingRequest {
    private static let key = "reader.continueRequested"

    static func raise(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    /// Reads the ask and clears it in one move.
    ///
    /// Cleared even when nothing can be done with it — a reader with no history who
    /// pressed the button once must not find a book opening at every launch from then on.
    static func take(from defaults: UserDefaults = .standard) -> Bool {
        defer { defaults.removeObject(forKey: key) }
        return defaults.bool(forKey: key)
    }
}
