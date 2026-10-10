import AppKit
import SwiftUI

@main
struct CleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    init() {
        // `ICloudCleaner --dry-run` prints what a cleanup would do, without changing anything.
        if CommandLine.arguments.contains("--dry-run") {
            MainActor.assumeIsolated { Self.dryRun() }
            exit(0)
        }
    }

    var body: some Scene {
        Window("iCloud Cleaner", id: "main") {
            MainView()
                .environmentObject(state)
                .environmentObject(state.prefs)
        }
        .windowResizability(.contentSize)

        Window("iCloud Cleaner Settings", id: "settings") {
            SettingsView()
                .environmentObject(state)
                .environmentObject(state.prefs)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Local Files", id: "files") {
            FilesView()
                .environmentObject(state)
                .environmentObject(state.prefs)
        }
        .defaultLaunchBehavior(.suppressed)

        Window("Cleanup Preview", id: "preview") {
            PreviewView().environmentObject(state)
        }
        .defaultLaunchBehavior(.suppressed)
    }

    @MainActor
    private static func dryRun() {
        let rules = Preferences().rules
        let result = Scanner.scan(rules)
        let plan = Cleaner.plan(result, rules, force: true)
        print("Local iCloud copies: \(formatBytes(result.totalBytes)) in \(result.items.count) items")
        print("Limit: \(formatBytes(rules.limitBytes)), target: \(formatBytes(rules.targetBytes))")
        print("Would remove \(plan.count) local copies (\(formatBytes(plan.reduce(0) { $0 + $1.size }))):")
        for item in plan.prefix(25) {
            print("  \(formatBytes(item.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.url.path)")
        }
        if plan.count > 25 { print("  …and \(plan.count - 25) more") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Closing the window quits the app (automatic cleaning only runs while it's open).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
