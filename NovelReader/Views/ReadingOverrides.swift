import Foundation

/// What one book, or one whole medium, may be read differently from everything else.
///
/// Split out of `ReaderSettings` because it is a different question. That type is the
/// reader's answers; this is the rule for whose answer wins — a book's own, then its
/// medium's, then the general one.
extension ReaderSettings {
    /// The reading appearance that one book, or one whole medium, may answer differently.
    ///
    /// Everything about how the text is laid out and turned: the mode, the face, the size,
    /// the two spacings, the surface. What stays out is what is not about a book at all —
    /// which script the reader reads Chinese in, whether a tap turns the page, whether the
    /// screen is kept awake. Those are about the person and the device, and no book has an
    /// opinion on them.
    ///
    /// Nil per field, so a book can disagree about one of them and inherit the rest. A
    /// reader who made one book bigger has not thereby decided anything about its colours.
    struct Overrides: Codable, Equatable {
        /// Raw values rather than the enums, for `LibraryBackup.Settings`' reason: this
        /// travels in a backup file, and a case some later build renames has to degrade to
        /// "no answer here" rather than fail to decode the file it sits in.
        private var modeRaw: String?
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

        var theme: Theme? {
            get { themeRaw.flatMap(Theme.init(rawValue:)) }
            set { themeRaw = newValue?.rawValue }
        }

        /// Whether this layer says anything at all. What "follows in every respect" looks
        /// like, and what an entry is dropped for rather than stored empty.
        var isEmpty: Bool {
            modeRaw == nil && themeRaw == nil && fontName == nil
                && fontSize == nil && lineSpacing == nil && paragraphSpacing == nil
        }

        init(
            mode: Mode? = nil,
            fontName: String? = nil,
            fontSize: Double? = nil,
            lineSpacing: Double? = nil,
            paragraphSpacing: Double? = nil,
            theme: Theme? = nil
        ) {
            self.modeRaw = mode?.rawValue
            self.themeRaw = theme?.rawValue
            self.fontName = fontName
            self.fontSize = fontSize
            self.lineSpacing = lineSpacing
            self.paragraphSpacing = paragraphSpacing
        }
    }

    // MARK: - What one book is read with

    /// How this book is read: its own answer where it has one, its medium's otherwise.
    ///
    /// The resolution in the order a reader would say it out loud — this book, then this
    /// kind of reading, then what I usually do. The rest take the same walk down the same
    /// two layers; only the field and the answer at the bottom differ.
    func resolvedMode(forBook bookId: String, kind: SiteRule.Kind) -> Mode {
        overrides(forBook: bookId).mode ?? defaultMode(for: kind)
    }

    /// The one that cannot be written as a `??` chain, because nil is an answer here and
    /// not only an absence — see `Overrides.fontName`.
    func resolvedFontName(forBook bookId: String, kind: SiteRule.Kind) -> String? {
        guard let own = overrides(forBook: bookId).fontName else {
            return defaultFontName(for: kind)
        }
        return Self.face(own)
    }

    func resolvedFontSize(forBook bookId: String, kind: SiteRule.Kind) -> Double {
        overrides(forBook: bookId).fontSize ?? defaultFontSize(for: kind)
    }

    func resolvedLineSpacing(forBook bookId: String, kind: SiteRule.Kind) -> Double {
        overrides(forBook: bookId).lineSpacing ?? defaultLineSpacing(for: kind)
    }

    func resolvedParagraphSpacing(forBook bookId: String, kind: SiteRule.Kind) -> Double {
        overrides(forBook: bookId).paragraphSpacing ?? defaultParagraphSpacing(for: kind)
    }

    func resolvedTheme(forBook bookId: String, kind: SiteRule.Kind) -> Theme {
        overrides(forBook: bookId).theme ?? defaultTheme(for: kind)
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

    // MARK: - What a medium is read with

    /// What a medium is read with before any book of it disagrees — and what the reader's
    /// own panel names as the thing a book is following.
    ///
    /// Comics are answered too, out of the general defaults, which is neither wrong nor
    /// ever used: nothing draws a comic through these settings. A `switch` that refused
    /// them would be a crash waiting for the day one does.
    func defaultMode(for kind: SiteRule.Kind) -> Mode {
        mediumOverrides(for: kind).mode ?? mode
    }

    func defaultFontName(for kind: SiteRule.Kind) -> String? {
        guard let own = mediumOverrides(for: kind).fontName else { return fontName }
        return Self.face(own)
    }

    func defaultFontSize(for kind: SiteRule.Kind) -> Double {
        mediumOverrides(for: kind).fontSize ?? fontSize
    }

    func defaultLineSpacing(for kind: SiteRule.Kind) -> Double {
        mediumOverrides(for: kind).lineSpacing ?? lineSpacing
    }

    func defaultParagraphSpacing(for kind: SiteRule.Kind) -> Double {
        mediumOverrides(for: kind).paragraphSpacing ?? paragraphSpacing
    }

    func defaultTheme(for kind: SiteRule.Kind) -> Theme {
        mediumOverrides(for: kind).theme ?? theme
    }

    // MARK: - Reading and writing a layer

    /// What this book was explicitly given and nothing more — the layer the reader's own
    /// panel edits. Empty for a book that follows in every respect, which is most of them.
    ///
    /// The overrides rather than the resolved values, because a resolved value cannot say
    /// "following", and following is a state the panel has to show and to return to.
    func overrides(forBook bookId: String) -> Overrides {
        overridesByBook[bookId] ?? Overrides()
    }

    private func mediumOverrides(for kind: SiteRule.Kind) -> Overrides {
        kind == .feed ? feedOverrides : Overrides()
    }

    /// A stored face read back out: the empty string is the system face.
    private static func face(_ stored: String) -> String? { stored.isEmpty ? nil : stored }
}
