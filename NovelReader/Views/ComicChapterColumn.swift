import CoreGraphics

/// One comic chapter as a column of pages.
///
/// The mirror of `ChapterColumn` in shape and purpose — a chapter that knows its own
/// height and can map a height to what is at it — and deliberately not a shared
/// abstraction with it. That one is bound to TextKit 2: its coordinates come out of a
/// layout manager, its unit is a character offset, and it answers questions about
/// glyphs, marks and paragraph extents. This one holds an array of numbers. Two users
/// is not enough to build an abstraction over, and the one that would result would be
/// a layout manager wearing a page-array costume.
///
/// The difference that matters is *when* the heights are known. Text is laid out once
/// and completely before a column exists, so `ChapterColumn.height` is final. A page's
/// height is not known until its image has been decoded, which happens per page, later,
/// and out of order. So this column starts on an estimate and takes corrections — and
/// the correction is exactly what the column-stack architecture makes cheap: a page
/// growing above the reader is a number the coordinator adds to the scroll offset (see
/// `ComicScrollCoordinator.correct`), where a lazy container could only be asked to aim
/// at a row and then measured for how far it missed.
///
/// Not `@MainActor`: it is arithmetic over an array and holds nothing that has a thread
/// affinity. Nothing here is safe to call concurrently, like the column it mirrors.
final class ComicChapterColumn {
    let pageCount: Int
    /// The measure the pages are drawn at. A change means every height in here describes
    /// a width nobody is reading at, and a new column has to be built.
    let width: CGFloat

    /// Each page's height, and the running total above it. `tops` has one entry more
    /// than there are pages, so the last is the column's height and no caller has to
    /// special-case the end.
    private var heights: [CGFloat]
    private var tops: [CGFloat]
    /// Which pages have been given the size of a real decoded image. The rest are
    /// carrying `estimatedHeight`.
    private var measured: [Bool]

    var height: CGFloat { tops[pageCount] }

    /// How tall a page is assumed to be before its image arrives.
    ///
    /// 2:3, which is the shape of a printed comic page and roughly what all four
    /// surveyed sites serve. It is a guess and it is *going* to be wrong — a webtoon
    /// strip is many times taller — and being wrong is survivable here in a way it was
    /// not in the renderer this architecture replaced: the correction is one addition
    /// against a column that knows where everything is. What the estimate buys is a
    /// scrollable chapter before any image has been downloaded, which is what stops the
    /// reader looking at a screen that cannot be moved.
    static func estimatedHeight(forWidth width: CGFloat) -> CGFloat { width * 1.5 }

    /// No gap between pages, on purpose. A webtoon is one continuous drawing cut into
    /// slices, and any gap at all draws a line through the middle of the artwork. Page
    /// comics carry their own margins inside the image and need none added.
    init(pageCount: Int, width: CGFloat) {
        self.pageCount = max(0, pageCount)
        self.width = width
        let estimate = Self.estimatedHeight(forWidth: width)
        heights = Array(repeating: estimate, count: self.pageCount)
        measured = Array(repeating: false, count: self.pageCount)
        tops = []
        restack()
    }

    // MARK: - Measuring

    /// Records a page's real size, and says how much taller the column got.
    ///
    /// - Returns: the change in the column's height, which is also how far everything
    ///   below this page has moved. Zero when the size was already known or the page is
    ///   not in this chapter, so a caller may apply the result unconditionally.
    ///
    /// The height is derived from the aspect ratio rather than taken from the image's
    /// pixel height: a page is drawn to fit the reader's width, and its pixel height is
    /// a fact about the file. Deriving it here is what keeps the two in step when the
    /// device rotates — a new width builds a new column and every page recomputes.
    @discardableResult
    func setSize(_ size: CGSize, ofPage index: Int) -> CGFloat {
        guard heights.indices.contains(index), size.width > 0, size.height > 0 else { return 0 }
        let scaled = width * (size.height / size.width)
        guard !measured[index] || scaled != heights[index] else { return 0 }
        let delta = scaled - heights[index]
        heights[index] = scaled
        measured[index] = true
        restack()
        return delta
    }

    /// Whether this page is still carrying the estimate.
    func isEstimated(page index: Int) -> Bool {
        measured.indices.contains(index) ? !measured[index] : false
    }

    private func restack() {
        tops = Array(repeating: 0, count: pageCount + 1)
        var y: CGFloat = 0
        for index in 0..<pageCount {
            tops[index] = y
            y += heights[index]
        }
        tops[pageCount] = y
    }

    // MARK: - Coordinates

    /// Where a page starts in this column.
    func top(ofPage index: Int) -> CGFloat {
        tops[min(max(index, 0), pageCount)]
    }

    func height(ofPage index: Int) -> CGFloat {
        heights.indices.contains(index) ? heights[index] : 0
    }

    func frame(ofPage index: Int) -> CGRect {
        CGRect(x: 0, y: top(ofPage: index), width: width, height: height(ofPage: index))
    }

    /// Which page a height in this column falls on.
    ///
    /// The last page starting at or before `y`, so a height inside a page names that
    /// page rather than the next one — the same rule `ChapterColumn.offset(atY:)` keeps,
    /// and for the same reason: a reading position must never round forward into a page
    /// the reader has not reached.
    func page(atY y: CGFloat) -> Int {
        guard pageCount > 0 else { return 0 }
        var low = 0
        var high = pageCount - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if tops[mid] <= y {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// The pages with any part inside a vertical range, in reading order.
    ///
    /// What the coordinator asks on every scrolled frame to decide which images need to
    /// be on screen and which can have their bitmaps thrown away.
    func pages(in range: Range<CGFloat>) -> Range<Int> {
        guard pageCount > 0, range.upperBound > 0, range.lowerBound < height else { return 0..<0 }
        let first = page(atY: max(range.lowerBound, 0))
        var last = first
        while last + 1 < pageCount, tops[last + 1] < range.upperBound {
            last += 1
        }
        return first..<(last + 1)
    }

    /// How far through the chapter a height is, 0…1.
    ///
    /// By page rather than by points, because a page is what a comic's position names
    /// and points are a fact about images that have not all been measured yet. Two
    /// readers at page 12 of 40 have read the same amount of the chapter whether or not
    /// the pages between them have been decoded, and a share computed from a column
    /// still full of estimates would move under them as the images arrived.
    func fractionRead(through y: CGFloat) -> Double {
        guard pageCount > 0 else { return 0 }
        guard y < height else { return 1 }
        return Double(page(atY: y) + 1) / Double(pageCount)
    }
}
