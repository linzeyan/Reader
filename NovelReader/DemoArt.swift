#if DEBUG
import UIKit

/// Draws the fictional pages and covers the screenshot fixtures are made of.
///
/// Drawn rather than bundled, for the same reason `DemoSeed` invents its books: a
/// listing for an app that points at no particular source must not show anyone's
/// artwork, and the alternative — shipping images in the asset catalogue — puts
/// megabytes into every Release binary to serve a screenshot run that only ever
/// happens on this machine.
///
/// Every shape here is a function of the chapter and page number, so a screenshot run
/// produces the same pixels twice. That is not neatness: the listing is compared
/// across languages and device sizes, and a fixture that redraws itself differently
/// each run makes those comparisons meaningless.
///
/// Deliberately abstract — panels, a horizon, a moon. Anything more would be drawing a
/// story, and what these are props for is the layout: that a page fills the width, that
/// pages stack into a chapter, that the reader can be zoomed.
enum DemoArt {
    /// One comic page, at print-ish proportions (2:3) and a size a phone will
    /// downsample — the reader decodes to the width it draws at, and a fixture smaller
    /// than the screen would be the one thing on a screenshot that looks soft.
    static func comicPage(chapter: Int, page: Int, of pageCount: Int) -> Data {
        let size = CGSize(width: 900, height: 1350)
        return image(size: size) { context in
            paper(size, in: context)
            var random = Random(seed: UInt64(chapter * 1000 + page))
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: 54, dy: 54)
            for panel in panels(in: frame, layout: page % 3) {
                draw(panel, random: &random, in: context)
            }
            caption("\(page + 1) / \(pageCount)", in: frame, size: size)
        }
    }

    /// A book's cover, at the 3:4 the shelf's thumbnail is cut to.
    ///
    /// The two media get different covers because they are different objects: a comic's
    /// cover is a picture, and a serialised novel's is a title on a plain board. Drawing
    /// the novels the same way would put artwork on the shelf that the app has no reason
    /// to have — and at 44 by 60 points, "which of these is the comic" is a question the
    /// shelf should answer without being read.
    static func cover(title: String, author: String, kind: SiteRule.Kind, seed: Int) -> Data {
        let size = CGSize(width: 600, height: 800)
        return image(size: size) { context in
            paper(size, in: context)
            switch kind {
            case .comic:
                var random = Random(seed: UInt64(seed))
                let art = CGRect(x: 40, y: 40, width: size.width - 80, height: size.height - 200)
                draw(art, random: &random, in: context)
                band(title, under: art, width: size.width)
            // A subscription's real cover is the site's own icon, fetched like any other
            // — the demo shelf has no network, and a feed is text, so it gets the same
            // plain board a serialised novel gets.
            case .novel, .feed:
                boards(title: title, author: author, size: size)
            }
        }
    }

    // MARK: - Pieces

    private static let ink = UIColor(white: 0.12, alpha: 1)
    private static let paperColour = UIColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1)

    private static func paper(_ size: CGSize, in context: CGContext) {
        paperColour.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }

    /// Three page layouts, cycled by page number so a chapter does not read as one
    /// picture repeated.
    private static func panels(in frame: CGRect, layout: Int) -> [CGRect] {
        let gutter: CGFloat = 24
        switch layout {
        case 0:
            let unit = (frame.height - gutter * 2) / 3
            return (0..<3).map {
                CGRect(x: frame.minX, y: frame.minY + (unit + gutter) * CGFloat($0),
                       width: frame.width, height: unit)
            }
        case 1:
            let top = frame.height * 0.55
            let bottom = frame.height - top - gutter
            let half = (frame.width - gutter) / 2
            return [
                CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: top),
                CGRect(x: frame.minX, y: frame.minY + top + gutter, width: half, height: bottom),
                CGRect(x: frame.minX + half + gutter, y: frame.minY + top + gutter,
                       width: half, height: bottom),
            ]
        default:
            let top = frame.height * 0.58
            return [
                CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: top),
                CGRect(x: frame.minX, y: frame.minY + top + gutter,
                       width: frame.width, height: frame.height - top - gutter),
            ]
        }
    }

    private static func draw(_ panel: CGRect, random: inout Random, in context: CGContext) {
        context.saveGState()
        let path = UIBezierPath(rect: panel)
        path.addClip()
        scene(in: panel, random: &random, context: context)
        context.restoreGState()
        ink.setStroke()
        path.lineWidth = 7
        path.stroke()
    }

    /// One of a handful of horizons. Shapes only — a demo page that tried to tell a
    /// story would be a story nobody wrote.
    ///
    /// Roughly one panel in four comes out as night, which is the whole reason there is
    /// a variable here at all: three panels of the same composition read as one picture
    /// printed three times, and a page like that says nothing about a comic reader.
    private static func scene(in panel: CGRect, random: inout Random, context: CGContext) {
        let night = random.next(4) == 0
        let sky = night
            ? UIColor(white: 0.26, alpha: 1)
            : UIColor(white: 0.90 - CGFloat(random.next(4)) * 0.02, alpha: 1)
        sky.setFill()
        UIBezierPath(rect: panel).fill()

        let horizon = panel.minY + panel.height * (0.45 + CGFloat(random.next(4)) * 0.09)

        // The disc: a moon, or a sun, or a lamp. It is above the horizon and that is
        // all it has to be.
        let radius = min(panel.width, panel.height) * (0.10 + CGFloat(random.next(4)) * 0.03)
        let discX = panel.minX + panel.width * (0.18 + CGFloat(random.next(6)) * 0.12)
        let disc = CGRect(
            x: discX - radius, y: horizon - panel.height * 0.30 - radius,
            width: radius * 2, height: radius * 2
        )
        UIColor(white: night ? 0.97 : 1, alpha: night ? 1 : 0.9).setFill()
        UIBezierPath(ovalIn: disc).fill()
        let outline = UIBezierPath(ovalIn: disc)
        (night ? UIColor(white: 0.97, alpha: 1) : ink).setStroke()
        outline.lineWidth = 4
        outline.stroke()

        // Hills, drawn back to front so the nearer ones cover the further ones. At
        // night they are silhouettes against the sky; by day the sky is the light one.
        let tones: [CGFloat] = night ? [0.20, 0.13, 0.07] : [0.72, 0.50, 0.26]
        for layer in 0..<3 {
            let depth = CGFloat(layer)
            let hill = UIBezierPath()
            let base = horizon + depth * panel.height * 0.06
            hill.move(to: CGPoint(x: panel.minX, y: base))
            let peaks = 2 + random.next(3)
            let step = panel.width / CGFloat(peaks)
            for peak in 0..<peaks {
                let x = panel.minX + step * (CGFloat(peak) + 0.5)
                let height = panel.height * (0.10 + CGFloat(random.next(5)) * 0.03) - depth * 6
                hill.addQuadCurve(
                    to: CGPoint(x: panel.minX + step * CGFloat(peak + 1), y: base),
                    controlPoint: CGPoint(x: x, y: base - height)
                )
            }
            hill.addLine(to: CGPoint(x: panel.maxX, y: panel.maxY))
            hill.addLine(to: CGPoint(x: panel.minX, y: panel.maxY))
            hill.close()
            UIColor(white: tones[layer], alpha: 1).setFill()
            hill.fill()
        }

        // A few birds, which is a stroke of two curves and the only thing on the page
        // that suggests anything is alive.
        (night ? UIColor(white: 0.85, alpha: 1) : ink).setStroke()
        for _ in 0..<(1 + random.next(3)) {
            let x = panel.minX + panel.width * CGFloat(random.next(80)) / 100
            let y = panel.minY + panel.height * (0.10 + CGFloat(random.next(22)) / 100)
            let wing = panel.width * 0.03
            let bird = UIBezierPath()
            bird.move(to: CGPoint(x: x - wing, y: y))
            bird.addQuadCurve(to: CGPoint(x: x, y: y), controlPoint: CGPoint(x: x - wing / 2, y: y - wing * 0.7))
            bird.addQuadCurve(to: CGPoint(x: x + wing, y: y), controlPoint: CGPoint(x: x + wing / 2, y: y - wing * 0.7))
            bird.lineWidth = 3
            bird.stroke()
        }
    }

    private static func caption(_ text: String, in frame: CGRect, size: CGSize) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 26, weight: .medium),
            .foregroundColor: UIColor(white: 0.35, alpha: 1),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let measured = string.size()
        string.draw(at: CGPoint(x: frame.maxX - measured.width, y: size.height - 46))
    }

    /// A novel's cover: a ruled border, the title, a hairline, the author. What a
    /// serialised novel's cover actually looks like on these sites, which is to say
    /// typography and nothing else.
    private static func boards(title: String, author: String, size: CGSize) {
        let border = UIBezierPath(rect: CGRect(origin: .zero, size: size).insetBy(dx: 44, dy: 44))
        ink.setStroke()
        border.lineWidth = 6
        border.stroke()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 76, weight: .semibold),
            .foregroundColor: ink,
        ]
        let heading = NSAttributedString(string: title, attributes: titleAttributes)
        // Wrapped by hand rather than by a layout manager: a four-character title fits
        // and a longer one has to break somewhere, and the only thing this has to get
        // right is that it stays inside the border.
        let measured = heading.size()
        let top = size.height * 0.30
        if measured.width <= size.width - 160 {
            heading.draw(at: CGPoint(x: (size.width - measured.width) / 2, y: top))
        } else {
            let split = title.index(title.startIndex, offsetBy: title.count / 2)
            for (line, text) in [String(title[..<split]), String(title[split...])].enumerated() {
                let piece = NSAttributedString(string: text, attributes: titleAttributes)
                piece.draw(at: CGPoint(
                    x: (size.width - piece.size().width) / 2,
                    y: top + CGFloat(line) * (measured.height + 8)
                ))
            }
        }

        let rule = UIBezierPath()
        rule.move(to: CGPoint(x: size.width * 0.35, y: size.height * 0.56))
        rule.addLine(to: CGPoint(x: size.width * 0.65, y: size.height * 0.56))
        UIColor(white: 0.45, alpha: 1).setStroke()
        rule.lineWidth = 3
        rule.stroke()

        let byline = NSAttributedString(string: author, attributes: [
            .font: UIFont.systemFont(ofSize: 40, weight: .regular),
            .foregroundColor: UIColor(white: 0.35, alpha: 1),
        ])
        byline.draw(at: CGPoint(
            x: (size.width - byline.size().width) / 2, y: size.height * 0.60
        ))
    }

    private static func band(_ title: String, under art: CGRect, width: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 54, weight: .semibold),
            .foregroundColor: ink,
        ]
        let string = NSAttributedString(string: title, attributes: attributes)
        let measured = string.size()
        string.draw(at: CGPoint(x: (width - measured.width) / 2, y: art.maxY + 34))
    }

    private static func image(size: CGSize, draw: (CGContext) -> Void) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        // Scale 1, so the pixel size is the size asked for: these are files standing in
        // for a site's, and a site does not serve at the screenshot device's scale.
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            draw(context.cgContext)
        }
    }

    /// A tiny reproducible generator, so the fixtures do not depend on the system's.
    /// `SystemRandomNumberGenerator` cannot be seeded, and a fixture that draws itself
    /// differently on every run is not a fixture.
    private struct Random {
        private var state: UInt64

        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }

        /// A value in `0..<bound`.
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(max(1, bound)))
        }
    }
}
#endif
