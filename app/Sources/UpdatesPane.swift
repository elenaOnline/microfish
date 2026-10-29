import SwiftUI

// Settings > Updates, in the grouped-Form style of the other panes. The controls write straight to the
// updater (through `UpdateSettingsModel`'s hooks), so they apply immediately like System Settings.
// Labels are HintLabels so a disabled row dims its text the way the other panes do.

struct UpdatesPane: View {
    @Bindable var model: UpdateSettingsModel = .shared
    var body: some View {
        // Read here, not inside the Bindings' closures: SwiftUI only tracks what body itself reads.
        let checks = model.automaticChecks, downloads = model.automaticDownloads && model.automaticChecks, beta = model.beta
        Form {
            if !model.available {
                Section { Text("Updates are checked by the installed Microfish app. This copy isn’t running from an app bundle with an update feed.").foregroundStyle(.secondary) }
            }
            Section("Software Update") {
                LabeledContent("Current version") { Text(model.version).foregroundStyle(.secondary).textSelection(.enabled) }
                LabeledContent {
                    if model.checking {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
                    } else {
                        Button(model.waitingVersion == nil ? "Check Now" : "View Update…") { model.onCheckNow?() }
                            .disabled(!model.canCheck || !model.available)
                    }
                } label: {
                    HintLabel(model.waitingVersion.map { "Version \($0) is available" } ?? "Last checked", model.waitingVersion == nil ? model.lastCheckText : "Last checked \(model.lastCheckText)")
                }
            }
            Section("Automatic Updates") {
                Toggle(isOn: Binding(get: { checks }, set: { model.onSetAutomaticChecks?($0) })) { HintLabel("Automatically check for updates") }
                    .disabled(!model.available)
                Toggle(isOn: Binding(get: { downloads }, set: { model.onSetAutomaticDownloads?($0) })) { HintLabel("Automatically download and install updates") }
                    .disabled(!model.available || !checks || !model.canAutomaticallyDownload)
            }
            Section("Channel") {
                Toggle(isOn: Binding(get: { beta }, set: { model.onSetBeta?($0) })) {
                    HintLabel("Get beta updates", "Pre-release versions, for testing; they can be unstable. Turning this off keeps the installed version until a newer stable one is released.")
                }
                .disabled(!model.available)
            }
        }
        .toggleStyle(.switch)
    }
}
