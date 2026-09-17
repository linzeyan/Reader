import UIKit

/// How fast the page moves when nobody is touching it.
///
/// Stated in lines a minute rather than points a second, because a reading speed belongs
/// to the reader and not to the type size: the same page at 24pt is nearly twice the
/// travel it is at 14pt, so a speed stored as distance would quietly halve itself the day
/// somebody makes the text bigger — and the slider they set last month would mean
/// something else without anybody touching it.
struct ReadingPace: Equatable {
    var linesPerMinute: Double

    /// Slow enough for a page being studied, fast enough to be skimming. A phone line of
    /// Chinese prose runs about twenty characters, so the middle of this range is the
    /// 300–500 characters a minute prose is actually read at.
    static let range: ClosedRange<Double> = 5...60

    /// Where a reader who has never touched the slider starts.
    static let standard = ReadingPace(linesPerMinute: 20)

    /// Points a second, for a surface that scrolls continuously.
    func pointsPerSecond(lineHeight: CGFloat) -> CGFloat {
        CGFloat(max(0, linesPerMinute)) * max(0, lineHeight) / 60
    }
}

extension ReadingMetrics {
    /// The height one line of body text occupies, its leading included — what a speed in
    /// lines a minute is measured against.
    ///
    /// Asked of `ReaderTypography` rather than resolved here: that type already owns the
    /// rule that turns a face name and a size into a font, including what an uninstalled
    /// face falls back to. A second copy of it is a line height that stops matching the
    /// text it claims to measure.
    var lineHeight: CGFloat {
        ReaderTypography(metrics: self, color: .clear).body.lineHeight + lineSpacing
    }
}

/// Moves a scrolling surface on its own, one frame at a time.
///
/// Knows nothing about what it is moving: it offers a distance and is told how far the
/// surface really went. That is what lets one driver serve the text reader and the comic
/// one, and it is also how running out of text is noticed — a surface already at the foot
/// of everything it holds answers "nowhere", which is a fact no caller has to be asked for.
@MainActor
final class AutoScrollDriver {
    /// Asked to move the surface, and answers how far it actually moved.
    private let step: (CGFloat) -> CGFloat

    /// Points a second. Zero is off, and off means no display link at all: a reader who
    /// is not using this must not pay for a callback a frame.
    private(set) var speed: CGFloat = 0

    /// The surface has had nowhere to go for `stallLimit`, so this has switched itself
    /// off — the end of the book, or a chapter that will not load.
    ///
    /// Distinct from being held by a finger, which is the reader taking the page back and
    /// not a reason to switch anything off.
    var onRanAground: (() -> Void)?

    var isRunning: Bool { speed > 0 }

    /// How long the surface may refuse to move before this gives up on it.
    ///
    /// Not at once: the foot of the loaded text is a place the reader passes through on
    /// the way into a chapter that is still being fetched, and a driver that stopped there
    /// would switch itself off every time the network was slower than the reading.
    private static let stallLimit: CFTimeInterval = 5

    /// The longest travel one frame may be asked for.
    ///
    /// A display link that has not fired for a while — the app was in the switcher, the
    /// main thread was busy — reports the whole gap as elapsed, and honouring it would
    /// throw the reader a screen or more down the book. Two frames' worth: the page may
    /// catch up a stutter, never a minute.
    private static let longestStep: CFTimeInterval = 1.0 / 30

    /// The coarsest grid a scroll view here can sit on: a whole device pixel, which is half
    /// a point at 2x and a third at 3x. The same number `ReaderScrollCoordinator.visibleTurn`
    /// is, for the same reason.
    private static let smallestMove: CGFloat = 0.5

    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var stalledSince: CFTimeInterval?
    /// Travel the surface has been promised and not yet been given.
    ///
    /// The whole reason a frame's distance is not simply handed over as it is earned: at a
    /// reading pace one frame is worth a fraction of a point, and a surface that can only
    /// sit on a whole pixel rounds every one of them away. Measured on an iPhone SE — the
    /// page stood perfectly still, and because each of those frames also *reported* not
    /// moving, the driver read a book the reader was in the middle of as one that had run
    /// out and switched itself off five seconds in. Banked here, the fractions add up until
    /// they are worth a pixel, and "it did not move" goes back to meaning what it says.
    private var carry: CGFloat = 0
    /// Whether a finger is on the glass. The reader's own scrolling wins outright: a page
    /// being dragged while something else also moves it is a page nobody is steering.
    private var isHeld = false

    init(step: @escaping (CGFloat) -> CGFloat) {
        self.step = step
    }

    deinit { link?.invalidate() }

    func setSpeed(_ pointsPerSecond: CGFloat) {
        let wanted = max(0, pointsPerSecond)
        guard wanted != speed else { return }
        speed = wanted
        if wanted > 0 { start() } else { stop() }
    }

    /// A finger on the glass, or the coast after it lifts — the same signal a chapter
    /// insert waits for.
    func hold(_ down: Bool) {
        guard isHeld != down else { return }
        isHeld = down
        link?.isPaused = down
        // Nothing elapsed while the reader had the page. Without this the whole hold
        // arrives as one step the moment they let go.
        lastTick = nil
        stalledSince = nil
        carry = 0
    }

    /// One frame's worth of travel.
    ///
    /// Internal rather than private, and taking the time rather than reading a clock, so
    /// that the arithmetic can be asserted without a run loop to animate through.
    func tick(at now: CFTimeInterval) {
        guard speed > 0, !isHeld else {
            lastTick = nil
            return
        }
        defer { lastTick = now }
        guard let previous = lastTick, now > previous else { return }
        let elapsed = min(now - previous, Self.longestStep)
        carry += speed * CGFloat(elapsed)
        // Not yet worth a pixel. Nothing is asked of the surface, so nothing is learned
        // about it either — a frame that was never offered anywhere to go cannot count as
        // one that found nowhere.
        guard carry >= Self.smallestMove else { return }
        let moved = step(carry)
        guard moved < Self.smallestMove else {
            carry -= moved
            stalledSince = nil
            return
        }
        // Nowhere to go. The banked travel is dropped rather than kept: a chapter that
        // takes four seconds to arrive would otherwise be paid out as one jump the moment
        // it did, throwing the reader down the page they had been waiting for.
        carry = 0
        guard let since = stalledSince else {
            stalledSince = now
            return
        }
        guard now - since >= Self.stallLimit else { return }
        setSpeed(0)
        onRanAground?()
    }

    private func start() {
        guard link == nil else { return }
        lastTick = nil
        stalledSince = nil
        carry = 0
        let proxy = DisplayLinkProxy()
        proxy.driver = self
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        // `.common`, so the page keeps moving while the reader drags the speed slider: a
        // run loop tracking a touch leaves `.default` behind, and a page that stops the
        // moment you reach for the control that sets its speed cannot be set by feel.
        link.add(to: .main, forMode: .common)
        link.isPaused = isHeld
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
        lastTick = nil
        stalledSince = nil
        carry = 0
    }
}

/// Holds the display link's end of the reference.
///
/// `CADisplayLink` retains its target and the run loop retains the link, so a driver that
/// were the target itself would outlive the reader that built it — moving a page nobody
/// is looking at until it happened to run aground.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var driver: AutoScrollDriver?

    @objc func tick(_ link: CADisplayLink) {
        driver?.tick(at: link.timestamp)
    }
}
