import Foundation

/// What one book, or one whole shelf, may be read differently from everything else.
///
/// Split out of `ReaderSettings` because it is a different question. That type is the
/// reader's answers; this is the rule for whose answer wins — a book's own, then its
/// shelf's, then the general one.
extension ReaderSettings {
    /// The reading appearance that one book, or one whole shelf, may answer differently.
    ///
    /// Everything about how the text is laid out and turned: the mode, the page turning,
    /// the face, the size, the two spacings, the surface. What stays out is what is not
    /// about a book at all — which script the reader reads Chinese in, how a book is left,
    /// whether the screen is kept awake. Those are about the person and the device, and no
    /// book has an opinion on them.
    ///
    /// Nil per field, so a book can disagree about one of them and inherit the rest. A
    /// reader who made one book bigger has not thereby decided anything about its colours.
    struct Overrides: Codable, Equatable {
        /// Raw values rather than the enums, for `LibraryBackup.Settings`' reason: this
        /// travels in a backup file, and a case some later build renames has to degrade to
        /// "no answer here" rather than fail to decode the file it sits in.
        private var modeRaw: String?
        private var pageTurnRaw: String?
        private var themeRaw: String?
        /// Nil is "follows"; the empty string is the system face, *chosen*. The same
        /// sentinel `ReaderSettings.fontName` is written to disk with, for the same reason:
        /// one book deliberately taken off the Song face must not be handed it back because
        /// "no face" and "the system face" were stored as the same thing.
        var fontName: String?
        var fontSize: Double?
        var lineSpacing: Double?
        var paragraphSpacing: Double?

        var mode: Mode? {
            get { modeRaw.flatMap(Mode.init(rawValue:)) }
            set { modeRaw = newValue?.rawValue }
        }

        var pageTurn: PageTurn? {
            get { pageTurnRaw.flatMap(PageTurn.init(rawValue:)) }
            set { pageTurnRaw = newValue?.rawValue }
        }

        var theme: Theme? {
            get { themeRaw.flatMap(Theme.init(rawValue:)) }
            set { themeRaw = newValue?.rawValue }
        }

        /// Whether this layer says anything at all. What "follows in every respect" looks
        /// like, and what an entry is dropped for rather than stored empty.
        var isEmpty: Bool {
            modeRaw == nil && pageTurnRaw == nil && themeRaw == nil && fontName == nil
                && fontSize == nil && lineSpacing == nil && paragraphSpacing == nil
        }

        init(
            mode: Mode? = nil,
            pageTurn: PageTurn? = nil,
            fontName: String? = nil,
            fontSize: Double? = nil,
            lineSpacing: Double? = nil,
            paragraphSpacing: Double? = nil,
            theme: Theme? = nil
        ) {
            self.modeRaw = mode?.rawValue
            self.pageTurnRaw = pageTurn?.rawValue
            self.themeRaw = theme?.rawValue
            self.fontName = fontName
            self.fontSize = fontSize
            self.lineSpacing = lineSpacing
            self.paragraphSpacing = paragraphSpacing
        }
    }

    // MARK: - Whose answer is being asked for

    /// Which set of answers a question is being put to.
    ///
    /// The layering as a value, so that the walk down it exists once. The panel now edits
    /// all three, and each control asks three things of its layer — what does it show, what
    /// would it show if it followed, is it following — which written out field by field and
    /// layer by layer is one rule copied twenty-one times.
    enum Layer: Hashable {
        case general
        case shelf(SiteRule.Kind)
        case book(id: String, kind: SiteRule.Kind)

        /// The layer this one follows where it says nothing. The general answers follow
        /// nobody, which is what makes them the general answers.
        var above: Layer {
            switch self {
            case .general, .shelf: return .general
            case .book(_, let kind): return .shelf(kind)
            }
        }

        /// What is being read, where that is known. Nil for the general answers, which are
        /// about the reader rather than about any one thing they read.
        var kind: SiteRule.Kind? {
            switch self {
            case .general: return nil
            case .shelf(let kind), .book(_, let kind): return kind
            }
        }
    }

    /// What a layer is read with: its own answer where it has one, otherwise the answer of
    /// the nearest layer above it that does.
    ///
    /// Generic over the field, which is the point — this is the resolution order, and it is
    /// the same order for every setting here. `general` names the same field where it is no
    /// longer optional, and being no longer optional is what makes it the bottom.
    func value<V>(
        _ field: KeyPath<Overrides, V?>,
        of layer: Layer,
        general: KeyPath<ReaderSettings, V>
    ) -> V {
        guard case .general = layer else {
            return overrides(of: layer)[keyPath: field]
                ?? value(field, of: layer.above, general: general)
        }
        return self[keyPath: general]
    }

    /// The face, which cannot go through `value`: nil is an answer here rather than an
    /// absence — see `Overrides.fontName`.
    func fontName(of layer: Layer) -> String? {
        guard case .general = layer else {
            guard let own = overrides(of: layer).fontName else { return fontName(of: layer.above) }
            return Self.face(own)
        }
        return fontName
    }

