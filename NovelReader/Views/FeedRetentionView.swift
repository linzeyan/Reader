import SwiftUI

/// How much of each subscription is kept, and how long the app waits before acting on it.
///
/// Three pickers rather than one "manage storage" number, because the three answer
/// different worries: how much room this takes, how sure the reader is that they have
/// finished with an article, and whether an unread article is a thing that expires at all.
/// The wording throughout says what will be *deleted* — this screen has consequences no
/// other settings screen in the app has.
struct FeedRetentionView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.retentionSettings

        List {
            Section {
                Picker("retention.keep", selection: $settings.keep) {
                    ForEach(FeedRetentionSettings.Keep.allCases) { keep in
                        Text(keep.nameKey).tag(keep)
                    }
                }
                .accessibilityIdentifier("retention.keep")
            } footer: {
                Text("retention.keep.footer")
            }

            // Both hidden when nothing is ever deleted: they are the terms of a deletion
            // that is not happening, and a screen that keeps offering them says the
            // opposite of what the setting above it just said.
            if settings.keep != .everything {
                Section {
                    Picker("retention.grace", selection: $settings.grace) {
                        ForEach(FeedRetentionSettings.Grace.allCases) { grace in
                            Text(grace.nameKey).tag(grace)
                        }
                    }
                    .accessibilityIdentifier("retention.grace")
                } footer: {
                    Text("retention.grace.footer")
                }

                Section {
                    Picker("retention.unread", selection: $settings.unread) {
                        ForEach(FeedRetentionSettings.UnreadRetention.allCases) { unread in
                            Text(unread.nameKey).tag(unread)
                        }
                    }
                    .accessibilityIdentifier("retention.unread")
                } footer: {
                    Text("retention.unread.footer")
                }

                Section {
                    Text("retention.protected.footer")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("retention.protected")
                }
            }
        }
        .navigationTitle("retention.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}
