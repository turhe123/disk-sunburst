import SwiftUI

/// Settings window: scan options, chart depth and the Support / Donate button.
struct SettingsView: View {
    @AppStorage("showHidden") private var showHidden = false
    @AppStorage("packagesAsItems") private var packagesAsItems = true
    @AppStorage("maxDepth") private var maxDepth = 5

    var body: some View {
        Form {
            Section("Scanning") {
                Toggle("Show hidden files", isOn: $showHidden)
                Toggle("Treat packages (such as app bundles) as single items", isOn: $packagesAsItems)
                Text("Scan option changes apply on the next scan or rescan.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Chart") {
                Stepper("Maximum ring depth: \(maxDepth)", value: $maxDepth, in: 2...8)
            }
            Section {
                Button("Support / Donate ❤️") {
                    NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
