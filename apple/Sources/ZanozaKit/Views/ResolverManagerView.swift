import SwiftUI
import UniformTypeIdentifiers

public struct ResolverManagerView: View {
    @ObservedObject var store: ResolverPresetStore
    @Binding var selection: UUID?
    let profile: ConnectionProfile
    let settings: AppSettings
    let isTunnelRunning: Bool
    let physicalInterface: PhysicalInterfaceMonitor.Snapshot

    @State private var importDraft: ResolverImportDraft?
    @State private var isShowingFileImporter = false
    @State private var scanPreset: ResolverPreset?
    @State private var message: String?

    public init(
        store: ResolverPresetStore,
        selection: Binding<UUID?>,
        profile: ConnectionProfile,
        settings: AppSettings,
        isTunnelRunning: Bool,
        physicalInterface: PhysicalInterfaceMonitor.Snapshot
    ) {
        self.store = store
        _selection = selection
        self.profile = profile
        self.settings = settings
        self.isTunnelRunning = isTunnelRunning
        self.physicalInterface = physicalInterface
    }

    public var body: some View {
        List {
            if store.parents.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No resolver presets").font(.headline)
                    Text("Import a file, paste a list, or enter resolver addresses manually.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
            ForEach(store.parents) { parent in
                DisclosureGroup {
                    presetRow(parent, level: 0)
                    ForEach(store.children(of: parent.id)) { child in
                        presetRow(child, level: 1)
                    }
                } label: {
                    Label("\(parent.name) · \(parent.endpoints.count)", systemImage: "folder.fill")
                        .font(.body.weight(.semibold))
                }
            }
        }
        .navigationTitle("Resolver presets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { importFromClipboard() } label: {
                        Label("Import from clipboard", systemImage: "doc.on.clipboard")
                    }
                    Button { isShowingFileImporter = true } label: {
                        Label("Import file", systemImage: "doc.badge.plus")
                    }
                    Button { importDraft = ResolverImportDraft() } label: {
                        Label("Enter plain text", systemImage: "square.and.pencil")
                    }
                } label: {
                    Label("Add resolver preset", systemImage: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.plainText, .commaSeparatedText, .json, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    importDraft = ResolverImportDraft(name: url.deletingPathExtension().lastPathComponent, text: text)
                } catch {
                    message = error.localizedDescription
                }
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .sheet(item: $importDraft) { draft in
            NavigationStack {
                ResolverImportEditor(draft: draft, parents: store.parents) { completed in
                    saveImport(completed)
                    importDraft = nil
                }
            }
        }
        .sheet(item: $scanPreset) { preset in
            NavigationStack {
                ResolverScanView(
                    store: store,
                    preset: preset,
                    profile: profile,
                    settings: settings,
                    isTunnelRunning: isTunnelRunning,
                    physicalInterface: physicalInterface
                )
            }
        }
        .alert("Resolver manager", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: ResolverPreset, level: Int) -> some View {
        HStack(spacing: 10) {
            Button {
                selection = preset.id
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selection == preset.id ? "checkmark.circle.fill" : (level == 0 ? "tray.full" : "line.3.horizontal.decrease.circle"))
                        .foregroundStyle(selection == preset.id ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name).foregroundStyle(.primary)
                        Text(rowDetail(preset)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button { scanPreset = preset } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Scan and evaluate")

            Menu {
                Button { ClipboardService.copy(preset.resolverText) } label: {
                    Label("Copy list", systemImage: "doc.on.doc")
                }
                Button {
                    importDraft = ResolverImportDraft(parentID: preset.kind == .parent ? preset.id : preset.parentID)
                } label: {
                    Label("Add subpreset", systemImage: "folder.badge.plus")
                }
                Button(role: .destructive) {
                    if selection == preset.id { selection = nil }
                    store.delete(preset.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.leading, level == 0 ? 0 : 18)
    }

    private func rowDetail(_ preset: ResolverPreset) -> String {
        let summary = ResolverEvaluationSummary(evaluations: preset.evaluations)
        if summary.total > 0 {
            return "\(preset.endpoints.count) resolvers · \(summary.tunnelViable) tunnel-valid"
        }
        return "\(preset.endpoints.count) resolvers"
    }

    private func importFromClipboard() {
        guard let text = ClipboardService.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "Clipboard does not contain text."
            return
        }
        importDraft = ResolverImportDraft(name: "Clipboard import", text: text)
    }

    private func saveImport(_ draft: ResolverImportDraft) {
        let report = ResolverImportParser.parse(draft.text)
        guard !report.endpoints.isEmpty else {
            message = "No valid resolver addresses were found."
            return
        }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported resolvers" : draft.name
        let saved: ResolverPreset
        if let parentID = draft.parentID {
            saved = store.createChild(
                parentID: parentID,
                name: name,
                endpoints: report.endpoints,
                source: report.summary
            )
        } else {
            saved = store.createParent(name: name, endpoints: report.endpoints, source: report.summary)
        }
        selection = saved.id
        if !report.issues.isEmpty || report.prohibitedCount > 0 {
            message = report.summary + (report.issues.first.map { "\n\($0.message)" } ?? "")
        }
    }
}

private struct ResolverImportDraft: Identifiable {
    let id = UUID()
    var name: String = ""
    var text: String = ""
    var parentID: UUID?
}

private struct ResolverImportEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: ResolverImportDraft
    let parents: [ResolverPreset]
    let onSave: (ResolverImportDraft) -> Void
    @State private var report: ResolverImportReport?

    var body: some View {
        Form {
            Section("Preset") {
                TextField("Name", text: $draft.name)
                Picker("Save as", selection: $draft.parentID) {
                    Text("Parent preset").tag(nil as UUID?)
                    ForEach(parents) { parent in
                        Text("Subpreset of \(parent.name)").tag(parent.id as UUID?)
                    }
                }
            }
            Section("Resolver data") {
                TextEditor(text: $draft.text)
                    .font(.system(.footnote, design: .monospaced)).frame(minHeight: 220)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
            }
            if let report {
                Section("Preview") {
                    LabeledContent("Unique", value: "\(report.endpoints.count)")
                    LabeledContent("Duplicates", value: "\(report.duplicateCount)")
                    LabeledContent("Prohibited skipped", value: "\(report.prohibitedCount)")
                    ForEach(report.issues.prefix(5)) { issue in
                        Text(issue.message).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("Import resolvers")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(draft); dismiss() }
                    .disabled((report?.endpoints.isEmpty ?? true))
            }
        }
        .onAppear { report = ResolverImportParser.parse(draft.text) }
        .onChange(of: draft.text) { report = ResolverImportParser.parse($0) }
    }
}

private struct ResolverScanView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ResolverPresetStore
    let preset: ResolverPreset
    let profile: ConnectionProfile
    let settings: AppSettings
    let isTunnelRunning: Bool
    let physicalInterface: PhysicalInterfaceMonitor.Snapshot

    @State private var attempts = 5
    @State private var runNative = true
    @State private var runThroughput = false
    @State private var throughputCandidates = 5
    @State private var progress: ResolverScanProgress?
    @State private var results: [ResolverEvaluation] = []
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var rankingMode: ResolverRankingMode = .balanced
    private let scanner = ResolverScannerService()

    var body: some View {
        Form {
            Section("Scan") {
                LabeledContent("Preset", value: preset.name)
                LabeledContent("Resolvers", value: "\(preset.endpoints.count)")
                Stepper("Attempts: \(attempts)", value: $attempts, in: 1...10)
                Toggle("MasterDNS encrypted MTU probe", isOn: $runNative)
                Toggle("Single-resolver throughput test", isOn: $runThroughput)
                if runThroughput {
                    Stepper(
                        "Throughput candidates: \(throughputCandidates)",
                        value: $throughputCandidates,
                        in: 1...20
                    )
                    Text("Only the highest-ranked reachable candidates are tested. Each gets its own real MasterDNS session and explicit SOCKS speed test; this can take several minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let progress {
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))) {
                        Text(progress.stage.rawValue)
                    } currentValueLabel: {
                        Text("\(progress.completed)/\(progress.total) · valid \(progress.accepted)")
                    }
                    Text(progress.detail).font(.caption).foregroundStyle(.secondary)
                }
                if task == nil {
                    Button("Start evaluation", action: start)
                        .disabled(isTunnelRunning || profile.domain.isEmpty || profile.encryptionKey.isEmpty)
                } else {
                    Button("Cancel", role: .destructive, action: cancel)
                }
                if isTunnelRunning {
                    Text("Disconnect Zanoza before native scanning.").font(.caption).foregroundStyle(.orange)
                }
            }

            if !results.isEmpty {
                Section("Evaluated subsets") {
                    Picker("Ranking", selection: $rankingMode) {
                        ForEach(ResolverRankingMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    HStack {
                        ForEach([5, 10, 20], id: \.self) { count in
                            Button("Top \(count)") { saveTop(count) }.disabled(selectableResultCount < count)
                        }
                    }
                    HStack {
                        ForEach([50, 100], id: \.self) { count in
                            Button("Top \(count)") { saveTop(count) }.disabled(selectableResultCount < count)
                        }
                    }
                }

                Section("Results") {
                    ForEach(Array(sortedResults.prefix(100))) { result in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(result.endpoint.canonicalAddress).font(.callout.monospaced())
                                Spacer()
                                Image(systemName: result.tunnelViable ? "checkmark.circle.fill" : (result.replies > 0 ? "exclamationmark.circle" : "xmark.circle"))
                                    .foregroundStyle(result.tunnelViable ? .green : (result.replies > 0 ? .orange : .red))
                            }
                            Text(resultDetail(result)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Resolver evaluator")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .alert("Scan failed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        .onDisappear(perform: cancel)
    }

    private var sortedResults: [ResolverEvaluation] {
        results.sorted { $0.rankingScore(for: rankingMode) > $1.rankingScore(for: rankingMode) }
    }

    private var selectableResultCount: Int {
        results.filter { $0.isSelectable(for: rankingMode) }.count
    }

    private func start() {
        let service = scanner
        task = Task {
            do {
                let output = try await service.evaluate(
                    preset: preset,
                    profile: profile,
                    settings: settings,
                    options: ResolverScanOptions(
                        attempts: attempts,
                        runMasterDnsMTUProbe: runNative,
                        runThroughputProbe: runThroughput,
                        throughputCandidateLimit: throughputCandidates
                    ),
                    runtimeDirectory: scanRuntimeDirectory(),
                    boundInterface: physicalInterface.name,
                    boundIPv4: physicalInterface.ipv4,
                    boundIPv6: physicalInterface.ipv6
                ) { update in
                    Task { @MainActor in progress = update }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    results = output
                    var updated = preset
                    updated.evaluations = output
                    store.save(updated)
                    task = nil
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription; task = nil }
            }
        }
    }

    private func cancel() {
        scanner.cancelNativeScan()
        task?.cancel()
        task = nil
    }

    private func saveTop(_ count: Int) {
        var source = preset
        source.evaluations = results
        _ = store.save(source.topSubset(count: count, mode: rankingMode))
    }

    private func resultDetail(_ result: ResolverEvaluation) -> String {
        var values = ["loss \(String(format: "%.0f", result.lossPercent))%"]
        if let latency = result.medianLatencyMS { values.append("\(String(format: "%.0f", latency)) ms") }
        if let up = result.uploadMTU { values.append("UP \(up)") }
        if let down = result.downloadMTU { values.append("DOWN \(down)") }
        if let downMbps = result.downloadMbps { values.append("↓ \(String(format: "%.2f", downMbps)) Mbit/s") }
        if let upMbps = result.uploadMbps { values.append("↑ \(String(format: "%.2f", upMbps)) Mbit/s") }
        if let reason = result.failureReason, !reason.isEmpty { values.append(reason) }
        return values.joined(separator: " · ")
    }

    private func scanRuntimeDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Zanoza/Scanner", isDirectory: true)
    }
}
