import SwiftUI

/// What the shelf, the search and the sources list are currently about.
///
/// `SiteRule.Kind` itself rather than a second enum beside it, for the reason
/// `Book.kind` gives: the answer comes from the rule a book was added through, and
/// two spellings of the same two words is how a book ends up on the wrong shelf.
/// The alias names the *role* — a shelf mode is a question about this session, not a
/// field of a rule file — without introducing a type that would have to be converted
/// back at every `book.kind == mode`.
typealias MediaMode = SiteRule.Kind

extension MediaMode: Identifiable {
    var id: String { rawValue }

    var nameKey: LocalizedStringKey {
        switch self {
        case .novel: return "media.novel"
        case .comic: return "media.comic"
        case .feed: return "media.feed"
        }
    }

    /// Whether this medium is read through installed rule files.
    ///
    /// False for exactly one mode, and every screen that offers to add something has to
    /// ask: a novel or a comic address is useless without a rule that reads that site,
    /// while a feed address is complete on its own. Screens that gate their "add" button
    /// on having a source would otherwise gate the feed shelf on rules it never uses.
    var needsRules: Bool { self != .feed }

    /// What a screen says when this medium has no sources installed, and where to get
    /// one. On the shared type because two screens ask — the shelf and the search — and
    /// one of them answering "尚未加入來源" while the other says "尚未加入漫畫來源"
    /// would read as two different problems with two different fixes.
    /// Never asked of `.feed`, which has no sources to be missing — `needsRules` is the
    /// guard, and the empty feed shelf says "subscribe to something" instead.
    var noSourcesTitleKey: LocalizedStringKey {
        switch self {
        case .novel: return "library.empty.title"
        case .comic: return "library.empty.comic.title"
        case .feed: return "library.empty.feed.title"
        }
    }

    var noSourcesHintKey: LocalizedStringKey {
        switch self {
        case .novel: return "library.empty.needSource"
        case .comic: return "library.empty.comic.needSource"
        case .feed: return "library.empty.feed.hint"
        }
    }

    /// Neither of these is the shelf tab's own `books.vertical`. The two sit next to
    /// each other in a control the width of a thumbnail, so what matters is that they
    /// are distinguishable from *each other* at that size — not that either is the
    /// prettiest picture of its medium.
    ///
    /// Measured, not guessed: `book` against `magazine` — the obvious pair — renders at
    /// toolbar size as two open books, near enough identical that the switch read as one
    /// smudged glyph. A closed book against a stack of pictures is the difference the
    /// two media actually have.
    /// A third glyph has to clear two bars, and the second one eliminates most of the
    /// candidates: it must be distinguishable from *both* of the others at toolbar size,
    /// and `selectedIcon` below requires it to have a `.fill` variant. The broadcast
    /// symbols — `dot.radiowaves.up.forward`, `antenna.radiowaves.left.and.right` — are
    /// the obvious pictures of a feed and none of them are filled, so the on side of the
    /// switch would have drawn nothing at all. `newspaper` is filled, is what every other
    /// reader uses for this, and carries column texture and a folded corner that a plain
    /// closed book has none of.
    var icon: String {
        switch self {
        case .novel: return "book.closed"
        case .comic: return "photo.stack"
        case .feed: return "newspaper"
        }
    }

    /// The same glyph filled, for the side of the switch that is currently on.
    var selectedIcon: String { icon + ".fill" }
}

/// The two-state switch that says what this screen is showing.
///
/// One control shared by the shelf and the search rather than one written per screen,
/// because it does not belong to either: it sets the app-wide mode, and a reader who
/// switches to comics on the shelf and finds the search still offering novel sources
/// would be looking at a bug.
///
/// A pair of buttons rather than a segmented picker, which is what this was first: a
/// segmented control does not fit inside the toolbar's own capsule — measured on
/// iPhone 17, its selection lozenge bled out of the capsule's top, bottom and left
/// edge, in that order, as the item was moved around. Two plain buttons are exactly
/// what a toolbar holds, and the state a segmented control would have drawn is said
/// instead by filling the icon of the side that is on and tinting it.
///
/// Icons only. Words wide enough to read would leave no room beside them for the
/// buttons that add a book; the names are on the buttons as accessibility labels,
/// which is where VoiceOver looks for them anyway.
struct MediaModePicker: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: 6) {
            ForEach(MediaMode.allCases) { mode in
                let isOn = env.mediaMode == mode
                Button {
                    env.mediaMode = mode
                } label: {
                    Image(systemName: isOn ? mode.selectedIcon : mode.icon)
                        .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .accessibilityLabel(Text(mode.nameKey))
                // The trait, not a suffix on the label: VoiceOver has its own word for
                // "this one is on", and it is the word its users are listening for.
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
                // Per side rather than one identifier on the pair: a walk that wants the
                // comic shelf has to be able to say so, and "the second button" is not a
                // thing a test should have to know.
                .accessibilityIdentifier("library.mode.\(mode.rawValue)")
            }
        }
    }
}
