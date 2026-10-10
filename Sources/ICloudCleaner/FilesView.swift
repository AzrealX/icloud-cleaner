import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

enum FileKind: String, CaseIterable, Identifiable {
    case documents = "Documents", images = "Images", videos = "Videos", audio = "Audio", archives = "Archives", other = "Other"
    var id: String { rawValue }

    init(_ url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension) else { self = .other; return }
        if type.conforms(to: .image) { self = .images }
        else if type.conforms(to: .audio) { self = .audio }
        else if type.conforms(to: .audiovisualContent) { self = .videos }
        else if type.conforms(to: .archive) || type.conforms(to: .diskImage) { self = .archives }
        else if [UTType.pdf, .text, .compositeContent, .presentation, .spreadsheet].contains(where: type.conforms) { self = .documents }
        else { self = .other }
    }

    var symbol: String {
        switch self {
        case .documents: "doc.text"
        case .images: "photo"
        case .videos: "film"
        case .audio: "waveform"
        case .archives: "archivebox"
        case .other: "doc"
        }
    }
}

enum AgeBucket: String, CaseIterable {
    case week = "Past week", month = "Past month", halfYear = "1–6 months", year = "6–12 months", older = "Over a year"

    init(_ date: Date, now: Date = .now) {
        let days = now.timeIntervalSince(date) / 86_400
        self = days < 7 ? .week : days < 30 ? .month : days < 182 ? .halfYear : days < 365 ? .year : .older
    }
}

struct FileRow: Identifiable {
    let item: LocalItem
    let name: String
    /// Containing folder, relative to the managed root it was found under.
    let folder: String
    /// First-level folder, used to group sizes in the analysis.
    let topFolder: String
    let kind: FileKind
    var kindName: String { kind.rawValue }
    var id: URL { item.url }
    var size: Int64 { item.size }
    var lastUsed: Date { item.lastUsed }
    var evictable: Bool { item.evictable }
}

@MainActor
final class FilesModel: ObservableObject {
    @Published var rows: [FileRow] = []
    @Published var selection = Set<URL>()
    @Published var sortOrder = [KeyPathComparator(\FileRow.size, order: .reverse)]
    @Published var search = ""
    @Published var kind: FileKind?
    @Published var confirming = false

    func load(_ scan: ScanResult?, roots: [String]) {
        let roots = roots.sorted { $0.count > $1.count }
        rows = (scan?.items ?? []).map { item in
            let path = item.url.path
            let root = roots.first { path.hasPrefix($0 + "/") }
            let rootName = root.map { $0 == Preferences.iCloudDrive ? "iCloud Drive" : URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            let relative = root.map { String(path.dropFirst($0.count + 1)) } ?? path
            let parents = relative.split(separator: "/").dropLast().map(String.init)
            return FileRow(
                item: item,
                name: item.url.lastPathComponent,
                folder: ([rootName] + parents).joined(separator: " › "),
                topFolder: ([rootName] + parents.prefix(1)).joined(separator: " › "),
                kind: FileKind(item.url)
            )
        }
        selection.formIntersection(rows.map(\.id))
    }

    var visibleRows: [FileRow] {
        rows.filter { row in
            (kind == nil || row.kind == kind)
                && (search.isEmpty || row.name.localizedCaseInsensitiveContains(search) || row.folder.localizedCaseInsensitiveContains(search))
        }
        .sorted(using: sortOrder)
    }

    var selectedRows: [FileRow] { rows.filter { selection.contains($0.id) } }

    /// Selects visible files that can be removed and weren't used within `days`.
    func selectUnused(days: Int) {
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        selection = Set(visibleRows.filter { $0.evictable && $0.lastUsed < cutoff }.map(\.id))
    }
}

struct FilesView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    @StateObject private var model = FilesModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.rows.isEmpty {
                if state.busy || state.lastScan == nil {
                    ProgressView("Scanning iCloud Drive…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("No iCloud Drive files are downloaded locally.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                AnalysisView(rows: model.rows)
                Divider()
                filters
                FileTable(model: model)
            }
            footer
        }
        .padding()
        .frame(minWidth: 900, minHeight: 680)
        .onReceive(state.$lastScan) { model.load($0, roots: prefs.roots) }
        .task { if state.lastScan == nil { await state.rescan() } }
        .confirmationDialog(confirmTitle, isPresented: $model.confirming) {
            Button("Remove Downloads") {
                let items = model.selectedRows.filter(\.evictable).map(\.item)
                Task {
                    await state.evictSelected(items)
                    model.selection = []
                }
            }
        } message: {
            Text(confirmMessage)
        }
    }

    private var filters: some View {
        HStack {
            TextField("Search names and folders", text: $model.search)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
            Picker("Type", selection: $model.kind) {
                Text("All types").tag(FileKind?.none)
                ForEach(FileKind.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag(FileKind?.some($0)) }
            }
            .fixedSize()
            Spacer()
            Menu("Select") {
                Button("All Shown") { model.selection = Set(model.visibleRows.map(\.id)) }
                Divider()
                Button("Unused for 1+ Month") { model.selectUnused(days: 30) }
                Button("Unused for 6+ Months") { model.selectUnused(days: 182) }
                Button("Unused for 1+ Year") { model.selectUnused(days: 365) }
                Divider()
                Button("None") { model.selection = [] }
            }
            .fixedSize()
        }
    }

