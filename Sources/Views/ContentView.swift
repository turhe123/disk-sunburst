import SwiftUI
import UniformTypeIdentifiers

/// The main window: toolbar, breadcrumb, sunburst chart, largest-items list and status bar.
struct ContentView: View {
    @EnvironmentObject private var model: ScanModel
    @AppStorage("maxDepth") private var maxDepth = 5
    @State private var hovered: SunburstArc?
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if let center = model.center {
                breadcrumb
                Divider()
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        SunburstView(center: center, maxDepth: max(2, maxDepth), selectedID: model.selected?.id,
                                     hovered: $hovered,
                                     onTapArc: { arc in
                                         if let node = arc.node { model.drill(into: node) }
                                     },
                                     onTapCenter: { model.goUp() })
                            .padding()
                            .frame(width: geo.size.width * 2 / 3)
                        Divider()
                        ItemListView(center: center)
                    }
                }
                Divider()
                hoverFooter
            } else if model.isScanning {
                ProgressView("Starting scan…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(targeted: dropTargeted)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 820, minHeight: 540)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .toolbar { toolbarContent }
        .confirmationDialog("Move “\(model.pendingTrash?.name ?? "")” to the Trash?",
                            isPresented: Binding(get: { model.pendingTrash != nil },
                                                 set: { if !$0 { model.pendingTrash = nil } }),
                            presenting: model.pendingTrash) { node in
            Button("Move to Trash", role: .destructive) { model.confirmTrash(node) }
            Button("Cancel", role: .cancel) { model.pendingTrash = nil }
        } message: { node in
            Text("\(Bytes.format(node.size)) will be moved to the Trash. You can restore it from there.")
        }
        .alert("DiskSunburst", isPresented: Binding(get: { model.errorMessage != nil },
                                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onDisappear { model.cancel() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goUp() } label: { Label("Up", systemImage: "chevron.up") }
                .keyboardShortcut(.cancelAction)
                .disabled(model.path.isEmpty)
                .help("Go up one level (Esc)")
        }
        ToolbarItemGroup {
            Button { model.chooseFolder() } label: { Label("Choose Folder", systemImage: "folder") }
                .help("Choose a folder to scan (⌘O)")
            Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(model.rootURL == nil)
                .help("Scan the same folder again (⌘R)")
            Button { model.requestTrash() } label: { Label("Move to Trash", systemImage: "trash") }
                .disabled(!model.canTrash)
                .help("Move the selected item to the Trash (Delete)")
            Button { model.openDonate() } label: { Label("Support / Donate ❤️", systemImage: "heart") }
                .help("Support / Donate ❤️")
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.breadcrumb.enumerated()), id: \.element.id) { index, node in
                if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(node.name) { model.jump(to: node) }
                    .buttonStyle(.link)
                    .foregroundStyle(index == model.breadcrumb.count - 1 ? Color.primary : Color.accentColor)
            }
            Spacer()
        }
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var hoverFooter: some View {
        HStack {
            if let arc = hovered {
                Image(systemName: arc.node?.isDirectory == true ? "folder.fill" : "doc.fill").foregroundStyle(arc.color)
                Text(arc.label).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(Bytes.format(arc.size)).monospacedDigit()
                Text(String(format: "%.1f%% of parent", arc.parentSize > 0 ? Double(arc.size) * 100 / Double(arc.parentSize) : 0))
                    .foregroundStyle(.secondary)
            } else {
                Text("Hover an arc for details · click a folder to drill in · click the center to go up")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12).frame(height: 28)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning \(model.progress.currentPath)").lineLimit(1).truncationMode(.middle)
                Text(Bytes.format(model.progress.bytes)).monospacedDigit()
                Button("Cancel") { model.cancel() }.controlSize(.small)
            } else if let root = model.root {
                Text("Scanned: \(Bytes.format(root.size))").monospacedDigit()
            }
            if model.progress.unreadable > 0 {
                Button {
                    model.openFullDiskAccessSettings()
                } label: {
                    Label("\(model.progress.unreadable) folders unreadable — check permissions",
                          systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(.link)
                .help("Grant Full Disk Access in System Settings to read protected folders")
            }
            Spacer()
            if let free = model.freeSpace { Text("Free on volume: \(Bytes.format(free))").monospacedDigit() }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 26)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { model.scan(url) } }
        }
        return true
    }
}

/// Right-hand list of the center's largest children with proportional size bars.
struct ItemListView: View {
    @EnvironmentObject private var model: ScanModel
    let center: FileNode

    var body: some View {
        let largest = center.children.first?.size ?? 1
        List(center.children, selection: Binding(get: { model.selected?.id },
                                                 set: { id in model.selected = center.children.first { $0.id == id } })) { node in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: node.isAggregate ? "ellipsis.circle" : node.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Bytes.format(node.size)).monospacedDigit().foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    Capsule().fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(2, geo.size.width * CGFloat(node.size) / CGFloat(max(1, largest))))
                }
                .frame(height: 4)
            }
            .padding(.vertical, 2)
            .tag(node.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.drill(into: node) }
            .contextMenu {
                Button("Reveal in Finder") { model.selected = node; model.reveal() }
                Button("Open") { model.selected = node; model.open() }
                Button("Copy Path") { model.selected = node; model.copyPath() }
                Divider()
                Button("Move to Trash…") { model.selected = node; model.requestTrash() }
            }
            .disabled(node.isAggregate)
        }
        .listStyle(.inset)
        .overlay {
            if center.children.isEmpty { Text("Empty folder").foregroundStyle(.secondary) }
        }
    }
}

/// Shown before any scan: drop target, quick actions and privacy guidance.
struct EmptyStateView: View {
    @EnvironmentObject private var model: ScanModel
    let targeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "chart.pie").font(.system(size: 64)).foregroundStyle(.tint)
            Text("Drop a folder here or press Choose Folder").font(.title2.weight(.semibold))
            HStack {
                Button("Choose Folder…") { model.chooseFolder() }.keyboardShortcut(.defaultAction)
                Button("Scan Home Folder") { model.scan(FileManager.default.homeDirectoryForCurrentUser) }
            }
            .controlSize(.large)
            VStack(spacing: 6) {
                Text("macOS asks for permission the first time folders like Desktop, Documents or Downloads are read. To scan a whole disk, grant DiskSunburst Full Disk Access in System Settings › Privacy & Security.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                Button("Open Privacy Settings…") { model.openFullDiskAccessSettings() }.buttonStyle(.link)
            }
            .font(.callout)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(24)
        )
    }
}
