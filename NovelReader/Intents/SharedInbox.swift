import Foundation

/// Pages shared to the app from another app's share sheet, waiting for the app to add them.
///
/// Compiled into both the app and the share extension, which is what keeps the two halves
/// agreeing on where the pages are left. The extension cannot add a book itself — that
/// takes the app's web view and database, and sometimes the reader getting past a site's
/// check — and it does not open the app either: a share extension is meant to finish in
/// the sheet, and the ways round that are ones App Review can refuse. So it leaves the
/// address here, in the container the two targets share, and the app takes whatever is
/// waiting the next time it comes forward.
///
/// One file per share rather than one list. The extension and the app are separate
/// processes that can both be running, and a list each of them read, changed and wrote
/// back would lose whichever share landed in between; a file is written whole or not at
/// all.
struct SharedInbox {
    /// Also declared in both targets' entitlements, which is what lets each of them reach
    /// the container.
    static let group = "group.com.zeyanlin.novelreader"

    /// The inbox both targets use. Nil when the container cannot be reached — a build
    /// whose entitlements lost the group.
    static let shared: SharedInbox? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: group)
        .map { SharedInbox(directory: $0.appendingPathComponent("SharedLinks", isDirectory: true)) }

    let directory: URL

    func put(_ address: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Named for the moment it was shared, so taking them back in name order is taking
        // them in the order the reader shared them.
        let name = String(format: "%.6f-%@", Date().timeIntervalSince1970, UUID().uuidString)
        try Data(address.absoluteString.utf8)
            .write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    var isEmpty: Bool { files().isEmpty }

    /// Everything waiting, oldest first, and the inbox emptied of it.
    func take() -> [String] {
        files().compactMap { file in
            defer { try? FileManager.default.removeItem(at: file) }
            let address = (try? String(contentsOf: file, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return address?.isEmpty == false ? address : nil
        }
    }

    /// The shares, without the hidden file an atomic write keeps while it is half done.
    private func files() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return names
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