    /// What this layer was explicitly given and nothing more — the layer a panel edits.
    /// Empty for one that follows in every respect, which is most of them.
    ///
    /// The overrides rather than the resolved values, because a resolved value cannot say
    /// "following", and following is a state the panel has to show and to return to. The
    /// general answers are empty here too: they are the bottom of the chain, not a layer
    /// sitting on it.
    func overrides(of layer: Layer) -> Overrides {
        switch layer {
        case .general: return Overrides()
        case .shelf(let kind): return overrides(forKind: kind)
        case .book(let id, _): return overrides(forBook: id)
        }
    }

    func setOverrides(_ overrides: Overrides, of layer: Layer) {
        switch layer {
        case .general:
            // A panel editing the general answers writes the properties directly. Arriving
            // here means a control was pointed at the wrong layer, and the write would go
            // nowhere at all.
            assertionFailure("the general answers are not overrides of anything")
        case .shelf(let kind): setOverrides(overrides, forKind: kind)
        case .book(let id, _): setOverrides(overrides, forBook: id)
        }
    }

    // MARK: - What one book is read with

    /// How this book is read: its own answer where it has one, its shelf's otherwise, and
    /// the general one under that. The names the renderers ask by.
    func resolvedMode(forBook bookId: String, kind: SiteRule.Kind) -> Mode {
        value(\.mode, of: .book(id: bookId, kind: kind), general: \.mode)
    }

    func resolvedFontName(forBook bookId: String, kind: SiteRule.Kind) -> String? {
        fontName(of: .book(id: bookId, kind: kind))
    }

    func resolvedFontSize(forBook bookId: String, kind: SiteRule.Kind) -> Double {
        value(\.fontSize, of: .book(id: bookId, kind: kind), general: \.fontSize)
    }

    func resolvedLineSpacing(forBook bookId: String, kind: SiteRule.Kind) -> Double {
        value(\.lineSpacing, of: .book(id: bookId, kind: kind), general: \.lineSpacing)
    }

    func resolvedParagraphSpacing(forBook bookId: String, kind: SiteRule.Kind) -> Double {
        value(\.paragraphSpacing, of: .book(id: bookId, kind: kind), general: \.paragraphSpacing)
    }

    func resolvedPageTurn(forBook bookId: String, kind: SiteRule.Kind) -> PageTurn {
        value(\.pageTurn, of: .book(id: bookId, kind: kind), general: \.pageTurn)
    }

    func resolvedTheme(forBook bookId: String, kind: SiteRule.Kind) -> Theme {
        value(\.theme, of: .book(id: bookId, kind: kind), general: \.theme)
    }

    /// What a book's text is laid out with, resolved once so that the renderers never have
    /// to know a book has layers — see `ReadingMetrics`.
    func metrics(forBook bookId: String, kind: SiteRule.Kind) -> ReadingMetrics {
        ReadingMetrics(
            fontName: resolvedFontName(forBook: bookId, kind: kind),
            fontSize: resolvedFontSize(forBook: bookId, kind: kind),
            lineSpacing: resolvedLineSpacing(forBook: bookId, kind: kind),
            paragraphSpacing: resolvedParagraphSpacing(forBook: bookId, kind: kind),
            script: chineseScript
        )
    }

    // MARK: - What a shelf is read with

    /// What a shelf is read with before any book on it disagrees — and what a book's own
    /// controls name as the thing they are following.
    ///
    /// Comics are answered for every field, which is neither wrong nor mostly used: nothing
    /// draws a comic through the type settings. A `switch` that refused them would be a
    /// crash waiting for the day one does.
    func defaultMode(for kind: SiteRule.Kind) -> Mode {
        value(\.mode, of: .shelf(kind), general: \.mode)
    }

    func defaultFontName(for kind: SiteRule.Kind) -> String? {
        fontName(of: .shelf(kind))
    }

    func defaultFontSize(for kind: SiteRule.Kind) -> Double {
        value(\.fontSize, of: .shelf(kind), general: \.fontSize)
    }

    func defaultLineSpacing(for kind: SiteRule.Kind) -> Double {
        value(\.lineSpacing, of: .shelf(kind), general: \.lineSpacing)
    }

    func defaultParagraphSpacing(for kind: SiteRule.Kind) -> Double {
        value(\.paragraphSpacing, of: .shelf(kind), general: \.paragraphSpacing)
    }

    func defaultPageTurn(for kind: SiteRule.Kind) -> PageTurn {
        value(\.pageTurn, of: .shelf(kind), general: \.pageTurn)
    }

    func defaultTheme(for kind: SiteRule.Kind) -> Theme {
        value(\.theme, of: .shelf(kind), general: \.theme)
    }

    // MARK: - Reading and writing one stored layer

    /// What this book was explicitly given, and nothing more.
    func overrides(forBook bookId: String) -> Overrides {
        overridesByBook[bookId] ?? Overrides()
    }

    /// What a whole shelf was explicitly given. Every shelf has a layer now, where only
    /// subscriptions used to: a shelf is the unit a reader thinks in — "articles in pages,
    /// comics tapped" — and singling one medium out was an accident of which one needed it
    /// first.
    func overrides(forKind kind: SiteRule.Kind) -> Overrides {
        overridesByKind[kind.rawValue] ?? Overrides()
    }

    /// A stored face read back out: the empty string is the system face.
    private static func face(_ stored: String) -> String? { stored.isEmpty ? nil : stored }
}
