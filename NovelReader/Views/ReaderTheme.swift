import SwiftUI
import UIKit

/// A colour that survives a round trip through `UserDefaults`.
///
/// SwiftUI's `Color` has no storage form that is stable to write down, and a reader's
/// own text colour has to come back exactly as chosen — a shade of drift between two
/// launches is a bug nobody can describe well enough to file.
struct ReaderColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From a hex literal, which is how the two shipped palettes are specified.
    /// A `Color(white:)` that happens to land near `#121314` is the same colour only
    /// by accident, and these two were chosen, not approximated.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    init(_ color: Color) { self.init(UIColor(color)) }

    init(_ color: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            self.init(red: red, green: green, blue: blue, alpha: alpha)
        } else {
            // A greyscale colour refuses the RGB question. White is the one every
            // colour space answers, and a grey is the same colour in both.
            var white: CGFloat = 0
            color.getWhite(&white, alpha: &alpha)
            self.init(red: white, green: white, blue: white, alpha: alpha)
        }
    }

    var color: Color { Color(red: red, green: green, blue: blue, opacity: alpha) }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Perceived brightness, 0…1. Weighted rather than averaged because the eye reads
    /// green as most of a colour's light: a saturated blue and a saturated green of the
    /// same arithmetic mean are nowhere near equally readable on the same page.
    var brightness: Double { 0.299 * red + 0.587 * green + 0.114 * blue }
}

/// What the page is painted with.
///
/// One case covers a flat colour and a gradient because to a reader they are the same
/// decision — what colour is my page — and two cases would mean two editors with a mode
/// switch between them. One stop is a plain surface; more than one is blended from the
/// top of the screen to the bottom, which is the only direction a page of text is read
/// in and so the only direction worth a control.
enum ReaderBackground: Codable, Equatable {
    case colors([ReaderColor])
    /// A picture the reader supplied, by file name inside `ReaderBackgroundStore`.
    case image(String)

    /// The one flat colour this is, or nil for anything else.
    ///
    /// The scrolling renderer paints its text canvas opaque so that a scrolled frame is
    /// not a full-screen blend, and it can only do that when there is a single colour to
    /// paint it with. See `ReaderTextScrollView.apply(palette:)`.
    var flatColor: ReaderColor? {
        guard case .colors(let stops) = self, stops.count == 1 else { return nil }
        return stops[0]
    }

    /// The stops, for a background made of colours; empty for a picture.
    var stops: [ReaderColor] {
        guard case .colors(let stops) = self else { return [] }
        return stops
    }
}

/// The reader's surface, resolved: what the page is painted with, and what the text is
/// painted in.
///
/// One value rather than two lookups, because everything downstream is a function of the
/// pair — the wash a highlight is drawn in, the colour scheme the floating chrome has to
/// sit at, and the key the text columns were laid out under.
struct ReaderPalette: Equatable, Codable {
    var background: ReaderBackground
    var foreground: ReaderColor

    /// Off-white and near-black rather than white on black: a pure value at either end
    /// is what makes a screen glare under a lamp.
    static let light = ReaderPalette(
        background: .colors([ReaderColor(hex: 0xFAF7F0)]),
        foreground: ReaderColor(hex: 0x1A1A1A)
    )

    static let dark = ReaderPalette(
        background: .colors([ReaderColor(hex: 0x121314)]),
        foreground: ReaderColor(hex: 0xBFBFBF)
    )

    var ink: Color { foreground.color }

    /// Read off the text rather than the page, because it is the one signal every kind of
    /// background carries. A picture has no single colour to measure, but light text over
    /// it still means the reader is looking at a dark screen.
    var isDark: Bool { foreground.brightness > 0.5 }

    /// The one highlight tint, in the one place both renderers read it from.
    ///
    /// One style, not a palette: colours would have to be chosen in the reader, stored per
    /// highlight and rendered in two engines, and a reader who marks a passage wants it
    /// marked, not categorised. A warm yellow because that is what a marked page looks
    /// like everywhere else — but a dark surface swallows a translucent wash, so it gets
    /// less transparency rather than a different hue.
    var highlight: Color {
        Color(red: 1.0, green: 0.84, blue: 0.28).opacity(isDark ? 0.34 : 0.44)
    }