    private var footer: some View {
        let selected = model.selectedRows
        let removable = selected.filter(\.evictable)
        return HStack {
            if selected.isEmpty {
                Text("\(model.visibleRows.count) files shown").foregroundStyle(.secondary)
            } else {
                Text("\(selected.count) selected · \(formatBytes(removable.reduce(0) { $0 + $1.size })) can be freed")
            }
            if state.busy { ProgressView().controlSize(.small) }
            Spacer()
            Button("Rescan") { Task { await state.rescan() } }
                .disabled(state.busy)
            Button("Remove Downloads…") { model.confirming = true }
                .buttonStyle(.borderedProminent)
                .disabled(removable.isEmpty || state.busy)
        }
    }

    private var confirmTitle: String {
        let removable = model.selectedRows.filter(\.evictable)
        return "Remove local copies of \(removable.count) files (\(formatBytes(removable.reduce(0) { $0 + $1.size })))?"
    }

    private var confirmMessage: String {
        let skipped = model.selectedRows.filter { !$0.evictable }.count
        var text = "They stay in iCloud Drive and download again when you open them."
        if skipped > 0 { text += " \(skipped) selected files haven't finished uploading and will be skipped." }
        return text
    }
}

private struct FileTable: View {
    @ObservedObject var model: FilesModel

    var body: some View {
        Table(model.visibleRows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { row in
                Label(row.name, systemImage: row.kind.symbol).help(row.id.path)
            }
            TableColumn("Folder", value: \.folder) { Text($0.folder).foregroundStyle(.secondary) }
            TableColumn("Type", value: \.kindName) { Text($0.kindName) }.width(80)
            TableColumn("Size", value: \.size) { Text(formatBytes($0.size)).monospacedDigit() }.width(80)
            TableColumn("Last used", value: \.lastUsed) { row in
                if row.lastUsed == .distantPast { Text("Unknown") } else { Text(row.lastUsed, format: .dateTime.year().month().day()) }
            }
            .width(100)
            TableColumn("iCloud") { row in
                if row.evictable {
                    Label("Uploaded", systemImage: "checkmark.icloud").foregroundStyle(.secondary)
                } else {
                    Label("Uploading", systemImage: "arrow.up.icloud").foregroundStyle(.orange)
                }
            }
            .width(100)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
            Button("Remove Download…") {
                model.selection = urls
                model.confirming = true
            }
            .disabled(!model.rows.contains { urls.contains($0.id) && $0.evictable })
        }
    }
}

private struct AnalysisView: View {
    let rows: [FileRow]

    private struct Slice: Identifiable {
        let name: String
        let bytes: Int64
        let count: Int
        var id: String { name }
    }

    private func total(_ rows: some Sequence<FileRow>) -> Int64 { rows.reduce(0) { $0 + $1.size } }

    var body: some View {
        let byKind = FileKind.allCases.compactMap { kind -> Slice? in
            let matching = rows.filter { $0.kind == kind }
            return matching.isEmpty ? nil : Slice(name: kind.rawValue, bytes: total(matching), count: matching.count)
        }
        let byAge = AgeBucket.allCases.map { bucket in
            let matching = rows.filter { AgeBucket($0.lastUsed) == bucket }
            return Slice(name: bucket.rawValue, bytes: total(matching), count: matching.count)
        }
        let byFolder = Dictionary(grouping: rows, by: \.topFolder)
            .map { Slice(name: $0.key, bytes: total($0.value), count: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
        let all = total(rows)
        let pending = rows.filter { !$0.evictable }
        let stale = rows.filter { $0.evictable && AgeBucket($0.lastUsed) >= .halfYear }

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Tile(title: "Stored locally", value: formatBytes(all), detail: "\(rows.count) files")
                Tile(title: "Largest file", value: formatBytes(rows.map(\.size).max() ?? 0),
                     detail: rows.max { $0.size < $1.size }?.name ?? "")
                Tile(title: "Unused 6+ months", value: formatBytes(total(stale)), detail: "\(stale.count) files could be freed")
                Tile(title: "Still uploading", value: formatBytes(total(pending)), detail: "\(pending.count) files, can't be removed yet")
            }

            HStack(alignment: .top, spacing: 20) {
                Panel(title: "By type") {
                    Chart(byKind) { slice in
                        SectorMark(angle: .value("Size", Double(slice.bytes)), innerRadius: .ratio(0.6), angularInset: 1)
                            .foregroundStyle(by: .value("Type", slice.name))
                    }
                    .chartLegend(position: .trailing, alignment: .center)
                }
                Panel(title: "By last used") {
                    Chart(byAge) { slice in
                        BarMark(x: .value("Size", Double(slice.bytes)), y: .value("Last used", slice.name))
                            .annotation(position: .trailing) {
                                Text(formatBytes(slice.bytes)).font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                    .chartXAxis(.hidden)
                }
                Panel(title: "Largest folders") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(byFolder.prefix(5)) { slice in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(slice.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(formatBytes(slice.bytes)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.caption)
                                ProgressView(value: Double(slice.bytes), total: Double(max(all, 1)))
                            }
                        }
                    }
                }
            }
            .frame(height: 150)
        }
    }
}

extension AgeBucket: Comparable {
    static func < (a: AgeBucket, b: AgeBucket) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

private struct Tile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content.frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }
}
