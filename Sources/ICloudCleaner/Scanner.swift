import Foundation

struct LocalItem: Sendable, Identifiable {
    let url: URL
    let size: Int64
    let lastUsed: Date
    /// Fully uploaded to iCloud, so removing the local copy loses nothing.
    let evictable: Bool
    var id: URL { url }
}

struct ScanResult: Sendable {
    let items: [LocalItem]
    let totalBytes: Int64
    let date: Date
}

enum Scanner {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .contentAccessDateKey, .contentModificationDateKey,
    ]

    /// Finds every iCloud item under the rule roots that currently has a local copy.
    static func scan(_ rules: Rules) -> ScanResult {
        let fm = FileManager.default
        var items: [LocalItem] = []
        var seen = Set<String>()
        var total: Int64 = 0

        for root in rules.roots {
            guard let walker = fm.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in walker {
                let path = url.path
                if isExcluded(path, rules.excluded) { walker.skipDescendants(); continue }
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let isPackage = v.isPackage ?? false
                if v.isDirectory == true && !isPackage { continue }
                guard v.isUbiquitousItem == true, seen.insert(path).inserted else { continue }
                let status = v.ubiquitousItemDownloadingStatus
                guard status == .current || status == .downloaded else { continue }

                let size = isPackage ? packageSize(url) : Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                let lastUsed = max(v.contentAccessDate ?? .distantPast, v.contentModificationDate ?? .distantPast)
                let evictable = (v.ubiquitousItemIsUploaded ?? false) && !(v.ubiquitousItemIsUploading ?? false)
                items.append(LocalItem(url: url, size: size, lastUsed: lastUsed, evictable: evictable))
                total += size
            }
        }
        return ScanResult(items: items, totalBytes: total, date: .now)
    }

    static func isExcluded(_ path: String, _ excluded: [String]) -> Bool {
        excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func packageSize(_ url: URL) -> Int64 {
        let sizeKeys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: sizeKeys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let v = try? file.resourceValues(forKeys: Set(sizeKeys))
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return total
    }
}

enum Cleaner {
    /// Picks the least recently used evictable items to bring local usage down to the target.
    /// Without `force`, nothing is planned until usage exceeds the limit.
    static func plan(_ scan: ScanResult, _ rules: Rules, force: Bool, now: Date = .now) -> [LocalItem] {
        guard force || scan.totalBytes > rules.limitBytes else { return [] }
        var toFree = scan.totalBytes - rules.targetBytes
        let cutoff = now.addingTimeInterval(-rules.minAge)
        var picked: [LocalItem] = []
        for item in scan.items.filter({ $0.evictable && $0.lastUsed < cutoff }).sorted(by: { $0.lastUsed < $1.lastUsed }) {
            guard toFree > 0 else { break }
            picked.append(item)
            toFree -= item.size
        }
        return picked
    }

    struct Outcome: Sendable {
        var evicted = 0
        var freed: Int64 = 0
        var evictedURLs = Set<URL>()
        var failures: [String] = []
    }

    /// Removes local copies only; the files stay in iCloud Drive and re-download on demand.
    static func evict(_ items: [LocalItem]) -> Outcome {
        var outcome = Outcome()
        for item in items {
            do {
                try FileManager.default.evictUbiquitousItem(at: item.url)
                outcome.evicted += 1
                outcome.freed += item.size
                outcome.evictedURLs.insert(item.url)
            } catch {
                outcome.failures.append("\(item.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return outcome
    }
}
