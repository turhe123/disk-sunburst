import AppKit
import SwiftUI

/// Main-actor state for the window: the scanned tree, drill-down path, selection,
/// scan progress and the file actions (reveal, open, copy path, trash).
@MainActor
final class ScanModel: ObservableObject {
    @Published private(set) var root: FileNode?
    /// Nodes drilled into below the root; the last one is the chart center.
    @Published private(set) var path: [FileNode] = []
    @Published var selected: FileNode?
    @Published private(set) var rootURL: URL?
    @Published private(set) var isScanning = false
    @Published private(set) var progress = ScanProgress()
    @Published private(set) var freeSpace: Int64?
    @Published var pendingTrash: FileNode?
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?
    private var scanToken = UUID()

    var center: FileNode? { path.last ?? root }
    var breadcrumb: [FileNode] { root.map { [$0] + path } ?? [] }
    /// The item that toolbar/menu actions apply to.
    var actionTarget: FileNode? { selected ?? center }
    var canTrash: Bool {
        guard let target = actionTarget, target.url != nil, !isScanning else { return false }
        return target.id != root?.id
    }

    static let donateURL = URL(string: "https://ko-fi.com/leodavidai")!
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    // MARK: Scanning

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or volume to scan"
        if panel.runModal() == .OK, let url = panel.url { scan(url) }
    }

    func rescan() {
        if let rootURL { scan(rootURL) }
    }

    func scan(_ url: URL) {
        cancel()
        let token = UUID()
        scanToken = token
        rootURL = url
        root = nil
        path = []
        selected = nil
        progress = ScanProgress()
        isScanning = true
        freeSpace = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        let defaults = UserDefaults.standard
        let depth = max(2, defaults.object(forKey: "maxDepth") as? Int ?? 5)
        let scanner = DiskScanner(rootURL: url,
                                  showHidden: defaults.bool(forKey: "showHidden"),
                                  packagesAsItems: defaults.object(forKey: "packagesAsItems") as? Bool ?? true,
                                  snapshotDepth: depth + 1) { [weak self] node, progress, done in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.scanToken == token else { return }
                    self.apply(node, progress: progress, done: done)
                }
            }
        }
        task = Task.detached(priority: .userInitiated) { scanner.run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        scanToken = UUID()
        isScanning = false
    }

    private func apply(_ node: FileNode, progress: ScanProgress, done: Bool) {
        root = node
        self.progress = progress
        if done { isScanning = false; task = nil }
        remapPath()
    }

    /// Re-resolves the drill-down path and selection against a new snapshot by id.
    private func remapPath() {
        var resolved: [FileNode] = []
        var current = root
        for old in path {
            guard let next = current?.children.first(where: { $0.id == old.id }) else { break }
            resolved.append(next)
            current = next
        }
        path = resolved
        if let sel = selected {
            selected = center?.id == sel.id ? center : center?.children.first { $0.id == sel.id }
        }
    }

    // MARK: Navigation

    func drill(into node: FileNode) {
        guard node.isDirectory, !node.isAggregate, let center,
              center.children.contains(where: { $0.id == node.id }) else { selected = node; return }
        path.append(node)
        selected = nil
    }

    func goUp() {
        guard !path.isEmpty else { return }
        let left = path.removeLast()
        selected = left
    }

    func jump(to node: FileNode) {
        if node.id == root?.id { path = [] } else if let i = path.firstIndex(where: { $0.id == node.id }) {
            path = Array(path.prefix(through: i))
        }
        selected = nil
    }

    // MARK: Actions

    func reveal() {
        guard let url = actionTarget?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open() {
        guard let url = actionTarget?.url else { return }
        NSWorkspace.shared.open(url)
    }

    func copyPath() {
        guard let url = actionTarget?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func requestTrash() {
        guard canTrash else {
            if actionTarget?.id == root?.id { errorMessage = "The scan root itself can't be moved to the Trash." }
            return
        }
        pendingTrash = actionTarget
    }

    func confirmTrash(_ node: FileNode) {
        pendingTrash = nil
        guard let url = node.url, node.id != root?.id else { return }
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let error {
                        self.errorMessage = "Couldn't move “\(node.name)” to the Trash: \(error.localizedDescription)"
                    } else {
                        self.root = self.root?.removing(node)
                        if self.selected?.id == node.id { self.selected = nil }
                        self.remapPath()
                    }
                }
            }
        }
    }

    func openFullDiskAccessSettings() {
        if let url = Self.fullDiskAccessURL { NSWorkspace.shared.open(url) }
    }

    func openDonate() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
    }
}

/// Byte formatting helper shared by the views.
enum Bytes {
    static func format(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
