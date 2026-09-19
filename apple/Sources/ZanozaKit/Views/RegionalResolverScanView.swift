import SwiftUI

/// First-stage discovery screen for carrier/ISP-local recursive resolvers.
///
/// The existing evaluator is deliberately kept as the second stage: this
/// screen discovers a bounded candidate pool, records provenance, and saves a
/// parent preset; `ResolverScanView` then performs reachability/MTU/throughput
/// measurements and can create explicitly selected child presets.
struct RegionalResolverScanView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ResolverPresetStore
    let profile: ConnectionProfile
    let settings: AppSettings
    let physicalInterface: PhysicalInterfaceMonitor.Snapshot
    let isTunnelRunning: Bool

    @State private var seedText: String
    @State private var selectedProviderID: String = AppSettings.noResolverProviderID
    @State private var expandNearby = true
    @State private var nearbyRadius = RegionalResolverDiscoveryService.defaultNearbyRadius
    @State private var maximumCandidates = 512
    @State private var report: RegionalResolverDiscoveryReport?
    @State private var isDiscovering = false
    @State private var isLoadingProvider = false
    @State private var task: Task<Void, Never>?
    @State private var evaluationPreset: ResolverPreset?
    @State private var message: String?
    @State private var logs: [String] = []
    @State private var showingLogs = false
    #if os(iOS)
    @State private var idleTimerClaimed = false
    #endif

    init(
        store: ResolverPresetStore,
        profile: ConnectionProfile,
        settings: AppSettings,
        physicalInterface: PhysicalInterfaceMonitor.Snapshot,
        isTunnelRunning: Bool
    ) {
        self.store = store
        self.profile = profile
        self.settings = settings
        self.physicalInterface = physicalInterface
        self.isTunnelRunning = isTunnelRunning
        _seedText = State(initialValue: settings.customResolvers)
        _selectedProviderID = State(initialValue: settings.resolverProviderID)
    }

    var body: some View {
        Form {
            sourceSection
            discoverySection
            if let report, !report.candidates.isEmpty {
                candidateSection(report)
                actionSection(report)
            }
            logSection
        }
        .navigationTitle("ISP / regional DNS scan")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showingLogs = true } label: {
                    Label("Logs", systemImage: "text.alignleft")
                }
                Button("Done") { dismiss() }
            }
        }
        .sheet(item: $evaluationPreset) { preset in
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
        .sheet(isPresented: $showingLogs) {
            NavigationStack {
                LogView(logs: logs, onClear: { logs.removeAll() })
                    .navigationTitle("Regional scan logs")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingLogs = false }
                        }
                    }
            }
        }
        .alert("Regional resolver scan", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .onAppear { acquireIdleTimer() }
        .onDisappear {
            task?.cancel()
            releaseIdleTimer()
        }
    }

    private var sourceSection: some View {
        Section("Network source") {
            Picker("Provider list", selection: $selectedProviderID) {
                Text("Pasted / local seeds").tag(AppSettings.noResolverProviderID)
                ForEach(ResolverCatalog.providers) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }
            Button {
                loadSelectedProvider()
            } label: {
                Label(
                    isLoadingProvider ? "Loading provider list…" : "Load provider list",
                    systemImage: "arrow.down.circle"
                )
            }
            .disabled(isLoadingProvider || selectedProviderID.isEmpty)

            Text("Paste DHCP/router DNS addresses, resolver scan output, or a bounded CIDR. The app cannot read an iOS DHCP DNS list directly, so pasted seeds remain visible and auditable.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $seedText)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 120)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

            Toggle("Probe nearby private /24 addresses", isOn: $expandNearby)
            if expandNearby {
                Stepper("Nearby radius: ±\(nearbyRadius)", value: $nearbyRadius, in: 1...64)
                Text("Only a bounded neighbourhood around private seeds and the active local IPv4 is added; no 10/8 sweep is performed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Stepper("Candidate cap: \(maximumCandidates)", value: $maximumCandidates, in: 32...2_048, step: 32)
        }
    }

    @ViewBuilder
    private var discoverySection: some View {
        Section("Discovery") {
            HStack {
                Text("Physical path")
                Spacer()
                Text(physicalInterface.name.isEmpty ? "Automatic" : physicalInterface.name)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            if !physicalInterface.ipv4.isEmpty {
                HStack {
                    Text("Source IPv4")
                    Spacer()
                    Text(physicalInterface.ipv4)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
            }
            Button {
                discover()
            } label: {
                Label(isDiscovering ? "Discovering…" : "Discover carrier / regional resolvers", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(isDiscovering || isTunnelRunning)
            if isTunnelRunning {
                Text("Disconnect Zanoza before probing carrier resolvers.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if isDiscovering {
                ProgressView("Building bounded candidate pool…")
            }
            if let report {
                LabeledContent("Candidates", value: String(report.candidates.count))
                if !report.sourceSummary.isEmpty {
                    Text(report.sourceSummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                ForEach(report.issues.prefix(4), id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func candidateSection(_ report: RegionalResolverDiscoveryReport) -> some View {
        Section("Candidate pool · first 80") {
            ForEach(Array(report.candidates.prefix(80))) { candidate in
                HStack(alignment: .top, spacing: 8) {
                    Text(candidate.endpoint.canonicalAddress)
                        .font(.callout.monospaced())
                    Spacer(minLength: 4)
                    Text(candidate.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
                .contextMenu {
                    Button {
                        ClipboardService.copy(candidate.endpoint.canonicalAddress)
                    } label: {
                        Label("Copy resolver", systemImage: "doc.on.doc")
                    }
                }
            }
            if report.candidates.count > 80 {
                Text("\(report.candidates.count - 80) more candidates will be evaluated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func actionSection(_ report: RegionalResolverDiscoveryReport) -> some View {
        Section("Next step") {
            Button {
                saveAndEvaluate(report)
            } label: {
                Label("Save pool and evaluate MTU / latency", systemImage: "waveform.path.ecg")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isTunnelRunning || profile.domain.isEmpty || profile.encryptionKey.isEmpty)

            Button {
                savePool(report)
            } label: {
                Label("Save candidate pool as parent preset", systemImage: "folder.badge.plus")
            }
            Text("The saved parent keeps every discovered address and its source. The evaluator's separate selection action creates a reliable/fast child preset without silently replacing the parent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var logSection: some View {
        Section("Live log") {
            if logs.isEmpty {
                Text("No scan activity yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(logs.suffix(8).enumerated()), id: \.offset) { _, line in
                    Text(LogFormatter.compact([line]).first ?? line)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                }
                Button("Open full log") { showingLogs = true }
            }
        }
    }

    private func loadSelectedProvider() {
        guard let provider = ResolverCatalog.provider(id: selectedProviderID) else { return }
        isLoadingProvider = true
        append("I loading \(provider.displayName) resolver list")
        let selectedID = selectedProviderID
        task?.cancel()
        task = Task {
            var providerSettings = settings
            providerSettings.customResolvers = ""
            providerSettings.resolverProviderID = selectedID
            providerSettings.useFastResolvers = false
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try ResolverListService.resolve(settings: providerSettings)
                }.value
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    seedText = text
                    isLoadingProvider = false
                    append("I loaded \(text.split(whereSeparator: { $0.isNewline }).count) resolver seeds from \(provider.displayName)")
                    task = nil
                }
            } catch {
                await MainActor.run {
                    isLoadingProvider = false
                    append("E provider list: \(error.localizedDescription)")
                    message = error.localizedDescription
                    task = nil
                }
            }
        }
    }

    private func discover() {
        task?.cancel()
        isDiscovering = true
        report = nil
        append("I discovery started · seeds=\(seedText.split(whereSeparator: { $0.isNewline }).count) · nearby=\(expandNearby)")
        let options = RegionalResolverDiscoveryOptions(
            seedText: seedText,
            localIPv4: physicalInterface.ipv4,
            expandNearby: expandNearby,
            nearbyRadius: nearbyRadius,
            maximumCandidates: maximumCandidates
        )
        task = Task {
            // Yield once so the progress indicator is painted before parsing a
            // large imported list.
            await Task.yield()
            let result = RegionalResolverDiscoveryService.discover(options: options)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                report = result
                isDiscovering = false
                append("I discovery complete · candidates=\(result.candidates.count)")
                for issue in result.issues.prefix(4) { append("W \(issue)") }
                task = nil
            }
        }
    }

    private func savePool(_ report: RegionalResolverDiscoveryReport) {
        guard !report.candidates.isEmpty else { return }
        let name = suggestedName(report)
        let parent = store.createParent(
            name: name,
            endpoints: report.endpoints,
            source: "Carrier/regional discovery · \(report.sourceSummary)"
        )
        append("I saved parent preset \(parent.name) · \(parent.endpoints.count) resolvers")
        message = "Saved \(parent.name) with \(parent.endpoints.count) candidate resolvers."
    }

    private func saveAndEvaluate(_ report: RegionalResolverDiscoveryReport) {
        guard !report.candidates.isEmpty else { return }
        let name = suggestedName(report)
        let parent = store.createParent(
            name: name,
            endpoints: report.endpoints,
            source: "Carrier/regional discovery · \(report.sourceSummary)"
        )
        append("I saved parent \(parent.name); opening live evaluator")
        evaluationPreset = parent
    }

    private func suggestedName(_ report: RegionalResolverDiscoveryReport) -> String {
        if let provider = ResolverCatalog.provider(id: selectedProviderID) {
            return "\(provider.displayName) regional scan"
        }
        return "Carrier regional scan · \(report.candidates.count)"
    }

    private func append(_ line: String) {
        logs.append(line)
        if logs.count > 600 { logs.removeFirst(logs.count - 600) }
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
