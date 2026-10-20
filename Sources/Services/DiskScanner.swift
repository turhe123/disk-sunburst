import Foundation

/// Immutable snapshot of one item in the scanned tree. `id` is the item's path so
/// nodes stay identifiable across successive snapshots of the same scan.
final class FileNode: Identifiable, Sendable {
    let id: String
    let name: String
    let url: URL?
    let size: Int64
    let isDirectory: Bool
    /// True for the synthetic node that aggregates children beyond the storage limit.
    let isAggregate: Bool
    /// Children sorted by size, largest first.
    let children: [FileNode]

    init(id: String, name: String, url: URL?, size: Int64, isDirectory: Bool,
         isAggregate: Bool = false, children: [FileNode] = []) {
        self.id = id
        self.name = name
        self.url = url
        self.size = size
        self.isDirectory = isDirectory
        self.isAggregate = isAggregate
        self.children = children
    }

    /// Returns a copy of this subtree with `target` removed and ancestor sizes reduced.
    func removing(_ target: FileNode) -> FileNode {
        let prefix = id.hasSuffix("/") ? id : id + "/"
        guard target.id.hasPrefix(prefix) else { return self }
        let kept = children.compactMap { $0.id == target.id ? nil : $0.removing(target) }
        return FileNode(id: id, name: name, url: url, size: max(0, size - target.size),
                        isDirectory: isDirectory, isAggregate: isAggregate,
                        children: kept.sorted { $0.size > $1.size })
    }
}

/// Progress information reported while a scan runs.
struct ScanProgress {
    var currentPath = ""
    var bytes: Int64 = 0
    var unreadable = 0
}

/// Walks a directory tree on a background thread, summing allocated sizes and
/// periodically emitting immutable `FileNode` snapshots. Not thread-safe: one scan per instance.
final class DiskScanner {
    /// Mutable node used only by the scanning thread.
    private final class ScanNode {
        let name: String
        let url: URL
        let isDirectory: Bool
        var size: Int64 = 0
        var children: [ScanNode] = []
        var isAggregate = false
        weak var parent: ScanNode?
        init(name: String, url: URL, isDirectory: Bool, size: Int64 = 0) {
            self.name = name; self.url = url; self.isDirectory = isDirectory; self.size = size
        }
    }

    static let childLimit = 300
    private static let skippedSystemPaths: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm", "/cores"]
    private let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                                          .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
                                          .linkCountKey, .fileIdentifierKey]
    private let rootURL: URL
    private let showHidden: Bool
    private let packagesAsItems: Bool
    private let snapshotDepth: Int
    private let onUpdate: (FileNode, ScanProgress, Bool) -> Void
    private var progress = ScanProgress()
    private var seenHardLinks = Set<UInt64>()
    private var lastEmit = Date.distantPast
    private var root: ScanNode?

    init(rootURL: URL, showHidden: Bool, packagesAsItems: Bool, snapshotDepth: Int,
         onUpdate: @escaping (FileNode, ScanProgress, Bool) -> Void) {
        self.rootURL = rootURL.standardizedFileURL
        self.showHidden = showHidden
        self.packagesAsItems = packagesAsItems
        self.snapshotDepth = snapshotDepth
        self.onUpdate = onUpdate
    }

    /// Runs the scan synchronously. Call from a detached task; honours task cancellation.
    func run() {
        let node = ScanNode(name: rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent,
                            url: rootURL, isDirectory: true)
        root = node
        walk(node)
        guard !Task.isCancelled else { return }
        onUpdate(freeze(node, depthLeft: Int.max), progress, true)
    }

    private var enumerationOptions: FileManager.DirectoryEnumerationOptions {
        showHidden ? [] : [.skipsHiddenFiles]
    }

    private func walk(_ dir: ScanNode) {
        if Task.isCancelled { return }
        progress.currentPath = dir.url.path
        emitIfDue()
        var readFailed = false
        guard let items = FileManager.default.enumerator(
            at: dir.url, includingPropertiesForKeys: keys,
            options: enumerationOptions.union(.skipsSubdirectoryDescendants),
            errorHandler: { _, _ in readFailed = true; return true }) else {
            progress.unreadable += 1
            return
        }
        var fileBytes: Int64 = 0
        for case let url as URL in items {
            if Task.isCancelled { return }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { continue }
            let isPackage = values.isPackage == true && packagesAsItems
            if values.isDirectory == true && !isPackage {
                if Self.skippedSystemPaths.contains(url.path) { continue }
                let child = ScanNode(name: url.lastPathComponent, url: url, isDirectory: true)
                child.parent = dir
                dir.children.append(child)
                walk(child)
            } else {
                let size = isPackage ? packageSize(url) : allocatedSize(values)
                fileBytes += size
                progress.bytes += size
                dir.children.append(ScanNode(name: url.lastPathComponent, url: url,
                                             isDirectory: values.isDirectory == true, size: size))
            }
        }
        if readFailed { progress.unreadable += 1 }
        var ancestor: ScanNode? = dir
        while let node = ancestor { node.size += fileBytes; ancestor = node.parent }
        cap(dir)
    }

    /// Allocated size of a regular file, counting each hard-linked inode once.
    private func allocatedSize(_ values: URLResourceValues) -> Int64 {
        if let links = values.linkCount, links > 1, let fileID = values.fileIdentifier {
            if !seenHardLinks.insert(fileID).inserted { return 0 }
        }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }

    /// Total size of a package (e.g. an app bundle) treated as a single item.
    private func packageSize(_ url: URL) -> Int64 {
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                         options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in items {
            if Task.isCancelled { break }
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true, values.isDirectory != true else { continue }
            total += allocatedSize(values)
        }
        return total
    }

    /// Keeps only the largest children of a finished folder plus one aggregate node.
    private func cap(_ dir: ScanNode) {
        dir.children.sort { $0.size > $1.size }
        guard dir.children.count > Self.childLimit else { return }
        let rest = dir.children[Self.childLimit...]
        let other = ScanNode(name: "\(rest.count) other items", url: dir.url.appendingPathComponent(".disksunburst-other"),
                             isDirectory: false, size: rest.reduce(0) { $0 + $1.size })
        other.isAggregate = true
        dir.children = Array(dir.children.prefix(Self.childLimit)) + [other]
    }

    private func emitIfDue() {
        guard let root, Date().timeIntervalSince(lastEmit) > 0.4 else { return }
        lastEmit = Date()
        onUpdate(freeze(root, depthLeft: snapshotDepth), progress, false)
    }

    /// Converts the mutable tree into an immutable snapshot, limited in depth and breadth.
    private func freeze(_ node: ScanNode, depthLeft: Int) -> FileNode {
        let kids = depthLeft > 0
            ? node.children.sorted { $0.size > $1.size }.prefix(Self.childLimit + 1).map { freeze($0, depthLeft: depthLeft - 1) }
            : []
        return FileNode(id: node.url.path, name: node.name, url: node.isAggregate ? nil : node.url,
                        size: node.size, isDirectory: node.isDirectory, isAggregate: node.isAggregate, children: kids)
    }
}
