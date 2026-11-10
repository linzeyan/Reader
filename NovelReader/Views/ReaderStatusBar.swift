import SwiftUI
import UIKit

extension View {
    /// The status bar inside a reader: shown with the controls on an iPhone with a notch
    /// or a Dynamic Island, hidden everywhere else.
    ///
    /// The clock and the battery are what a reader looks up for, and the controls are the
    /// moment they are looking up anyway. The condition is about the page not moving: on
    /// those phones the status bar sits either side of the sensor housing, in height the
    /// safe area has already given up, so showing it shifts nothing. On a phone without
    /// one, or an iPad, the status bar's height *is* safe area, and toggling it would
    /// move every line of text by that much — there it stays hidden.
    func readerStatusBar(showingControls: Bool) -> some View {
        statusBarHidden(!(showingControls && SensorHousing.isPresent))
    }
}

@MainActor
private enum SensorHousing {
    /// Read off the window rather than a device list, so a new model needs no entry.
    /// With the status bar hidden, as it is in a reader until the controls come up, a
    /// phone without a housing reports no top inset at all; the housing is the only
    /// thing left holding one open. Landscape reports none either, which is right:
    /// iOS keeps the status bar hidden there on these phones regardless.
    static var isPresent: Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        return (window?.safeAreaInsets.top ?? 0) > 24
    }
}