    /// While the finger is still down this is a selection, not a mark, so it reads as
    /// neutral: the passage turns yellow at the moment the reader commits, which is the
    /// feedback that says the highlight was actually made.
    var selection: Color { ink.opacity(0.24) }

    /// Everything about this palette that is baked into laid-out text.
    ///
    /// The background is deliberately absent. It is painted *behind* the glyphs and never
    /// into them, so swapping a gradient for a photograph must not throw away every
    /// chapter the reader has already scrolled through.
    var textKey: String {
        "\(foreground.red)|\(foreground.green)|\(foreground.blue)|\(foreground.alpha)"
    }
}

/// Where a reader's own background picture lives.
///
/// Application Support, next to the covers, rather than Caches: the system empties Caches
/// under pressure, and a background that evaporates leaves the reader looking at a page
/// they never chose. Only ever one file — picking a new picture replaces the old one,
/// because the setting holds one background, not a library of them.
enum ReaderBackgroundStore {
    static let directory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("ReaderBackground", isDirectory: true)
    }()

    /// The longest edge worth keeping. A photo straight out of a modern camera is several
    /// times the pixels of the screen it will be stretched over, and holding one decoded
    /// behind every scrolled frame costs tens of megabytes for nothing anyone can see.
    private static let maxEdge: CGFloat = 2048

    /// Decoded once and held: SwiftUI asks for the background on every body pass, and a
    /// reader who re-reads a two-megapixel JPEG off disk per frame is a reader whose
    /// scroll stutters.
    private static var cached: (name: String, image: UIImage)?

    /// - Returns: the file name to store in a `ReaderBackground`, or nil if the picture
    ///   could not be written — which the picker reports rather than swallowing.
    static func save(_ image: UIImage) -> String? {
        guard let data = downscaled(image).jpegData(compressionQuality: 0.9) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            return nil
        }
        cached = nil
        removeAll(keeping: name)
        return name
    }

    static func image(named name: String) -> UIImage? {
        if let cached, cached.name == name { return cached.image }
        let path = directory.appendingPathComponent(name).path
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        cached = (name, image)
        return image
    }

    static func removeAll(keeping name: String?) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where file != name {
            try? manager.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        // Pixels, not points: `size` is already divided by the image's own scale, and a
        // photo measured in points would be let through at four times the data.
        let pixels = CGSize(
            width: image.size.width * image.scale, height: image.size.height * image.scale
        )
        let longest = max(pixels.width, pixels.height)
        guard longest > maxEdge, longest > 0 else { return image }
        let ratio = maxEdge / longest
        let size = CGSize(
            width: (pixels.width * ratio).rounded(), height: (pixels.height * ratio).rounded()
        )
        let format = UIGraphicsImageRendererFormat.default()
        // One drawn pixel per asked-for pixel. The renderer's default is the screen's
        // scale, which would put back the three-quarters of the data just removed.
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// The page, painted.
///
/// A view rather than a `ShapeStyle` because a picture is not one, and the three kinds of
/// background have to be interchangeable everywhere a page is drawn.
struct ReaderBackgroundView: View {
    let background: ReaderBackground

    var body: some View {
        switch background {
        case .colors(let stops):
            if stops.count > 1 {
                LinearGradient(colors: stops.map(\.color), startPoint: .top, endPoint: .bottom)
            } else {
                stops.first?.color ?? Color(.systemBackground)
            }
        case .image(let name):
            if let image = ReaderBackgroundStore.image(named: name) {
                // Filled and cropped rather than fitted: a picture letterboxed against the
                // page shows its own edges, and the reader chose a background, not a plate.
                Color.clear
                    .overlay { Image(uiImage: image).resizable().scaledToFill() }
                    .clipped()
            } else {
                // The file is gone — a restore, or a backup that carried the choice but not
                // the picture. A plain page the reader can still read on beats a screen
                // that draws nothing.
                Color(.systemBackground)
            }
        }
    }
}
