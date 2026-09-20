import SwiftUI
import UniformTypeIdentifiers

/// Turning the trace on, watching it catch something, and sending it.
///
/// Its own screen at the bottom of the settings list, beside the version number, because
/// that is where "about this app" lives and this is not one of the five things a reader
/// came to settings to adjust. Nobody finds this on their own; they are pointed at it.
///
/// Three rows, and the footers are half of what the screen is: a recording that cannot be
/// stopped without losing it, and a file that leaves the phone, both need saying out loud
/// before anybody touches the switch.
struct DiagnosticsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var exporting = false
    @State private var document: TraceDocument?
    @State private var confirmingStop = false
    /// Set by the "export first" answer to the stop question, so that finishing the
    /// export is what finally stops the recording — the reader asked for one thing, not
    /// for a save sheet followed by a second go at the switch.
    @State private var stopAfterExport = false

    var body: some View {
        Form {
            Section {
                Toggle("trace.record", isOn: recording)
                    .accessibilityIdentifier("trace.record")
            } footer: {
                Text("trace.record.footer")
            }

            Section {
                LabeledContent("trace.size", value: env.trace.size.formatted(.byteCount(style: .file)))
                Button("trace.export", systemImage: "square.and.arrow.up") { export() }
                    .disabled(env.trace.isEmpty)
                    .accessibilityIdentifier("trace.export")
            } footer: {
                Text("trace.privacy.footer")
            }
        }
        .navigationTitle("trace.title")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // The only number on this screen, and it moves while somebody is looking at
            // it: a reader who has just turned recording on came here to watch it catch
            // something, and a size frozen at the moment the screen opened says it did
            // not. Two seconds is slower than the trace's own five-second sample, so the
            // number always has something new to say when it changes.
            while !Task.isCancelled {
                env.trace.refreshSize()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .fileExporter(
            isPresented: $exporting,
            document: document,
            contentType: .plainText,
            defaultFilename: filename
        ) { result in
            switch result {
            case .success:
                if stopAfterExport { env.trace.isOn = false }
            case .failure(let error):
                env.report(error)
            }
            stopAfterExport = false
            document = nil
        }
        .alert("trace.stop.title", isPresented: $confirmingStop) {
            Button("trace.stop.export") {
                stopAfterExport = true
                export()
            }
            Button("trace.stop.discard", role: .destructive) { env.trace.isOn = false }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("trace.stop.message")
        }
    }

    /// The switch, with the one question that has to be asked before it stops.
    ///
    /// Turning the trace off deletes what it recorded, which is the behaviour that was
    /// asked for and the right one — but the reason anybody turned it on was to send it,
    /// and a thumb on a switch is a cheap way to lose an evening that cannot be
    /// reproduced. The toggle springs back while the question is open, which is accurate:
    /// nothing has stopped yet.
    private var recording: Binding<Bool> {
        Binding(
            get: { env.trace.isOn },
            set: { wanted in
                if !wanted, !env.trace.isEmpty {
                    confirmingStop = true
                } else {
                    env.trace.isOn = wanted
                }
            }
        )
    }

    /// Built when the button is pressed rather than in `body`, for the reason the backup
    /// is: this is the whole file in memory, and `body` runs again every two seconds
    /// while this screen is open.
    private func export() {
        document = TraceDocument(env.trace.contents())
        exporting = true
    }

    /// Dated like a backup, and for the same reason: two of these in a folder have to be
    /// tellable apart by more than the order they were saved in.
    private var filename: String {
        let day = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        return "novel-reader-trace-\(day).txt"
    }
}

/// The trace as a file the save sheet can write.
///
/// Plain text rather than a zip or a bundle: it is read by a person, often by being
/// pasted into a message, and anything that has to be unpacked first is one more step
/// between a question and its answer.
struct TraceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    private let data: Data

    init(_ data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        // Never read back through this type. A trace is written by the app and read by a
        // human; nothing in here imports one.
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
