import Foundation

/// How much of each subscription is kept.
///
/// In `UserDefaults` and not synced, like every other setting here: how much room this
/// device has is a fact about the device. It is also the one setting in the app that
/// *deletes* things, so the defaults are the conservative end of what was asked for — ten
/// articles a feed, nothing touched for a week, and unread articles given a month of their
/// own before they count at all.
@Observable
final class FeedRetentionSettings {
    /// Offered as a short list rather than a free number: this is a decision made once,
    /// and a stepper that can land on 37 invites a choice nobody has a reason to make.
    enum Keep: Int, CaseIterable, Identifiable {
        case ten = 10
        case twentyFive = 25
        case fifty = 50
        case hundred = 100
        /// Off. Nothing is ever deleted, which is what someone who reads a subscription
        /// as an archive wants — and it is the answer this setting has to be able to give,
        /// or the feature is something done *to* the reader.
        case everything = 0

        var id: Int { rawValue }

        var nameKey: LocalizedStringResource {
            switch self {
            case .ten: return "retention.keep.10"
            case .twentyFive: return "retention.keep.25"
            case .fifty: return "retention.keep.50"
            case .hundred: return "retention.keep.100"
            case .everything: return "retention.keep.all"
            }
        }
    }

    /// How long a surplus article is left alone first.
    enum Grace: Int, CaseIterable, Identifiable {
        case day = 1
        case week = 7
        case month = 30

        var id: Int { rawValue }
        var interval: TimeInterval { TimeInterval(rawValue) * 24 * 60 * 60 }

        var nameKey: LocalizedStringResource {
            switch self {
            case .day: return "retention.grace.day"
            case .week: return "retention.grace.week"
            case .month: return "retention.grace.month"
            }
        }
    }

    /// The longer clock an unread article gets.
    enum UnreadRetention: Int, CaseIterable, Identifiable {
        case week = 7
        case month = 30
        case quarter = 90
        /// Never deleted while unread. For the reader whose subscriptions are a list of
        /// things they still intend to read.
        case forever = 0

        var id: Int { rawValue }
        var interval: TimeInterval? {
            self == .forever ? nil : TimeInterval(rawValue) * 24 * 60 * 60
        }

        var nameKey: LocalizedStringResource {
            switch self {
            case .week: return "retention.unread.week"
            case .month: return "retention.unread.month"
            case .quarter: return "retention.unread.quarter"
            case .forever: return "retention.unread.forever"
            }
        }
    }

    var keep: Keep {
        didSet { defaults.set(keep.rawValue, forKey: Keys.keep) }
    }

    var grace: Grace {
        didSet { defaults.set(grace.rawValue, forKey: Keys.grace) }
    }

    var unread: UnreadRetention {
        didSet { defaults.set(unread.rawValue, forKey: Keys.unread) }
    }

    var policy: FeedRetention.Policy {
        FeedRetention.Policy(
            keepCount: keep.rawValue, grace: grace.interval, unreadRetention: unread.interval
        )
    }

    private enum Keys {
        static let keep = "feeds.retention.keep"
        static let grace = "feeds.retention.grace"
        static let unread = "feeds.retention.unread"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` first, because `integer(forKey:)` answers 0 for a key that was
        // never set — and 0 is a real value here, the one that means "keep everything".
        keep = (defaults.object(forKey: Keys.keep) as? Int).flatMap(Keep.init(rawValue:)) ?? .ten
        grace = (defaults.object(forKey: Keys.grace) as? Int)
            .flatMap(Grace.init(rawValue:)) ?? .week
        unread = (defaults.object(forKey: Keys.unread) as? Int)
            .flatMap(UnreadRetention.init(rawValue:)) ?? .month
    }
}
