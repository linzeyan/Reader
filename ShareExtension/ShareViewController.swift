import UIKit
import UniformTypeIdentifiers

/// "Share → 書房" from a browser: leaves the page's address for the app to add.
///
/// Only leaves it. Adding a book means fetching the page in the app's web view and
/// writing the app's database, neither of which an extension has — so the address goes
/// into the `SharedInbox`, the reader is told it got there, and the sheet closes on the
/// page they were reading. The app adds it the next time it comes forward, and says there
/// which ones did not go in. Several pages can be shared in a row this way, which is the
/// convenience the whole thing is for.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        // Clear, so the only thing drawn over the page is the word that it got there.
        view.backgroundColor = .clear
    }

    // On appearing rather than on loading: an alert can only be presented from a view
    // that is in a window.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await leave() }
    }

    private func leave() async {
        guard let address = await sharedAddress() else {
            return explain(String(localized: "share.error.noAddress"))
        }
        do {
            guard let inbox = SharedInbox.shared else { throw CocoaError(.fileNoSuchFile) }
            try inbox.put(address)
        } catch {
            // Not lost: the reader can still paste it into the app by hand, and is told so.
            UIPasteboard.general.string = address.absoluteString
            return explain(String(localized: "share.error.cannotSave"))
        }
        await confirm()
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// The page's address. The activation rule in Info.plist only offers this extension
    /// for a web address, so the first one is the page.
    private func sharedAddress() async -> URL? {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let type = UTType.url.identifier
        for provider in items.flatMap({ $0.attachments ?? [] })
        where provider.hasItemConformingToTypeIdentifier(type) {
            if let url = try? await provider.loadItem(forTypeIdentifier: type) as? URL,
               url.scheme == "http" || url.scheme == "https" {
                return url
            }
        }
        return nil
    }

    /// A moment's word that the page got there, which goes by itself.
    ///
    /// Seen, because it is the only answer a share gets until the app is opened; gone
    /// without a tap, because the reader is in the middle of a page and a button would be
    /// a tap that decides nothing. An alert rather than a drawn card so it looks and reads
    /// out like the system's own, however the host presents this view.
    private func confirm() async {
        let alert = UIAlertController(
            title: String(localized: "share.saved"), message: nil, preferredStyle: .alert
        )
        present(alert, animated: true)
        try? await Task.sleep(for: .seconds(1.2))
    }

    private func explain(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "share.ok"), style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        present(alert, animated: true)
    }
}
