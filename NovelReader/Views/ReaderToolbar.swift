import Foundation

/// One control in a reader's bottom bar, as something the reader can move and fold away.
///
/// Both bars are described by one type. The text reader and the comic reader draw
/// different subsets — see `appears(in:)` — but a shelf is a `SiteRule.Kind` and a reader
/// arranging the comic shelf is doing the same thing as one arranging the novel shelf. Two
/// enums would be two default orders to keep in step for the five controls they share.
///
/// Raw strings rather than an `Int`, because an arrangement travels in `LibraryBackup`: a
/// case some later build renames has to come back as "a button this version does not know"
/// and be dropped, rather than fail to decode the arrangement it sits in.
///
/// The order of the cases is the order the bars were designed in, and it is what a reader
/// who has never opened the editor sees.
enum ReaderButton: String, CaseIterable, Identifiable {
    case back
    case catalog
    case bookmark
    case previousChapter
    case nextChapter
    /// Re-reading a subscribed article from its page, with the browser on the long press.
    case original
    case autoScroll
    case speech
    case settings

    var id: String { rawValue }

    /// Whether a shelf has this control at all.
    ///
    /// Not the same question as whether it is on screen right now: the back button exists
    /// only where the reader is not leaving by the edge swipe, and the article control only
    /// where the article being read has an original to go back to. Those are answered where
    /// the bar is drawn, because they change while the reader is standing there. This one
    /// is answered here because it cannot: no comic will ever have a sentence to read out.
    func appears(in kind: SiteRule.Kind) -> Bool {
        switch self {
        // A bookmark is a text anchor and there is nothing in a comic to read aloud — see
        // `ComicControlBar`, which never offered either.
        case .bookmark, .speech: return kind != .comic
        // Only a subscription has a page the text came from.
        case .original: return kind == .feed
        default: return true
        }
    }

    /// The glyph the editor lists this control under: the bar's own, in the state it
    /// spends most of its time in. The bars draw the other state themselves — a bookmark
    /// is filled on a saved page and a voice that is speaking says so.
    var icon: String {
        switch self {
        case .back: return "chevron.left"
        case .catalog: return "list.bullet"
        case .bookmark: return "bookmark"
        case .previousChapter: return "arrow.up.to.line"
        case .nextChapter: return "arrow.down.to.line"
        case .original: return "arrow.clockwise"
        case .autoScroll: return "play.circle"
        case .speech: return "headphones.circle"
        case .settings: return "textformat.size"
        }
    }

    /// A resource rather than a key, for `ReaderSettings.Theme.nameKey`'s reason.
    var nameKey: LocalizedStringResource {
        switch self {
        case .back: return "common.back"
        case .catalog: return "reader.catalog"
        case .bookmark: return "reader.bookmark.add"
        case .previousChapter: return "reader.previousChapter"
        case .nextChapter: return "reader.nextChapter"
        case .original: return "reader.fetchFullText"
        case .autoScroll: return "reader.autoScroll.start"
        case .speech: return "reader.speech.start"
        case .settings: return "reader.settings"
        }
    }

    /// When a control that is not always there appears, for the editor to say underneath
    /// it. Nil for the ones that are always on the bar of a shelf that has them.
    ///
    /// Without this the editor is a list of switches, two of which do nothing that the
    /// reader can see — and a setting that looks broken is worse than one that is missing.
    var whenKey: LocalizedStringResource? {
        switch self {
        case .back: return "reader.toolbar.when.back"
        case .original: return "reader.toolbar.when.original"
        default: return nil
        }
    }
}

/// How one reader arranged a bottom bar: what order the controls are in, and which of them
/// are folded away behind the last button.
///
/// Stored as what the reader *said* rather than as the finished bar, which is what lets an
/// arrangement outlive the version it was made in. A build that adds a control finds it
/// missing from `order` and puts it where it was designed to sit; a build that removes one
/// finds a name it does not know and drops it. Neither case needs the reader to arrange
/// their bar again, and neither can leave a control with no way to reach it.
struct ReaderToolbarLayout: Codable, Equatable {
    /// The controls this reader put in an order, first to last. Folded ones are in here
    /// too, in the place they were left — which is the order they are listed in behind the
    /// last button.
    private var order: [String]
    /// The ones folded away.
    ///
    /// Named rather than implied by their absence from `order`, because absence already
    /// means something else here: a control this arrangement has never heard of.
    private var folded: [String]

    /// Everything in the order it was designed in, nothing folded. What a reader who has
    /// never opened the editor is reading with.
    static let standard = ReaderToolbarLayout()

    init(order: [ReaderButton] = [], folded: [ReaderButton] = []) {
        self.order = order.map(\.rawValue)
        self.folded = folded.map(\.rawValue)
    }

    /// Whether this arrangement says anything at all — what an override is dropped for
    /// rather than stored empty, and what "follows the shelf" looks like.
    var isEmpty: Bool { order.isEmpty && folded.isEmpty }

    func isFolded(_ button: ReaderButton) -> Bool { folded.contains(button.rawValue) }

    /// Every control a layer's editor lists, in this arrangement's order.
    ///
    /// - Parameter kind: which shelf. Nil for the general answers, which are not about any
    ///   one shelf: they are one order that each shelf takes its own subset of, so the
    ///   editor there lists every control there is.
    func arrangement(for kind: SiteRule.Kind?) -> [ReaderButton] {
        let available = kind.map { shelf in
            ReaderButton.allCases.filter { $0.appears(in: shelf) }
        } ?? ReaderButton.allCases
        var arranged = order
            .compactMap(ReaderButton.init(rawValue:))
            .filter(available.contains)
        // Controls this reader never arranged — the ones a later version added — go where
        // they were designed to sit rather than on the end. A new "next chapter" landing
        // after the settings button would be in the one place nobody looks for it.
        for button in available where !arranged.contains(button) {
            let after = available.prefix { $0 != button }.last { arranged.contains($0) }
            let place = after.flatMap { arranged.firstIndex(of: $0).map { $0 + 1 } } ?? 0
            arranged.insert(button, at: place)
        }
        return arranged
    }

    /// The bar as it is drawn: what sits on it, and what is folded behind its last button.
    func resolve(for kind: SiteRule.Kind) -> (bar: [ReaderButton], folded: [ReaderButton]) {
        let arranged = arrangement(for: kind)
        return (arranged.filter { !isFolded($0) }, arranged.filter(isFolded))
    }
}
