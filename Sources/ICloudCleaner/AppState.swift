import Foundation

struct Activity: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

@MainActor
final class AppState: ObservableObject {
    let prefs = Preferences()
    @Published var lastScan: ScanResult?
    @Published var busy = false
    @Published var activity: [Activity] = []
    @Published var preview: [LocalItem] = []

    private var loop: Task<Void, Never>?
    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/iCloudCleaner.log")

    init() { startLoop() }

    var isOverLimit: Bool { (lastScan?.totalBytes ?? 0) > prefs.limitBytes }

    /// (Re)starts the periodic check; runs one immediately.
    func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.run(auto: true)
                let minutes = self?.prefs.intervalMinutes ?? 60
                try? await Task.sleep(for: .seconds(Double(max(minutes, 1)) * 60))
            }
        }
    }

    func scan() async -> ScanResult {
        let rules = prefs.rules
        let result = await Task.detached { Scanner.scan(rules) }.value
        lastScan = result
        return result
    }

    /// Automatic runs only clean when over the limit (and auto-clean is on);
    /// manual runs trim down to the target whenever usage is above it.
    func run(auto: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        let result = await scan()
        if auto && !prefs.autoClean { return }
        let plan = Cleaner.plan(result, prefs.rules, force: !auto)
        if plan.isEmpty {
            if !auto { log("Nothing to clean — \(formatBytes(result.totalBytes)) stored locally") }
            return
        }
        await evict(plan)
    }

    /// Re-reads local usage without cleaning anything.
    func rescan() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        _ = await scan()
    }

    /// Removes the local copies of exactly these items (e.g. a selection in the Files window).
    func evictSelected(_ items: [LocalItem]) async {
        guard !busy, !items.isEmpty else { return }
        busy = true
        defer { busy = false }
        await evict(items)
    }

    func buildPreview() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        preview = Cleaner.plan(await scan(), prefs.rules, force: true)
    }

    func evictPreview() async {
        guard !busy, !preview.isEmpty else { return }
        busy = true
        defer { busy = false }
        await evict(preview)
        preview = []
        _ = await scan()
    }

    private func evict(_ items: [LocalItem]) async {
        let outcome = await Task.detached { Cleaner.evict(items) }.value
        log("Removed \(outcome.evicted) local copies, freed \(formatBytes(outcome.freed))")
        for failure in outcome.failures.prefix(5) { log("Skipped \(failure)") }
        if outcome.failures.count > 5 { log("…and \(outcome.failures.count - 5) more skipped") }
        if let scan = lastScan {
            lastScan = ScanResult(
                items: scan.items.filter { !outcome.evictedURLs.contains($0.url) },
                totalBytes: scan.totalBytes - outcome.freed, date: scan.date
            )
        }
    }

    private func log(_ message: String) {
        let entry = Activity(date: .now, message: message)
        activity.insert(entry, at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }

        let line = "\(ISO8601DateFormatter().string(from: entry.date))  \(message)\n"
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: Self.logURL, atomically: true, encoding: .utf8)
        }
    }
}
