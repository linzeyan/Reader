import Foundation
import Network

/// What kind of connection this device is on right now.
///
/// Only chapter downloads consult this. Opening a page, searching, or reading a
/// single chapter is a few hundred kilobytes that the user asked for at that
/// moment; warning about those would be nagging. A 1300-chapter book fetched
/// while the phone is in a pocket is the one thing here that can quietly spend
/// somebody's data plan.
@MainActor
@Observable
final class NetworkMonitor {
    enum Connection: Equatable {
        /// No path report has arrived yet. Treated as "not metered" everywhere:
        /// a warning shown because the OS had not answered yet is worse than a
        /// missed one in the first milliseconds after launch.
        case unknown
        case offline
        case wifi
        case cellular
    }

    private(set) var connection: Connection = .unknown

    /// Called on the main actor whenever `connection` changes. A callback rather
    /// than observation because the only listener is `AppEnvironment`, which is
    /// not a view and has no body to re-evaluate.
    var onChange: ((Connection) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    /// Runs for the lifetime of the app — there is no moment at which the
    /// download policy stops mattering, so there is nothing to stop.
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connection = Self.classify(
                isSatisfied: path.status == .satisfied,
                usesCellular: path.usesInterfaceType(.cellular),
                isExpensive: path.isExpensive
            )
            Task { @MainActor in self?.apply(connection) }
        }
        monitor.start(queue: queue)
    }

    /// Split out of the `NWPath` handler because an `NWPath` cannot be built in a
    /// test, and this mapping is the part with a decision in it.
    ///
    /// `isExpensive` folds into `.cellular` deliberately: tethering to a personal
    /// hotspot arrives as a *Wi-Fi* interface, and it is still cellular data that
    /// somebody pays for. Asking "Wi-Fi or cellular?" by interface type alone
    /// would answer "Wi-Fi" for the case where the warning matters most.
    nonisolated static func classify(
        isSatisfied: Bool, usesCellular: Bool, isExpensive: Bool
    ) -> Connection {
        guard isSatisfied else { return .offline }
        return usesCellular || isExpensive ? .cellular : .wifi
    }

    private func apply(_ new: Connection) {
        guard new != connection else { return }
        connection = new
        onChange?(new)
    }
}
