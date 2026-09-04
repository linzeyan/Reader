import SwiftUI
import UniformTypeIdentifiers

/// Writing the library out to a file, and putting one back.
///
/// Its own screen rather than two rows under the sync toggle, and the reason is the two
/// footers: what a backup holds and what it deliberately does not is the whole of what
/// someone needs to know before trusting one, and it cannot be said in a row's subtitle.
/// The restore's own footer says the other half — that it merges — because "will this
/// wipe what I have" is the question that stops people trying it.
struct BackupView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var exporting = false
    @State private var picking = false
    /// Built when the button is pressed rather than in `body`: this is the whole library
    /// encoded, and `body` runs again on every state change on this screen.
    @State private var document: BackupDocument?
    @State private var outcome: LibraryBackup.Outcome?

    var body: some View {
        Form {
            Section {
                Button("backup.export", systemImage: "square.and.arrow.up") {
                    do {
                        document = BackupDocument(try env.backupData())
                        exporting = true
                    } catch {
                        env.report(error)
                    }
                }
                .accessibilityIdentifier("backup.export")
            } footer: {
                Text("backup.export.footer")
            }

            Section {
                Button("backup.restore", systemImage: "square.and.arrow.down") {
                    picking = true
                }
                .accessibilityIdentifier("backup.restore")
            } footer: {
                Text("backup.restore.footer")
            }
        }
        .navigationTitle("backup.title")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $exporting,
            document: document,
            contentType: .json,
            defaultFilename: filename
        ) { result in
            if case .failure(let error) = result { env.report(error) }
            document = nil
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                do { outcome = try env.restoreBackup(from: url) } catch { env.report(error) }
            case .failure(let error):
                env.report(error)
            }
        }
        .alert(
            "backup.restored.title",
            isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })
        ) {
            Button("common.done") { outcome = nil }
        } message: {
            if let outcome { Text(summary(of: outcome)) }
        }
    }

    /// Dated for the reason the subscription export is: a backup is kept, and two of them
    /// in a folder have to be tellable apart by more than the order they were saved in.
    private var filename: String {
        let day = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        return "novel-reader-backup-\(day).json"
    }

    /// Counts, and then the one thing that needs explaining.
    ///
    /// The skipped line is not an error and does not read as one: it says what to do about
    /// it, because there is something — import those files again and restore the same
    /// backup — and a reader who is not told will assume the marks are gone.
    private func summary(of outcome: LibraryBackup.Outcome) -> String {
        var text = String(
            localized: "backup.restored \(outcome.books) \(outcome.marks) \(outcome.rules)"
        )
        if outcome.skippedImports > 0 {
            text += "\n\n" + String(localized: "backup.restored.skipped \(outcome.skippedImports)")
        }
        return text
    }
}

/// The backup as a file the save sheet can write.
///
/// Held in memory like the subscription list, and for the same reason: what is in it is
/// the library's *index* — rows, positions, marks — never a chapter's text, so a large
/// library is a large JSON file rather than a large book.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    private let data: Data

    init(_ data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        // Never read back through this type. Restoring reads the file the picker handed
        // over, which is how it can also accept a backup that arrived from anywhere else.
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
