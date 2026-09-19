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
                Button {
                    importDraft = ResolverImportDraft(
                        editingID: preset.id,
                        name: preset.name,
                        text: preset.resolverText,
                        parentID: preset.parentID
                    )
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
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
        if let editingID = draft.editingID, let updated = store.update(
            editingID,
            name: name,
            endpoints: report.endpoints,
            source: report.summary
        ) {
            saved = updated
        } else if let parentID = draft.parentID {
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
    var editingID: UUID?
    var name: String = ""
    var text: String = ""
    var parentID: UUID?

    init(editingID: UUID? = nil, name: String = "", text: String = "", parentID: UUID? = nil) {
        self.editingID = editingID
        self.name = name
        self.text = text
        self.parentID = parentID
    }
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
                if draft.editingID == nil {
                    Picker("Save as", selection: $draft.parentID) {
                        Text("Parent preset").tag(nil as UUID?)
                        ForEach(parents) { parent in
                            Text("Subpreset of \(parent.name)").tag(parent.id as UUID?)
                        }
                    }
                } else {
                    Text(draft.parentID.flatMap { id in parents.first(where: { $0.id == id })?.name.map { "Subpreset of \($0)" } } ?? "Parent preset")
                        .foregroundStyle(.secondary)
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
        .navigationTitle(draft.editingID == nil ? "Import resolvers" : "Edit resolver preset")
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
    @ObservedObject private var appLogger = AppLogger.shared
    let preset: ResolverPreset
    let profile: ConnectionProfile
    let settings: AppSettings
    let isTunnelRunning: Bool
    let physicalInterface: PhysicalInterfaceMonitor.Snapshot

    @State private var attempts = 5
    @State private var runNative = true
    @State private var runThroughput = false
    @State private var throughputCandidates = 3
    @State private var progress: ResolverScanProgress?
    @State private var results: [ResolverEvaluation] = []
    @State private var selectedResolverIDs = Set<String>()
    @State private var errorMessage: String?
    @State private var presetMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var rankingMode: ResolverRankingMode = .balanced
    @State private var topCount = 5.0
    @State private var evaluatorLogs: [String] = []
    @State private var isShowingLogs = false
    @State private var isShowingStatistics = false
    @State private var loggerStartIndex = 0
    #if os(iOS)
    @State private var idleTimerClaimed = false
    #endif

    private let scanner = ResolverScannerService()

    var body: some View {
        Form {
            scanSection
            if !results.isEmpty {
                selectionSection
                resultsSection
            }
        }
        .navigationTitle("Resolver evaluator")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { isShowingStatistics = true } label: {
                    Label("Statistics", systemImage: "chart.bar.xaxis")
                }
                Button { isShowingLogs = true } label: {
                    Label("Logs", systemImage: "text.alignleft")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $isShowingLogs) {
            NavigationStack {
                LogView(logs: evaluatorLogs, onClear: { evaluatorLogs.removeAll() })
                    .navigationTitle("Evaluation logs")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingLogs = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $isShowingStatistics) {
            NavigationStack {
                ResolverStatisticsView(
                    preset: preset,
                    progress: progress,
                    results: results,
                    rankingMode: rankingMode,
                    selectedIDs: selectedResolverIDs,
                    strategy: profile.configuration.resolver.balancingStrategy
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isShowingStatistics = false }
                    }
                }
            }
        }
        .alert("Scan failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Resolver preset", isPresented: Binding(
            get: { presetMessage != nil },
            set: { if !$0 { presetMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(presetMessage ?? "")
        }
        .onAppear {
            loggerStartIndex = appLogger.lines.count
            evaluatorLogs = Array(appLogger.lines.suffix(100))
            acquireIdleTimer()
        }
        .onChange(of: appLogger.lines.count) { _ in
            let newLines = appLogger.lines.dropFirst(min(loggerStartIndex, appLogger.lines.count))
            for line in newLines where evaluatorLogs.last != line {
                evaluatorLogs.append(line)
            }
            loggerStartIndex = appLogger.lines.count
            if evaluatorLogs.count > 600 {
                evaluatorLogs.removeFirst(evaluatorLogs.count - 600)
            }
        }
        .onDisappear {
            cancel()
            releaseIdleTimer()
        }
    }

    @ViewBuilder
    private var scanSection: some View {
        Section("Scan") {
            LabeledContent("Preset", value: preset.name)
            LabeledContent("Resolvers", value: String(preset.endpoints.count))
            Stepper("Attempts: \(attempts)", value: $attempts, in: 1...10)
            Toggle("MasterDNS encrypted MTU probe", isOn: $runNative)
            Toggle("Single-resolver throughput test", isOn: $runThroughput)
            if runThroughput {
                Stepper(
                    "Throughput candidates: \(throughputCandidates)",
                    value: $throughputCandidates,
                    in: 1...10
                )
                Text("Each candidate is capped at 30 seconds for session readiness and 15 seconds per transfer phase. Slow or dead candidates fail fast and evaluation continues.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let progress {
                ProgressView(value: progressValue(progress), total: Double(max(1, progress.total))) {
                    Text(stageTitle(progress.stage))
                } currentValueLabel: {
                    Text("\(progress.completed)/\(progress.total) · valid \(progress.accepted)")
                }
                Text(progress.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if task == nil {
                Button("Start evaluation", action: start)
                    .disabled(isTunnelRunning || profile.domain.isEmpty || profile.encryptionKey.isEmpty)
            } else {
                Button("Cancel", role: .destructive, action: cancel)
            }
            if isTunnelRunning {
                Text("Disconnect Zanoza before native scanning.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var selectionSection: some View {
        Section("Create evaluated subpreset") {
            Picker("Sort and rank", selection: $rankingMode) {
                ForEach(ResolverRankingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .onChange(of: rankingMode) { _ in
                topCount = min(topCount, Double(max(1, selectableResultCount)))
            }

            if selectableResultCount > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Top selection")
                        Spacer()
                        Text(String(Int(topCount)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $topCount,
                        in: 1...Double(max(1, selectableResultCount)),
                        step: 1
                    )
                    Button("Select top \(Int(topCount))") {
                        selectTop(Int(topCount))
                    }
                }
            }

            HStack {
                Text("Selected")
                Spacer()
                Text("\(selectedResolverIDs.count) of \(selectableResultCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Select all valid", action: selectAllValid)
                Spacer()
                Button("Clear", action: { selectedResolverIDs.removeAll() })
                    .disabled(selectedResolverIDs.isEmpty)
            }
            Button("Create preset from selected resolvers", action: saveSelected)
                .buttonStyle(.borderedProminent)
                .disabled(selectedResolverIDs.isEmpty)
        } footer: {
            Text("Top-N only changes the green selections. A new subpreset is written only after you press Create.")
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        Section("Results · tap to select") {
            ForEach(Array(sortedResults.prefix(250))) { result in
                ResolverEvaluationRow(
                    result: result,
                    isSelected: selectedResolverIDs.contains(result.id),
                    isSelectable: result.isSelectable(for: rankingMode),
                    detail: resultDetail(result),
                    onToggle: { toggleSelection(result) },
                    onCopy: { ClipboardService.copy(result.endpoint.canonicalAddress) }
                )
            }
        }
    }

    private var sortedResults: [ResolverEvaluation] {
        results.sorted {
            let left = $0.rankingScore(for: rankingMode)
            let right = $1.rankingScore(for: rankingMode)
            if left == right {
                return $0.endpoint.canonicalAddress < $1.endpoint.canonicalAddress
            }
            return left > right
        }
    }

    private var selectableResultCount: Int {
        results.filter { $0.isSelectable(for: rankingMode) }.count
    }

    private func start() {
        let service = scanner
        results.removeAll()
        selectedResolverIDs.removeAll()
        progress = nil
        errorMessage = nil
        loggerStartIndex = appLogger.lines.count
        evaluatorLogs = [
            "Evaluation started · \(preset.endpoints.count) resolvers · attempts \(attempts)",
            "Physical path · \(physicalInterface.name.isEmpty ? "automatic" : physicalInterface.name)"
        ]
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
                    Task { @MainActor in
                        progress = update
                        if !update.snapshot.isEmpty {
                            results = update.snapshot
                            if task == nil {
                                selectedResolverIDs = Set(update.snapshot.filter(\.isSelectable).map(\.id))
                            }
                        }
                        appendEvaluationProgress(update)
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    results = output
                    selectedResolverIDs = Set(output.filter(\.isSelectable).map(\.id))
                    topCount = min(5, Double(max(1, selectableResultCount)))
                    var updated = preset
                    updated.evaluations = output
                    store.save(updated)
                    evaluatorLogs.append("Evaluation complete · \(selectedResolverIDs.count) selectable")
                    task = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    evaluatorLogs.append("Evaluation cancelled")
                    task = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    evaluatorLogs.append("Evaluation failed · \(error.localizedDescription)")
                    task = nil
                }
            }
        }
    }

    private func cancel() {
        scanner.cancelNativeScan()
        task?.cancel()
        task = nil
    }

    private func toggleSelection(_ result: ResolverEvaluation) {
        guard result.isSelectable(for: rankingMode) else { return }
        if selectedResolverIDs.contains(result.id) {
            selectedResolverIDs.remove(result.id)
        } else {
            selectedResolverIDs.insert(result.id)
        }
    }

    private func selectTop(_ count: Int) {
        selectedResolverIDs = Set(
            sortedResults
                .filter { $0.isSelectable(for: rankingMode) }
                .prefix(max(1, count))
                .map(\.id)
        )
    }

    private func selectAllValid() {
        selectedResolverIDs = Set(results.filter { $0.isSelectable(for: rankingMode) }.map(\.id))
    }

    private func saveSelected() {
        guard let parentID = preset.kind == .parent ? preset.id : preset.parentID else {
            presetMessage = "The parent preset no longer exists."
            return
        }
        let selected = sortedResults.filter { selectedResolverIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        let saved = store.createChild(
            parentID: parentID,
            name: "Selected \(selected.count) · \(rankingMode.title)",
            endpoints: selected.map(\.endpoint),
            evaluations: selected,
            source: "Manually selected from \(preset.name)"
        )
        presetMessage = "Created \(saved.name) with \(saved.endpoints.count) resolvers."
    }

    private func appendEvaluationProgress(_ update: ResolverScanProgress) {
        let line = "\(stageTitle(update.stage)) · \(update.completed)/\(update.total) · valid \(update.accepted) · \(update.detail)"
        if evaluatorLogs.last != line {
            evaluatorLogs.append(line)
            if evaluatorLogs.count > 600 {
                evaluatorLogs.removeFirst(evaluatorLogs.count - 600)
            }
        }
    }

    private func progressValue(_ value: ResolverScanProgress) -> Double {
        min(Double(max(1, value.total)), Double(value.completed) + value.fraction)
    }

    private func stageTitle(_ stage: ResolverScanProgress.Stage) -> String {
        switch stage {
        case .reachability: "DNS reachability"
        case .masterDnsMTU: "MasterDNS MTU"
        case .throughput: "Tunnel throughput"
        case .complete: "Complete"
        }
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

    private func acquireIdleTimer() {
        #if os(iOS)
        guard !idleTimerClaimed else { return }
        idleTimerClaimed = true
        IdleTimerController.shared.acquire()
        #endif
    }

    private func releaseIdleTimer() {
        #if os(iOS)
        guard idleTimerClaimed else { return }
        idleTimerClaimed = false
        IdleTimerController.shared.release()
        #endif
    }
}

private struct ResolverEvaluationRow: View {
    let result: ResolverEvaluation
    let isSelected: Bool
    let isSelectable: Bool
    let detail: String
    let onToggle: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: selectionIcon)
                    .foregroundStyle(selectionColor)
                Text(result.endpoint.canonicalAddress)
                    .font(.callout.monospaced())
                Spacer()
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .opacity(isSelectable ? 1 : 0.72)
        .contextMenu {
            Button(action: onCopy) {
                Label("Copy IP address", systemImage: "doc.on.doc")
            }
            if isSelectable {
                Button(action: onToggle) {
                    Label(isSelected ? "Deselect" : "Select", systemImage: isSelected ? "minus.circle" : "checkmark.circle")
                }
            }
        }
        .accessibilityAction(
            named: Text(isSelected ? "Deselect" : "Select"),
            onToggle
        )
    }

    private var selectionIcon: String {
        isSelected ? "checkmark.circle.fill" : "circle"
    }

    private var selectionColor: Color {
        isSelected ? .green : .secondary
    }

    private var statusIcon: String {
        result.tunnelViable ? "bolt.horizontal.circle.fill" : (result.replies > 0 ? "exclamationmark.circle" : "xmark.circle")
    }

    private var statusColor: Color {
        result.tunnelViable ? .green : (result.replies > 0 ? .orange : .red)
    }
}

private struct ResolverStatisticsView: View {
    let preset: ResolverPreset
    let progress: ResolverScanProgress?
    let results: [ResolverEvaluation]
    let rankingMode: ResolverRankingMode
    let selectedIDs: Set<String>
    let strategy: BalancingStrategy

    var body: some View {
        List {
            Section("Current pool") {
                LabeledContent("Preset", value: preset.name)
                LabeledContent("Configured", value: String(preset.endpoints.count))
                LabeledContent("Evaluated", value: String(results.count))
                LabeledContent("Reachable", value: String(results.filter { $0.replies > 0 }.count))
                LabeledContent("Tunnel-valid", value: String(results.filter(\.tunnelViable).count))
                LabeledContent("Selected", value: String(selectedIDs.count))
            }
            Section("Tactics") {
                LabeledContent("Runtime balancing", value: strategy.title)
                LabeledContent("Evaluator ranking", value: rankingMode.title)
                if let progress {
                    LabeledContent("Current stage", value: progress.stage.rawValue)
                    Text(progress.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Section("Top resolvers") {
                if ranked.isEmpty {
                    Text("No measurements yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(ranked.prefix(20).enumerated()), id: \.offset) { index, result in
                    HStack(alignment: .top) {
                        Text("#\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.endpoint.canonicalAddress).font(.callout.monospaced())
                            Text(statDetail(result)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Resolver statistics")
    }

    private var ranked: [ResolverEvaluation] {
        results.sorted { $0.rankingScore(for: rankingMode) > $1.rankingScore(for: rankingMode) }
    }

    private func statDetail(_ result: ResolverEvaluation) -> String {
        var parts = ["loss \(String(format: "%.0f", result.lossPercent))%"]
        if let latency = result.medianLatencyMS ?? result.tunnelLatencyMS {
            parts.append("\(String(format: "%.0f", latency)) ms")
        }
        if let speed = result.downloadMbps {
            parts.append("↓ \(String(format: "%.2f", speed)) Mbit/s")
        }
        if let speed = result.uploadMbps {
            parts.append("↑ \(String(format: "%.2f", speed)) Mbit/s")
        }
        return parts.joined(separator: " · ")
    }
}
