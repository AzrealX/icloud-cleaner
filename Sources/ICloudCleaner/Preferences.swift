import Foundation
import ServiceManagement

/// Immutable snapshot of the user's settings, safe to hand to background work.
struct Rules: Sendable {
    var limitBytes: Int64
    var targetBytes: Int64
    var minAge: TimeInterval
    var roots: [URL]
    var excluded: [String]
}

@MainActor
final class Preferences: ObservableObject {
    static let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path

    private let defaults = UserDefaults.standard

    /// Cleanup kicks in once local copies exceed this many GB.
    @Published var limitGB: Double { didSet { defaults.set(limitGB, forKey: "limitGB") } }
    /// After cleanup, local copies are trimmed to this percentage of the limit.
    @Published var targetPercent: Double { didSet { defaults.set(targetPercent, forKey: "targetPercent") } }
    /// Files used more recently than this are never removed.
    @Published var minDaysUnused: Int { didSet { defaults.set(minDaysUnused, forKey: "minDaysUnused") } }
    @Published var intervalMinutes: Int { didSet { defaults.set(intervalMinutes, forKey: "intervalMinutes") } }
    @Published var autoClean: Bool { didSet { defaults.set(autoClean, forKey: "autoClean") } }
    @Published var roots: [String] { didSet { defaults.set(roots, forKey: "roots") } }
    @Published var excluded: [String] { didSet { defaults.set(excluded, forKey: "excluded") } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            if launchAtLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    init() {
        defaults.register(defaults: [
            "limitGB": 10.0,
            "targetPercent": 80.0,
            "minDaysUnused": 7,
            "intervalMinutes": 60,
            "autoClean": true,
            "roots": [Self.iCloudDrive],
            "excluded": [String](),
        ])
        limitGB = defaults.double(forKey: "limitGB")
        targetPercent = defaults.double(forKey: "targetPercent")
        minDaysUnused = defaults.integer(forKey: "minDaysUnused")
        intervalMinutes = defaults.integer(forKey: "intervalMinutes")
        autoClean = defaults.bool(forKey: "autoClean")
        roots = defaults.stringArray(forKey: "roots") ?? [Self.iCloudDrive]
        excluded = defaults.stringArray(forKey: "excluded") ?? []
    }

    var limitBytes: Int64 { Int64(limitGB * 1_000_000_000) }

    var rules: Rules {
        Rules(
            limitBytes: limitBytes,
            targetBytes: Int64(Double(limitBytes) * targetPercent / 100),
            minAge: TimeInterval(minDaysUnused) * 86_400,
            roots: roots.map { URL(fileURLWithPath: $0, isDirectory: true) },
            excluded: excluded
        )
    }
}
