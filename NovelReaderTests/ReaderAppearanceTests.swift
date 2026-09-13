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
        XCTAssertEqual(settings.palette(theme: .system, systemIsDark: false), .light)
        XCTAssertEqual(settings.palette(theme: .system, systemIsDark: true), .dark)
        XCTAssertNil(
            settings.forcedColorScheme(for: .system),
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
        XCTAssertEqual(relaunched.palette(theme: .custom, systemIsDark: false), mixed)
    }

    /// Trying the shipped palettes must not cost the reader the one they built.
    func testLookingAtAShippedPaletteKeepsTheCustomOne() {
        let settings = ReaderSettings(defaults: defaults)
        let mixed = ReaderPalette(
            background: .image("wallpaper.jpg"), foreground: ReaderColor(hex: 0xFFFFFF)
        )
        settings.customPalette = mixed
        settings.theme = .light
        XCTAssertEqual(settings.palette(theme: .light, systemIsDark: true), .light)
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

    // MARK: - What each medium is read in

    /// Nothing changes for a reader who never opens this: subscriptions are turned the way
    /// everything else is until they are given an answer of their own.
    func testSubscriptionsFollowTheGeneralModeUntilGivenOneOfTheirOwn() {
        let settings = ReaderSettings(defaults: defaults)
        settings.mode = .paginated

        XCTAssertNil(settings.feedOverrides.mode)
        XCTAssertEqual(settings.defaultMode(for: .feed), .paginated)

        settings.feedOverrides.mode = .scroll
        XCTAssertEqual(settings.defaultMode(for: .feed), .scroll)
        XCTAssertEqual(
            ReaderSettings(defaults: defaults).feedOverrides.mode, .scroll,
            "and it survives a launch"
        )
    }

    /// The point of the medium having its own default rather than forty per-book
    /// overrides: an article is a different shape of thing from a novel, and saying so
    /// once has to cover the subscriptions added next month too.
    func testAModeSetForSubscriptionsLeavesEverythingElseAlone() {
        let settings = ReaderSettings(defaults: defaults)
        settings.mode = .paginated

        settings.feedOverrides.mode = .scroll

        XCTAssertEqual(settings.resolvedMode(forBook: "feed|blog", kind: .feed), .scroll)
        XCTAssertEqual(settings.resolvedMode(forBook: "site|novel", kind: .novel), .paginated)
    }

    /// And the order of the three answers, which is the order a reader would say them in:
    /// this book, then this kind of reading, then what I usually do.
    func testABooksOwnAnswerOutranksItsMediums() {
        let settings = ReaderSettings(defaults: defaults)
        settings.mode = .paginated
        settings.feedOverrides.mode = .scroll

        settings.setOverrides(.init(mode: .paginated), forBook: "feed|longform")

        XCTAssertEqual(settings.resolvedMode(forBook: "feed|longform", kind: .feed), .paginated)
        XCTAssertEqual(
            settings.resolvedMode(forBook: "feed|blog", kind: .feed), .scroll,
            "the one feed that was singled out must not take the others with it"
        )
    }

    // MARK: - One book's own page turning, size and colours

    /// The default answers for every book that has not been given one, which is all of
    /// them until a reader says otherwise — this is how these settings behaved before
    /// books could disagree with them at all.
    func testABookWithNoAnswerOfItsOwnFollowsTheDefaults() {
        let settings = ReaderSettings(defaults: defaults)
        settings.mode = .paginated
        settings.fontSize = 21
        settings.theme = .dark

        XCTAssertEqual(settings.resolvedMode(forBook: "site|untouched", kind: .novel), .paginated)
        XCTAssertEqual(settings.resolvedFontSize(forBook: "site|untouched", kind: .novel), 21)
        XCTAssertEqual(settings.resolvedTheme(forBook: "site|untouched", kind: .novel), .dark)
        XCTAssertTrue(settings.overrides(forBook: "site|untouched").isEmpty)
    }

    /// One book's answer is one book's: the novel read in pages and the one beside it
    /// scrolled through are the whole request behind this.
    func testAnAnswerChosenForOneBookLeavesTheRestAlone() {
        let settings = ReaderSettings(defaults: defaults)
        settings.mode = .scroll
        settings.fontSize = 18
        settings.theme = .light

        settings.setOverrides(
            .init(mode: .paginated, fontSize: 26, theme: .dark), forBook: "site|serial"
        )

        XCTAssertEqual(settings.resolvedMode(forBook: "site|serial", kind: .novel), .paginated)
        XCTAssertEqual(settings.resolvedFontSize(forBook: "site|serial", kind: .novel), 26)
        XCTAssertEqual(settings.resolvedTheme(forBook: "site|serial", kind: .novel), .dark)

        XCTAssertEqual(settings.resolvedMode(forBook: "site|other", kind: .novel), .scroll)
        XCTAssertEqual(settings.resolvedFontSize(forBook: "site|other", kind: .novel), 18)
        XCTAssertEqual(settings.resolvedTheme(forBook: "site|other", kind: .novel), .light)
    }

    /// Each setting inherits on its own. A reader who made one book bigger did not thereby
    /// decide anything about its colours, and a later change to the default palette has to
    /// reach it like it reaches every other book.
    func testABookThatOverridesOneSettingStillFollowsTheOthers() {
        let settings = ReaderSettings(defaults: defaults)
        settings.setOverrides(.init(fontSize: 28), forBook: "site|tired-eyes")

        settings.theme = .dark

        XCTAssertEqual(settings.resolvedFontSize(forBook: "site|tired-eyes", kind: .novel), 28)
        XCTAssertEqual(settings.resolvedTheme(forBook: "site|tired-eyes", kind: .novel), .dark)
    }

    /// What the renderers are handed, and the whole reason they stopped holding
    /// `ReaderSettings`: everything about the layout is resolved for one book before it
    /// gets there, and the script — which is about the reader, not the book — is not.
    func testTheMetricsHandedToTheRenderersAreResolvedForOneBook() {
        let settings = ReaderSettings(defaults: defaults)
        settings.fontSize = 19
        settings.lineSpacing = 7
        settings.paragraphSpacing = 8
        settings.chineseScript = ChineseScript(depth: .phrases, target: .traditional)
        settings.setOverrides(
            .init(fontName: "Kaiti TC", fontSize: 28, lineSpacing: 12), forBook: "site|serial"
        )

        let own = settings.metrics(forBook: "site|serial", kind: .novel)
        XCTAssertEqual(own.fontName, "Kaiti TC")
        XCTAssertEqual(own.fontSize, 28)
        XCTAssertEqual(own.lineSpacing, 12)
        XCTAssertEqual(own.paragraphSpacing, 8, "the one it was not given still follows")
        XCTAssertEqual(own.script, settings.chineseScript, "the script is not a book's to hold")

        let other = settings.metrics(forBook: "site|other", kind: .novel)
        XCTAssertEqual(other.fontSize, 19)
        XCTAssertEqual(other.lineSpacing, 7)
    }

    /// The face needs a sentinel that the numbers beside it do not: nil already means "the
    /// system face", so it cannot also mean "no answer here". A reader who deliberately
    /// took one book off the Song face must not find it back there.
    func testOneBookCanBeSetToTheSystemFaceWhileTheRestKeepTheirs() {
        let settings = ReaderSettings(defaults: defaults)
        settings.fontName = "Songti TC"

        settings.setOverrides(.init(fontName: ""), forBook: "site|plain")

        XCTAssertNil(
            settings.resolvedFontName(forBook: "site|plain", kind: .novel),
            "the empty string is the system face, chosen"
        )
        XCTAssertEqual(settings.resolvedFontName(forBook: "site|other", kind: .novel), "Songti TC")
        XCTAssertFalse(
            settings.overrides(forBook: "site|plain").isEmpty,
            "a book set to the system face has been answered, and must not read as following"
        )
    }

    /// The claim the storage rule exists for: choosing an answer is not the same as
    /// following one, even while the two agree.
    ///
    /// `LibrarySettings.catalogDescending` stores a choice equal to its default as no
    /// entry at all, and is right to — a catalog's default is a constant per medium. These
    /// defaults are the reader's own and they can change them tomorrow, so collapsing the
    /// two would silently unpin every book that was pinned on a day the default agreed.
    func testABookPinnedToTodaysDefaultStaysPinnedWhenTheDefaultChanges() {
        let settings = ReaderSettings(defaults: defaults)
        settings.mode = .scroll
        settings.setOverrides(.init(mode: .scroll), forBook: "site|pinned")

        settings.mode = .paginated

        XCTAssertEqual(
            settings.resolvedMode(forBook: "site|pinned", kind: .novel), .scroll,
            "it was chosen, not inherited, and nothing since has unchosen it"
        )
        XCTAssertEqual(settings.resolvedMode(forBook: "site|following", kind: .novel), .paginated)
    }

    /// And the way back out: following is somewhere a book can be put back to, not a state
    /// it leaves once and for all. A book that follows in every respect has to leave no
    /// entry behind, or the store grows a row for every book ever opened.
    func testPuttingABookBackToFollowingLeavesNothingBehind() {
        let settings = ReaderSettings(defaults: defaults)
        settings.setOverrides(.init(mode: .paginated, fontSize: 28), forBook: "site|serial")

        settings.setOverrides(.init(fontSize: 28), forBook: "site|serial")
        XCTAssertEqual(
            settings.resolvedMode(forBook: "site|serial", kind: .novel), settings.mode,
            "one setting put back to following must not take the others with it"
        )
        XCTAssertEqual(settings.resolvedFontSize(forBook: "site|serial", kind: .novel), 28)

        settings.setOverrides(.init(), forBook: "site|serial")
        XCTAssertTrue(settings.overridesByBook.isEmpty)
    }

    func testABooksOwnAnswersSurviveALaunch() {
        ReaderSettings(defaults: defaults)
            .setOverrides(.init(mode: .paginated, fontSize: 28, theme: .dark), forBook: "site|s")

        let relaunched = ReaderSettings(defaults: defaults)
        XCTAssertEqual(relaunched.overrides(forBook: "site|s").mode, .paginated)
        XCTAssertEqual(relaunched.overrides(forBook: "site|s").fontSize, 28)
        XCTAssertEqual(relaunched.overrides(forBook: "site|s").theme, .dark)
    }

    /// A book removed and added again must not come back read in a way the reader never
    /// chose for it — `AppEnvironment.removeBookmark` is where this is called from.
    func testDeletingABookForgetsHowItWasRead() {
        let settings = ReaderSettings(defaults: defaults)
        settings.setOverrides(.init(mode: .paginated), forBook: "site|gone")
        settings.setOverrides(.init(mode: .paginated), forBook: "site|kept")

        settings.forgetOverrides(forBook: "site|gone")

        XCTAssertTrue(settings.overrides(forBook: "site|gone").isEmpty)
        XCTAssertEqual(settings.overrides(forBook: "site|kept").mode, .paginated)
    }
}
