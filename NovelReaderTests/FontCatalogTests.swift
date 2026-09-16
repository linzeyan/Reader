import UIKit
import XCTest
@testable import NovelReader

/// What the font list has to keep straight about a face the reader installed themselves.
///
/// None of these can be end-to-end here: the case they are about is a font that exists on
/// a phone and on no simulator, and the panel that reaches one runs out of process. What is
/// testable is the bookkeeping around it — which is where the damage was, because a face
/// that cannot be resolved *yet* used to be indistinguishable from one that is gone.
final class FontCatalogTests: XCTestCase {
    /// A name no device here has installed, which is the whole point: this is the shape of
    /// a face that exists on the reader's phone and in nothing this suite runs on.
    private let installed = "Installed-Face"
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suite = "FontCatalogTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try XCTSkipUnless(
            UIFont(name: installed, size: 16) == nil,
            "these rest on this name being unresolvable"
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// The trap a face picked out of the system panel walks into on the next launch.
    ///
    /// Access to an installed face is granted per process, so at the moment the settings
    /// load the stored name resolves to nothing — indistinguishable, to `UIFont(name:)`,
    /// from a font that has been uninstalled. Dropping it there does not merely forget the
    /// choice: it writes the empty string back, which is "the system face, chosen", and the
    /// reader's face is gone for good on the first launch after they picked it.
    func testAPickedFaceOutlivesALaunchThatCannotYetResolveIt() {
        defaults.set([installed], forKey: "reader.installedFaces")
        defaults.set(installed, forKey: "reader.fontName")

        let relaunched = ReaderSettings(defaults: defaults)

        XCTAssertEqual(
            relaunched.fontName, installed,
            "a face the reader picked from the panel is theirs until they say otherwise"
        )
        XCTAssertEqual(
            defaults.string(forKey: "reader.fontName"), installed,
            "and it must still be on disk: the choice is lost the moment this is rewritten"
        )
    }

    /// The other half of that rule, which is the behaviour that was there before: a name
    /// nobody picked and nothing can draw is a setting left behind by a font that went away
    /// with the app that installed it.
    func testAFaceNothingCanDrawAndNobodyPickedIsStillDropped() {
        defaults.set(installed, forKey: "reader.fontName")

        XCTAssertNil(
            ReaderSettings(defaults: defaults).fontName,
            "a name with no face behind it draws as the system one anyway"
        )
    }

    /// The panel offers every font on the device, including the ones this app already
    /// lists. Picking one of those must not double the row it was picked from — a picker
    /// holding two identical tags cannot show which of them is selected.
    func testAFaceTheDeviceAlreadyOffersIsNotListedTwice() throws {
        let known = try XCTUnwrap(FontCatalog.chinese.first?.fontName)
        let settings = ReaderSettings(defaults: defaults)

        XCTAssertTrue(settings.remember(face: known))

        XCTAssertEqual(
            settings.faces.filter { $0.fontName == known }.count, 1,
            "a face the device came with is offered once, however it was reached"
        )
    }

    /// Nothing is written down on the strength of a name alone. A face that will not
    /// resolve here is one the page cannot draw either, and a row promising it would draw
    /// the system face under another face's name.
    func testANameThisProcessCannotDrawWithIsRefused() {
        let settings = ReaderSettings(defaults: defaults)

        XCTAssertFalse(settings.remember(face: installed))
        XCTAssertTrue(settings.installedFaces.isEmpty)
    }

    /// A face uninstalled between two launches — see `InstalledFonts.restore(into:)`. The
    /// reader is already reading in the system face by then; what this stops is a picker
    /// that goes on offering a row nothing can draw, and goes on showing it ticked.
    func testAFaceThatLeftTheDeviceLeavesTheListAndTheChoice() throws {
        let known = try XCTUnwrap(FontCatalog.chinese.first?.fontName)
        let settings = ReaderSettings(defaults: defaults)
        settings.remember(face: known)
        settings.fontName = known

        settings.forget(faces: [known])

        XCTAssertTrue(settings.installedFaces.isEmpty)
        XCTAssertNil(settings.fontName, "a reader is not left pointed at a face that is gone")
    }
}
