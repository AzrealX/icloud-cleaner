# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

iCloud Cleaner is a SwiftUI windowed macOS app (Dock icon, single main window; quits when its last window closes). It caps how much iCloud Drive data is kept on disk locally. When local copies exceed a limit, it calls `FileManager.evictUbiquitousItem` on the least recently used files. This is Finder's "Remove Download": the files stay in iCloud and nothing is deleted. Activity is logged to `~/Library/Logs/iCloudCleaner.log`.

## Build & run

The machine has only the Swift **Command Line Tools**, not Xcode. Use SwiftPM with `build.sh`; there is no `.xcodeproj`.

- `./build.sh` runs `swift build -c release`, assembles `build/iCloud Cleaner.app` (writes Info.plist, bundle id `local.icloudcleaner`), and ad-hoc codesigns it.
- `./build.sh install` also kills the running instance, copies the app to `~/Applications`, and launches it.
- `.build/release/ICloudCleaner --dry-run` is a read-only scan that prints the local total and what would be evicted, then exits. Override settings for one run without persisting them through the argument domain, e.g. `--dry-run -limitGB 1`. Use this to verify scan or plan logic against real data. Never evict the user's files to test.
- There are no tests or linter.
- The `ld: warning: search path ... not found` lines during build are expected with the CLT toolchain.

## Toolchain constraints

- The `Package.swift` tools version must be ≥ 6.0 to use `.macOS(.v15)`. The target uses `.swiftLanguageMode(.v5)` to avoid strict-concurrency errors.
- **Don't use `@State` (or other SwiftUI attribute macros).** In this SDK they are macros, and the CLT doesn't ship the `SwiftUIMacros` plugin, so the build fails. Keep view state in `ObservableObject`s (`@Published`) and use `@StateObject`/`@EnvironmentObject`/`@ObservedObject`, which work. For example, the "Open at login" toggle lives in `Preferences.launchAtLogin` for this reason.

## Architecture

All code is in `Sources/ICloudCleaner/`.

- **`Preferences`** (MainActor `ObservableObject`) holds every setting as `@Published` and persists it to `UserDefaults` in `didSet`. Defaults are registered in `init`. `prefs.rules` produces a `Sendable` `Rules` snapshot, the only thing passed to background work.
- **`Scanner` / `Cleaner`** (in `Scanner.swift`) are pure, nonisolated enums. `Scanner.scan(rules)` walks the roots (default `~/Library/Mobile Documents/com~apple~CloudDocs`). It skips hidden files and excluded prefixes, counts only items whose `ubiquitousItemDownloadingStatus` is `.current`/`.downloaded`, and treats packages (e.g. `.pages`) as single items. An item is `evictable` only when it is fully uploaded and not currently uploading. `lastUsed` is max(access date, modification date). `Cleaner.plan(scan, rules, force:)` sorts eligible items LRU-first and picks them until the total falls to `targetBytes`. Without `force`, it does nothing unless the total is over `limitBytes`.
- **`AppState`** (MainActor) owns `Preferences` and runs a periodic `Task` loop (`startLoop()` runs a cycle immediately, then sleeps for `intervalMinutes`; Settings restarts it when the interval changes). The loop calls `Scanner`/`Cleaner` via `Task.detached`. A `busy` flag serializes operations. Automatic runs (`run(auto: true)`) clean only when over the limit and auto-clean is on. Manual "Clean Now" (`auto: false`) forces trimming to the target.
- **`CleanerApp`** declares the `main` `Window` scene (`MainView`) plus the `files`, `settings` and `preview` `Window` scenes (`.defaultLaunchBehavior(.suppressed)` so they don't open at launch). Views open them with `openWindow(id:)` + `NSApp.activate()`. An `AppDelegate` (via `@NSApplicationDelegateAdaptor`) quits the app when the last window closes, so automatic cleaning runs only while it's open. It also handles `--dry-run` in `init`.
- **`FilesView.swift`** is the "Local Files" window. It shows an analysis of `lastScan` (by type via `UTType`, by last-used age, by top folder, using Swift Charts) and a sortable, searchable, multi-select `Table` (state in `FilesModel`). Selected evictable items go to `AppState.evictSelected` after a confirmation. `evict` drops evicted URLs from `lastScan`, so views update without a rescan.
- **`Views.swift`** contains `MainView`, `SettingsView`, and `PreviewView`. The preview shows `Cleaner.plan(..., force: true)` and evicts exactly that list.
