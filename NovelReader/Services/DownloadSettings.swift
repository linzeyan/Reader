import Foundation

/// Download preferences. In `UserDefaults` and deliberately *not* synced: which
/// networks are cheap is a property of this device's data plan, not of the
/// person — a phone on a metered plan and an iPad that never leaves Wi-Fi want
/// opposite answers.
@Observable
final class DownloadSettings {
    /// Which connections chapter downloads may run on.
    enum NetworkPolicy: String, CaseIterable, Identifiable {
        /// Starting a download on a metered connection asks first, every run,
        /// and a run that becomes metered pauses itself.
        case wifiOnly
        /// No detection, no prompt — the user has said the data is theirs to
        /// spend.
        case wifiAndCellular

        var id: String { rawValue }
    }

    /// Defaults to Wi-Fi only. The safe answer is the one that cannot surprise
    /// someone with a data bill, and the prompt puts the other one one tap away.
    var network: NetworkPolicy {
        didSet { defaults.set(network.rawValue, forKey: Keys.network) }
    }

    private enum Keys {
        static let network = "downloads.network"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        network = defaults.string(forKey: Keys.network)
            .flatMap(NetworkPolicy.init(rawValue:)) ?? .wifiOnly
    }
}

extension DownloadSettings.NetworkPolicy {
    /// Whether starting or resuming a download on `connection` has to ask the
    /// user first.
    func needsConfirmation(on connection: NetworkMonitor.Connection) -> Bool {
        self == .wifiOnly && connection == .cellular
    }
}
