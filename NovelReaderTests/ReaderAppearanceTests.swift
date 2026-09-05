import SwiftUI
import XCTest
@testable import NovelReader

/// What the reader's appearance has to keep straight between launches.
final class ReaderAppearanceTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A private suite, so exercising the appearance settings cannot leave the
        // simulator's real defaults changed.
        suite = "ReaderAppearanceTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// The one distinction the font default rests on: never having chosen and having
    /// chosen the system face are different answers, and only a sentinel tells them apart.
    /// Without it, a reader who deliberately left Songti would find it back on next
    /// launch, every launch, with no way to refuse it.
    func testChoosingTheSystemFaceOutlivesTheDefault() {
        let first = ReaderSettings(defaults: defaults)
        XCTAssertEqual(
            first.fontName, ReaderSettings.defaultFontName,
            "a device that has never chosen opens on the device's own Song face"
        )

        // Through a real face and back out again, so that "the reader chose the system
        // font" is a visible change even on a device with no Song face to default to.
        first.fontName = FontCatalog.chinese.first?.fontName
        first.fontName = nil
        XCTAssertEqual(
            defaults.string(forKey: "reader.fontName"), "",
            "the system face has to be written down; an absent key means never chosen"
        )

        let relaunched = ReaderSettings(defaults: defaults)
        XCTAssertNil(relaunched.fontName, "the system face is a choice, not an absence")
    }

    /// The default is what the picker will show selected, so it has to be a face the
    /// picker actually offers — a name nothing in the list matches is a picker with
    /// nothing ticked.
    func testTheDefaultFaceIsOneThePickerOffers() {
        guard let name = ReaderSettings.defaultFontName else {
            // Simulators ship without the Song faces a phone has. Nil is the honest answer
            // there — it is the system face — but it must mean the face is really absent
            // rather than that the lookup missed one the picker is happily offering.
            return XCTAssertFalse(
                FontCatalog.chinese.contains { $0.displayName.hasPrefix("Songti") },
                "a Song face the picker offers must also be the one the reader starts on"
            )
        }
        XCTAssertTrue(
            FontCatalog.chinese.contains { $0.fontName == name },
            "the default reading face must be selectable in the font picker"
        )
    }

    /// The system theme is the default a fresh install lands on, and its whole job is to
    /// be the two shipped palettes under the two system appearances.
    func testTheSystemThemeFollowsTheSystem() {
        let settings = ReaderSettings(defaults: defaults)
        XCTAssertEqual(settings.theme, .system)
        XCTAssertEqual(settings.palette(systemIsDark: false), .light)
        XCTAssertEqual(settings.palette(systemIsDark: true), .dark)
        XCTAssertNil(
            settings.forcedColorScheme,
            "the one theme with nothing to override must not override anything"
        )
    }

    /// A palette the reader mixed has to be there when they come back to it, including
    /// after the app has been closed — it is the only setting here they *made*.
    func testACustomPaletteSurvivesARelaunch() {
        let settings = ReaderSettings(defaults: defaults)
        let mixed = ReaderPalette(
            background: .colors([ReaderColor(hex: 0x101820), ReaderColor(hex: 0x30425A)]),
            foreground: ReaderColor(hex: 0xF0E6D2)
        )
        settings.theme = .custom
        settings.customPalette = mixed

        let relaunched = ReaderSettings(defaults: defaults)
        XCTAssertEqual(relaunched.customPalette, mixed)
        XCTAssertEqual(relaunched.palette(systemIsDark: false), mixed)
    }

    /// Trying the shipped palettes must not cost the reader the one they built.
    func testLookingAtAShippedPaletteKeepsTheCustomOne() {
        let settings = ReaderSettings(defaults: defaults)
        let mixed = ReaderPalette(
            background: .image("wallpaper.jpg"), foreground: ReaderColor(hex: 0xFFFFFF)
        )
        settings.customPalette = mixed
        settings.theme = .light
        XCTAssertEqual(settings.palette(systemIsDark: true), .light)
        XCTAssertEqual(settings.customPalette, mixed, "the reader's own page is still there")
    }

    /// The contract the scrolling renderer's opaque canvas rests on: it may only paint
    /// itself the page's colour when the page *is* one colour. Answer this wrongly for a
    /// gradient or a picture and the reader gets a flat rectangle over their background.
    func testOnlyASingleColourCountsAsAFlatPage() {
        XCTAssertEqual(
            ReaderBackground.colors([ReaderColor(hex: 0x121314)]).flatColor,
            ReaderColor(hex: 0x121314)
        )
        XCTAssertNil(
            ReaderBackground.colors([
                ReaderColor(hex: 0x121314), ReaderColor(hex: 0x303030),
            ]).flatColor
        )
        XCTAssertNil(ReaderBackground.image("wallpaper.jpg").flatColor)
    }

    /// Read off the text, because it is the one signal a photograph also carries. Get it
    /// wrong and the chrome floating over the page sits at the wrong contrast, and a
    /// highlight is washed out on exactly the surfaces that swallow it.
    func testDarknessIsReadOffTheText() {
        let overPhotograph = ReaderPalette(
            background: .image("wallpaper.jpg"), foreground: ReaderColor(hex: 0xEFEFEF)
        )
        XCTAssertTrue(overPhotograph.isDark)
        XCTAssertEqual(ReaderPalette.light.isDark, false)
        XCTAssertEqual(ReaderPalette.dark.isDark, true)
    }

    /// Only the ink is baked into laid-out glyphs. If the background were part of the key,
    /// dragging a gradient's colour picker would throw away every chapter on screen and
    /// lay them out again, mid-scroll.
    func testTheTextKeyIgnoresTheBackground() {
        let ink = ReaderColor(hex: 0xBFBFBF)
        let flat = ReaderPalette(background: .colors([ReaderColor(hex: 0x121314)]), foreground: ink)
        let photograph = ReaderPalette(background: .image("wallpaper.jpg"), foreground: ink)
        XCTAssertEqual(flat.textKey, photograph.textKey)
        XCTAssertNotEqual(
            flat.textKey,
            ReaderPalette(background: flat.background, foreground: ReaderColor(hex: 0x101010)).textKey
        )
    }

    /// The bridge every stored colour crosses twice — into a `ColorPicker` and back out of
    /// it. A colour that drifts here drifts a little further on every visit to the editor.
    func testAColourSurvivesTheRoundTripThroughSwiftUI() {
        let original = ReaderColor(hex: 0x3A6EA5)
        let returned = ReaderColor(original.color)
        XCTAssertEqual(returned.red, original.red, accuracy: 0.001)
        XCTAssertEqual(returned.green, original.green, accuracy: 0.001)
        XCTAssertEqual(returned.blue, original.blue, accuracy: 0.001)
    }
}
