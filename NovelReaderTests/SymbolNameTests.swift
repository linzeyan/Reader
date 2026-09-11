import UIKit
import XCTest
@testable import NovelReader

/// The system icons this app names, checked against the system.
///
/// SF Symbol names are strings the compiler never looks at. A typo is not a build failure
/// and not a crash — the control simply draws nothing, which on a swipe action means a
/// coloured rectangle with a label and no icon, and on a menu row means a missing column
/// that pulls every other row out of line. The only way to find it is to look at it, or
/// this.
///
/// Not every symbol in the app: the ones a reader reaches through a feed, which is where
/// they have most recently moved. `envelope.open` and `envelope.badge` are Mail's own
/// icons for exactly these two actions, which is why they were chosen over a checkmark —
/// and being Apple's choice for the same job is worth nothing if the name is wrong.
final class SymbolNameTests: XCTestCase {
    private static let named = [
        // Marking articles read and unread: the catalog swipe, the shelf swipe, and the
        // two menus that offer it for a whole subscription.
        "envelope.open",
        "envelope.badge",
        // The rest of a subscription's own controls.
        "link",
        "ellipsis.circle",
        "arrow.clockwise",
        "checkmark.circle.fill",
        "exclamationmark.circle.fill",
        "circle.dotted",
        "square.and.arrow.down",
        "square.and.arrow.up",
        "arrow.down.circle.fill",
        "safari",
    ]

    func testEverySymbolThisAppAsksForExists() {
        for name in Self.named {
            XCTAssertNotNil(
                UIImage(systemName: name),
                "\(name) is not a symbol on this system, so it draws as nothing"
            )
        }
    }
}
