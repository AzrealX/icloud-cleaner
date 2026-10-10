import AppKit
import SwiftUI

private func showWindow(_ openWindow: OpenWindowAction, _ id: String) {
    openWindow(id: id)
    NSApp.activate()
}

struct MainView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("iCloud Drive — local copies").font(.headline)

            if let scan = state.lastScan {
                ProgressView(value: min(Double(scan.totalBytes), Double(prefs.limitBytes)), total: Double(prefs.limitBytes))
                    .tint(state.isOverLimit ? .red : .accentColor)
                Text("\(formatBytes(scan.totalBytes)) of \(formatBytes(prefs.limitBytes)) limit")
                Text("Checked \(Text(scan.date, style: .relative)) ago")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Not checked yet").foregroundStyle(.secondary)
            }

            HStack {
                Button("Check Now") { Task { await state.run(auto: true) } }
                Button("Clean Now") { Task { await state.run(auto: false) } }
                if state.busy { ProgressView().controlSize(.small) }
            }
            .disabled(state.busy)

            HStack {
                Button("Browse Files…") { showWindow(openWindow, "files") }
                Button("Preview Cleanup…") { showWindow(openWindow, "preview") }
                Spacer()
                Button("Settings…") { showWindow(openWindow, "settings") }
            }

            Divider()
            Text("Recent activity").font(.caption).foregroundStyle(.secondary)
            List(state.activity) { entry in
                Text("\(Text(entry.date, style: .time))  \(entry.message)")
                    .font(.caption).lineLimit(2)
            }
            .listStyle(.bordered)
            .overlay {
                if state.activity.isEmpty { Text("No activity yet").foregroundStyle(.secondary) }
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 360)
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences

    private let intervals = [15: "15 minutes", 30: "30 minutes", 60: "1 hour", 180: "3 hours", 360: "6 hours", 1440: "1 day"]

    var body: some View {
        Form {
            Section("Limits") {
                TextField("Maximum local size (GB)", value: $prefs.limitGB, format: .number)
                LabeledContent("Trim down to") {
                    HStack {
                        Slider(value: $prefs.targetPercent, in: 50...95, step: 5)
                        Text("\(Int(prefs.targetPercent))% of limit").monospacedDigit().frame(width: 90, alignment: .trailing)
                    }
                }
                Stepper("Keep files used in the last \(prefs.minDaysUnused) days", value: $prefs.minDaysUnused, in: 0...365)
            }

            Section("Schedule") {
                Toggle("Clean automatically when over the limit", isOn: $prefs.autoClean)
                Picker("Check every", selection: $prefs.intervalMinutes) {
                    ForEach(intervals.keys.sorted(), id: \.self) { Text(intervals[$0]!).tag($0) }
                }
                .onChange(of: prefs.intervalMinutes) { state.startLoop() }
                Toggle("Open at login", isOn: $prefs.launchAtLogin)
            }

            Section("Folders to manage") { FolderList(paths: $prefs.roots) }
            Section("Never touch these folders") { FolderList(paths: $prefs.excluded) }

            Text("Only local copies are removed. Files stay in iCloud Drive and download again when you open them. Files that haven't finished uploading are never touched.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
    }
}

private struct FolderList: View {
    @Binding var paths: [String]

    var body: some View {
        ForEach(paths, id: \.self) { path in
            HStack {
                Text(path.replacingOccurrences(of: Preferences.iCloudDrive, with: "iCloud Drive"))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(role: .destructive) { paths.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
        Button("Add Folder…") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            panel.directoryURL = URL(fileURLWithPath: Preferences.iCloudDrive)
            guard panel.runModal() == .OK else { return }
            for url in panel.urls where !paths.contains(url.path) { paths.append(url.path) }
        }
    }
}

struct PreviewView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading) {
            if state.busy && state.preview.isEmpty {
                ProgressView("Scanning iCloud Drive…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.preview.isEmpty {
                Text("Nothing to clean — local copies are already under the target size, or every file was used recently.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("These local copies would be removed (least recently used first). They stay in iCloud.")
                    .foregroundStyle(.secondary)
                Table(state.preview) {
                    TableColumn("Name") { Text($0.url.lastPathComponent).help($0.url.path) }
                    TableColumn("Size") { Text(formatBytes($0.size)) }.width(80)
                    TableColumn("Last used") { Text($0.lastUsed, format: .dateTime.year().month().day()) }.width(110)
                }
                .contextMenu(forSelectionType: LocalItem.ID.self) { urls in
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
                }
            }

            HStack {
                Text("\(state.preview.count) items, \(formatBytes(state.preview.reduce(0) { $0 + $1.size }))")
                Spacer()
                Button("Refresh") { Task { await state.buildPreview() } }
                Button("Remove Downloads") { Task { await state.evictPreview() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.preview.isEmpty || state.busy)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 400)
        .task { await state.buildPreview() }
    }
}
