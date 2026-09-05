import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Where a reader builds their own page.
///
/// Reached from the theme picker, and it switches the reader onto the custom palette the
/// moment it opens: every control in here changes the page behind the sheet it is
/// presented over, and edits nobody can see are edits nobody can judge.
struct ReaderThemeEditor: View {
    @Bindable var settings: ReaderSettings
    @Environment(AppEnvironment.self) private var env

    /// Which kind of background the controls are showing.
    ///
    /// Held rather than derived from the palette, because a reader who taps 圖片 before
    /// choosing one has said what they are looking for but not yet what it is — and a
    /// derived value would snap the segment back the instant they let go.
    @State private var kind = Kind.colors
    /// The colours to come back to when a picture is swapped out for them again. A
    /// gradient that took four taps to mix must survive a look at a photograph.
    @State private var keptStops = ReaderPalette.light.background.stops
    @State private var photo: PhotosPickerItem?
    @State private var pickingFile = false

    private enum Kind: Hashable {
        case colors, image
    }

    /// Enough to mix a sky or a sunset, few enough that the list stays a list. Past this
    /// the stops are closer together than a screen of text can show.
    private static let maxStops = 5

    var body: some View {
        Form {
            Section { preview.listRowInsets(EdgeInsets()) }

            Section {
                Picker("reader.theme.background", selection: $kind) {
                    Text("reader.theme.background.colors").tag(Kind.colors)
                    Text("reader.theme.background.image").tag(Kind.image)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("reader.theme.background")

                switch kind {
                case .colors: stopRows
                case .image: imageRows
                }
            } header: {
                Text("reader.theme.background")
            } footer: {
                if kind == .colors { Text("reader.theme.gradient.footer") }
            }

            Section {
                ColorPicker("reader.theme.textColor", selection: ink, supportsOpacity: false)
                    .accessibilityIdentifier("reader.theme.textColor")
            }
        }
        .navigationTitle("reader.theme.custom.edit")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            settings.theme = .custom
            let stops = settings.customPalette.background.stops
            kind = stops.isEmpty ? .image : .colors
            if !stops.isEmpty { keptStops = stops }
        }
        .onChange(of: kind) { _, kind in
            // Only one direction acts on its own. Coming back to colours there is
            // something to come back *to*; going the other way there may be no picture
            // yet, and the page should not go blank while the reader looks for one.
            guard kind == .colors else { return }
            settings.customPalette.background = .colors(keptStops)
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await adopt(item) }
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): adopt(contentsOf: url)
            case .failure(let error): env.report(error)
            }
        }
    }

    /// A page of the reader's own text in the reader's own colours.
    ///
    /// Worth the space a picker would otherwise use: a gradient cannot be judged from two
    /// swatches, and this screen is also reachable from Settings, where there is no book
    /// behind it to look at.
    private var preview: some View {
        ZStack {
            ReaderBackgroundView(background: settings.customPalette.background)
            Text("reader.theme.sample")
                .font(settings.font)
                .lineSpacing(settings.lineSpacing)
                .foregroundStyle(settings.customPalette.ink)
                .padding(18)
        }
        .frame(height: 150)
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityIdentifier("reader.theme.preview")
    }

    @ViewBuilder
    private var stopRows: some View {
        let stops = settings.customPalette.background.stops
        ForEach(stops.indices, id: \.self) { index in
            ColorPicker(
                "reader.theme.stop \(index + 1)",
                selection: stop(at: index),
                supportsOpacity: false
            )
        }
        // The last one cannot go: a page has to be painted something, and an empty
        // gradient is a screen with no surface at all.
        .onDelete { offsets in
            var kept = stops
            kept.remove(atOffsets: offsets)
            guard !kept.isEmpty else { return }
            apply(stops: kept)
        }

        Button("reader.theme.addStop") {
            // A copy of the last stop rather than a colour of our own choosing: the new
            // row starts where the gradient currently ends, so nothing on screen jumps
            // until the reader actually picks something.
            apply(stops: stops + [stops.last ?? ReaderPalette.light.foreground])
        }
        .disabled(stops.count >= Self.maxStops)
    }

    @ViewBuilder
    private var imageRows: some View {
        PhotosPicker(selection: $photo, matching: .images) {
            Label("reader.theme.pickPhoto", systemImage: "photo.on.rectangle")
        }
        .accessibilityIdentifier("reader.theme.pickPhoto")

        Button {
            pickingFile = true
        } label: {
            Label("reader.theme.pickFile", systemImage: "folder")
        }
        .accessibilityIdentifier("reader.theme.pickFile")
    }

    // MARK: - Editing

    private var ink: Binding<Color> {
        Binding(
            get: { settings.customPalette.foreground.color },
            set: { settings.customPalette.foreground = ReaderColor($0) }
        )
    }

    private func stop(at index: Int) -> Binding<Color> {
        Binding(
            get: {
                let stops = settings.customPalette.background.stops
                return stops.indices.contains(index) ? stops[index].color : .clear
            },
            set: { colour in
                var stops = settings.customPalette.background.stops
                guard stops.indices.contains(index) else { return }
                stops[index] = ReaderColor(colour)
                apply(stops: stops)
            }
        )
    }

    private func apply(stops: [ReaderColor]) {
        keptStops = stops
        settings.customPalette.background = .colors(stops)
    }

    // MARK: - Pictures

    private func adopt(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else {
            env.report(PictureError.unusable)
            return
        }
        adopt(image)
    }

    private func adopt(contentsOf url: URL) {
        // A file the reader picked lives outside the app's sandbox until it is asked for.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            env.report(PictureError.unusable)
            return
        }
        adopt(image)
    }

    private func adopt(_ image: UIImage) {
        guard let name = ReaderBackgroundStore.save(image) else {
            env.report(PictureError.unusable)
            return
        }
        settings.customPalette.background = .image(name)
        kind = .image
    }

    /// One failure, because to the reader there is one: whatever went wrong between the
    /// picker and the disk, the picture is not on their page.
    private enum PictureError: LocalizedError {
        case unusable

        var errorDescription: String? { String(localized: "reader.theme.imageFailed") }
    }
}
