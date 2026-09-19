import SwiftUI

public struct ProfileEditorView: View {
    @Binding var profile: ConnectionProfile
    let validationMessage: String?
    let onCommit: () -> Void
    let isTunnelRunning: Bool
    let physicalInterface: PhysicalInterfaceMonitor.Snapshot
    let settings: AppSettings
    @ObservedObject private var resolverStore = ResolverPresetStore.shared
    @State private var configurationMessage: String?

    public init(
        profile: Binding<ConnectionProfile>,
        validationMessage: String?,
        onCommit: @escaping () -> Void,
        isTunnelRunning: Bool = false,
        physicalInterface: PhysicalInterfaceMonitor.Snapshot = .none,
        settings: AppSettings = AppSettingsStore.shared.load()
    ) {
        _profile = profile
        self.validationMessage = validationMessage
        self.onCommit = onCommit
        self.isTunnelRunning = isTunnelRunning
        self.physicalInterface = physicalInterface
        self.settings = settings
    }

    public var body: some View {
        Form {
            if let validationMessage {
                Section {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section(AppLocalization.string("Profile name")) {
                TextField(AppLocalization.string("Profile name"), text: $profile.name)
                    .zanozaPlainInput().onSubmit(onCommit)
            }

            Section(AppLocalization.string("Server")) {
                TextField("x.false.actor", text: $profile.domain)
                    .zanozaPlainInput().onSubmit(onCommit)
                SecureField(AppLocalization.string("Encryption key"), text: $profile.encryptionKey)
                    .zanozaPlainInput().onSubmit(onCommit)
                Picker(AppLocalization.string("Encryption method"), selection: $profile.encryptionMethod) {
                    ForEach(EncryptionMethod.allCases) { method in Text(method.title).tag(method) }
                }
            }

            Section {
                Picker("Configuration preset", selection: $profile.appliedConfigurationPreset) {
                    ForEach(MasterDnsConfigurationPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .onChange(of: profile.appliedConfigurationPreset) { preset in
                    profile.configuration.apply(preset)
                }
                Text(profile.appliedConfigurationPreset.detail)
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("MasterDNS preset")
            }

            Section {
                ResolverPresetPicker(selection: $profile.resolverPresetID, store: resolverStore)
                NavigationLink {
                    ResolverManagerView(
                        store: resolverStore,
                        selection: $profile.resolverPresetID,
                        profile: profile,
                        settings: settings,
                        isTunnelRunning: isTunnelRunning,
                        physicalInterface: physicalInterface
                    )
                } label: {
                    Label("Manage, scan and evaluate", systemImage: "folder.badge.gearshape")
                }
            } header: {
                Text("Resolver preset")
            } footer: {
                Text("A selected preset overrides the legacy provider/manual resolver list.")
            }

            Section("Local proxy compatibility") {
                LabeledContent("SOCKS5") {
                    Text("\(profile.configuration.listener.listenIP):\(profile.configuration.listener.listenPort)")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Toggle("Streisand optimistic handshake", isOn: $profile.configuration.listener.optimisticSocksConnect)
                Toggle("HTTP CONNECT fallback", isOn: $profile.configuration.listener.httpProxyEnabled)
                if profile.configuration.listener.httpProxyEnabled {
                    IntegerSettingRow("HTTP port", value: $profile.configuration.listener.httpProxyPort, range: 1_024...65_535)
                }
            }

            Section(AppLocalization.string("Reliability")) {
                Picker(AppLocalization.string("Resolver strategy"), selection: $profile.resolverBalancingStrategy) {
                    ForEach(BalancingStrategy.allCases) { strategy in Text(strategy.title).tag(strategy) }
                }
                Stepper("\(AppLocalization.string("Packet duplication")): \(profile.packetDuplicationCount)", value: $profile.packetDuplicationCount, in: 1...10)
                Stepper("\(AppLocalization.string("Setup duplication")): \(profile.setupPacketDuplicationCount)", value: $profile.setupPacketDuplicationCount, in: profile.packetDuplicationCount...12)
            }

            Section(AppLocalization.string("Compression")) {
                Picker(AppLocalization.string("Upload"), selection: $profile.uploadCompression) {
                    ForEach(CompressionType.allCases) { type in Text(type.title).tag(type) }
                }
                Picker(AppLocalization.string("Download"), selection: $profile.downloadCompression) {
                    ForEach(CompressionType.allCases) { type in Text(type.title).tag(type) }
                }
            }

            Section {
                NavigationLink("All MasterDNS settings") {
                    AdvancedMasterDnsConfigurationView(configuration: $profile.configuration)
                }
                Button {
                    ClipboardService.copy(MasterDnsConfigurationCodec.exportTOML(profile))
                } label: {
                    Label("Copy full TOML", systemImage: "doc.on.doc")
                }
                Button(action: importConfigurationFromClipboard) {
                    Label("Apply settings from clipboard", systemImage: "doc.on.clipboard")
                }
            } footer: {
                Text("Every setting emitted to the embedded MasterDNS core is available here. Exported TOML includes the encryption key; treat it as a secret. Changes apply after reconnecting.")
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            profile.configuration.normalize()
            onCommit()
        }
        .alert("MasterDNS configuration", isPresented: Binding(
            get: { configurationMessage != nil },
            set: { if !$0 { configurationMessage = nil } }
        )) {
            Button("OK", role: .cancel) { configurationMessage = nil }
        } message: {
            Text(configurationMessage ?? "")
        }
    }

    private func importConfigurationFromClipboard() {
        guard let text = ClipboardService.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            configurationMessage = "Clipboard does not contain configuration text."
            return
        }
        do {
            let imported = try MasterDnsConfigurationCodec.applyConfiguration(from: text, to: profile)
            profile = imported.profile
            let warning = imported.warnings.first.map { " \($0)" } ?? ""
            configurationMessage = "Settings applied. Server domain and encryption key were kept unchanged." + warning
            onCommit()
        } catch {
            configurationMessage = error.localizedDescription
        }
    }
}

private struct ResolverPresetPicker: View {
    @Binding var selection: UUID?
    @ObservedObject var store: ResolverPresetStore

    var body: some View {
        Menu {
            Button("Provider / manual settings") { selection = nil }
            ForEach(store.parents) { parent in
                Menu(parent.name) {
                    Button("\(parent.name) (\(parent.endpoints.count))") { selection = parent.id }
                    ForEach(store.children(of: parent.id)) { child in
                        Button("\(child.name) (\(child.endpoints.count))") { selection = child.id }
                    }
                }
            }
        } label: {
            LabeledContent("Active list") {
                Text(store.preset(id: selection)?.name ?? "Provider / manual")
            }
        }
    }
}

public struct AdvancedMasterDnsConfigurationView: View {
    @Binding var configuration: MasterDnsClientConfiguration

    public init(configuration: Binding<MasterDnsClientConfiguration>) {
        _configuration = configuration
    }

    public var body: some View {
        Form {
            listenerSection
            localDNSSection
            resolverSection
            mtuSection
            runtimeSection
            sessionSection
            pingSection
            arqSection
            diagnosticsSection
        }
        .navigationTitle("MasterDNS settings")
        .formStyle(.grouped)
        .onDisappear { configuration.normalize() }
    }

    private var listenerSection: some View {
        Section("Local listeners") {
            Picker("Protocol", selection: $configuration.listener.protocolType) {
                ForEach(LocalProxyProtocol.allCases) { value in Text(value.title).tag(value) }
            }
            TextField("Listen IP", text: $configuration.listener.listenIP).zanozaPlainInput()
            IntegerSettingRow("SOCKS/TCP port", value: $configuration.listener.listenPort, range: 1_024...65_535)
            Toggle("Require SOCKS credentials", isOn: $configuration.listener.socksAuth)
            if configuration.listener.socksAuth {
                TextField("Username", text: $configuration.listener.socksUser).zanozaPlainInput()
                SecureField("Password", text: $configuration.listener.socksPass).zanozaPlainInput()
            }
            Toggle("HTTP CONNECT proxy", isOn: $configuration.listener.httpProxyEnabled)
            if configuration.listener.httpProxyEnabled {
                IntegerSettingRow("HTTP port", value: $configuration.listener.httpProxyPort, range: 1_024...65_535)
            }
            Toggle("Optimistic CONNECT acknowledgement", isOn: $configuration.listener.optimisticSocksConnect)
            DecimalSettingRow("Local handshake timeout", value: $configuration.listener.localHandshakeTimeoutSeconds, suffix: "s")
        }
    }

    private var localDNSSection: some View {
        Section("Built-in local DNS") {
            Toggle("Enabled", isOn: $configuration.localDNS.enabled)
            TextField("Listen IP", text: $configuration.localDNS.listenIP).zanozaPlainInput()
            IntegerSettingRow("Port", value: $configuration.localDNS.port, range: 1...65_535)
            IntegerSettingRow("Cache records", value: $configuration.localDNS.cacheMaxRecords, range: 1...1_000_000)
            DecimalSettingRow("Cache TTL", value: $configuration.localDNS.cacheTTLSeconds, suffix: "s")
            DecimalSettingRow("Pending timeout", value: $configuration.localDNS.pendingTimeoutSeconds, suffix: "s")
            DecimalSettingRow("Fragment timeout", value: $configuration.localDNS.fragmentTimeoutSeconds, suffix: "s")
            Toggle("Persist cache", isOn: $configuration.localDNS.persistCache)
            DecimalSettingRow("Flush interval", value: $configuration.localDNS.cacheFlushIntervalSeconds, suffix: "s")
        }
    }

    private var resolverSection: some View {
        Section("Resolver transport") {
            Picker("Balancing", selection: $configuration.resolver.balancingStrategy) {
                ForEach(BalancingStrategy.allCases) { value in Text(value.title).tag(value) }
            }
            IntegerSettingRow("Packet duplication", value: $configuration.resolver.packetDuplicationCount, range: 1...10)
            IntegerSettingRow("Setup duplication", value: $configuration.resolver.setupPacketDuplicationCount, range: 1...12)
            IntegerSettingRow("Failover resend threshold", value: $configuration.resolver.failoverResendThreshold, range: 1...256)
            DecimalSettingRow("Failover cooldown", value: $configuration.resolver.failoverCooldownSeconds, suffix: "s")
            Toggle("Recheck inactive", isOn: $configuration.resolver.recheckInactiveServers)
            Toggle("Disable timing-out resolvers", isOn: $configuration.resolver.autoDisableTimeoutServers)
            DecimalSettingRow("Timeout window", value: $configuration.resolver.autoDisableTimeoutWindowSeconds, suffix: "s")
            Toggle("Base-encode DNS data", isOn: $configuration.resolver.baseEncodeData)
            Picker("Upload compression", selection: $configuration.encoding.uploadCompression) {
                ForEach(CompressionType.allCases) { value in Text(value.title).tag(value) }
            }
            Picker("Download compression", selection: $configuration.encoding.downloadCompression) {
                ForEach(CompressionType.allCases) { value in Text(value.title).tag(value) }
            }
            IntegerSettingRow("Compression minimum", value: $configuration.encoding.compressionMinSize, range: 100...65_535)
        }
    }

    private var mtuSection: some View {
        Section("MTU discovery") {
            IntegerSettingRow("Minimum upload", value: $configuration.mtu.minUpload, range: 0...512)
            IntegerSettingRow("Maximum upload", value: $configuration.mtu.maxUpload, range: 1...512)
            IntegerSettingRow("Minimum download", value: $configuration.mtu.minDownload, range: 0...4_096)
            IntegerSettingRow("Maximum download", value: $configuration.mtu.maxDownload, range: 1...4_096)
            Toggle("Remove low-MTU outliers", isOn: $configuration.mtu.autoRemoveLowMTUResolvers)
            IntegerSettingRow("Probe retries", value: $configuration.mtu.testRetries, range: 1...20)
            DecimalSettingRow("Probe timeout", value: $configuration.mtu.testTimeoutSeconds, suffix: "s")
            IntegerSettingRow("Probe parallelism", value: $configuration.mtu.testParallelism, range: 1...512)
        }
    }

    private var runtimeSection: some View {
        Section("Runtime") {
            IntegerSettingRow("RX/TX workers", value: $configuration.runtime.rxTxWorkers, range: 1...128)
            IntegerSettingRow("Processing workers", value: $configuration.runtime.tunnelProcessWorkers, range: 1...128)
            DecimalSettingRow("Packet timeout", value: $configuration.runtime.tunnelPacketTimeoutSeconds, suffix: "s")
            DecimalSettingRow("Dispatcher poll", value: $configuration.runtime.dispatcherIdlePollIntervalSeconds, suffix: "s")
            IntegerSettingRow("RX channel", value: $configuration.runtime.rxChannelSize, range: 64...65_536)
            DecimalSettingRow("SOCKS UDP idle", value: $configuration.runtime.socksUDPAssociateReadTimeoutSeconds, suffix: "s")
            DecimalSettingRow("Terminal stream retention", value: $configuration.runtime.terminalStreamRetentionSeconds, suffix: "s")
            DecimalSettingRow("Cancelled setup retention", value: $configuration.runtime.cancelledSetupRetentionSeconds, suffix: "s")
        }
    }

    private var sessionSection: some View {
        Section("Session retries") {
            DecimalSettingRow("Base delay", value: $configuration.session.retryBaseSeconds, suffix: "s")
            DecimalSettingRow("Linear step", value: $configuration.session.retryStepSeconds, suffix: "s")
            IntegerSettingRow("Linear after", value: $configuration.session.retryLinearAfter, range: 0...1_000)
            DecimalSettingRow("Maximum delay", value: $configuration.session.retryMaxSeconds, suffix: "s")
            DecimalSettingRow("Busy retry", value: $configuration.session.busyRetryIntervalSeconds, suffix: "s")
            IntegerSettingRow("Racing count", value: $configuration.session.racingCount, range: 1...5)
        }
    }

    private var pingSection: some View {
        Section("Adaptive ping") {
            DecimalSettingRow("Aggressive interval", value: $configuration.ping.aggressiveIntervalSeconds, suffix: "s")
            DecimalSettingRow("Lazy interval", value: $configuration.ping.lazyIntervalSeconds, suffix: "s")
            DecimalSettingRow("Cooldown interval", value: $configuration.ping.cooldownIntervalSeconds, suffix: "s")
            DecimalSettingRow("Cold interval", value: $configuration.ping.coldIntervalSeconds, suffix: "s")
            DecimalSettingRow("Warm threshold", value: $configuration.ping.warmThresholdSeconds, suffix: "s")
            DecimalSettingRow("Cool threshold", value: $configuration.ping.coolThresholdSeconds, suffix: "s")
            DecimalSettingRow("Cold threshold", value: $configuration.ping.coldThresholdSeconds, suffix: "s")
        }
    }

    private var arqSection: some View {
        Section("Reliable stream / ARQ") {
            IntegerSettingRow("Packets per batch", value: $configuration.arq.maxPacketsPerBatch, range: 1...64)
            IntegerSettingRow("Window size", value: $configuration.arq.windowSize, range: 2...8_000)
            DecimalSettingRow("Initial RTO", value: $configuration.arq.initialRTOSeconds, suffix: "s")
            DecimalSettingRow("Maximum RTO", value: $configuration.arq.maxRTOSeconds, suffix: "s")
            DecimalSettingRow("Control initial RTO", value: $configuration.arq.controlInitialRTOSeconds, suffix: "s")
            DecimalSettingRow("Control maximum RTO", value: $configuration.arq.controlMaxRTOSeconds, suffix: "s")
            IntegerSettingRow("Control retries", value: $configuration.arq.maxControlRetries, range: 5...5_000)
            DecimalSettingRow("Inactivity timeout", value: $configuration.arq.inactivityTimeoutSeconds, suffix: "s")
            DecimalSettingRow("Data TTL", value: $configuration.arq.dataPacketTTLSeconds, suffix: "s")
            DecimalSettingRow("Control TTL", value: $configuration.arq.controlPacketTTLSeconds, suffix: "s")
            IntegerSettingRow("Data retries", value: $configuration.arq.maxDataRetries, range: 5...100_000)
            IntegerSettingRow("NACK maximum gap", value: $configuration.arq.dataNackMaxGap, range: 0...128)
            DecimalSettingRow("NACK initial delay", value: $configuration.arq.dataNackInitialDelaySeconds, suffix: "s")
            DecimalSettingRow("NACK repeat", value: $configuration.arq.dataNackRepeatSeconds, suffix: "s")
            DecimalSettingRow("Terminal drain", value: $configuration.arq.terminalDrainTimeoutSeconds, suffix: "s")
            DecimalSettingRow("Terminal ACK wait", value: $configuration.arq.terminalAckWaitTimeoutSeconds, suffix: "s")
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Picker("Log level", selection: $configuration.logLevel) {
                ForEach(LogLevel.allCases) { value in Text(value.title).tag(value) }
            }
            Toggle("Save MTU results", isOn: $configuration.diagnostics.saveMTUResults)
            if configuration.diagnostics.saveMTUResults {
                TextField("Result filename", text: $configuration.diagnostics.mtuResultsFileName).zanozaPlainInput()
                TextField("Result format", text: $configuration.diagnostics.mtuResultsFileFormat).zanozaPlainInput()
                TextField("Section separator", text: $configuration.diagnostics.mtuSectionSeparator).zanozaPlainInput()
                TextField("Removed format", text: $configuration.diagnostics.mtuRemovedLogFormat).zanozaPlainInput()
                TextField("Added format", text: $configuration.diagnostics.mtuAddedLogFormat).zanozaPlainInput()
                TextField("Reactivated format", text: $configuration.diagnostics.mtuReactiveAddedLogFormat).zanozaPlainInput()
            }
            if !configuration.preservedUnsupportedSettings.isEmpty {
                LabeledContent("Preserved unsupported keys") {
                    Text("\(configuration.preservedUnsupportedSettings.count)").foregroundStyle(.orange)
                }
            }
        }
    }
}

struct IntegerSettingRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    init(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) {
        self.title = title; _value = value; self.range = range
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
                TextField("", value: $value, format: .number)
                .multilineTextAlignment(.trailing).frame(width: 96)
                #if os(iOS)
                // Keep the normal keyboard so users can paste values and move
                // the caret naturally; the value is still clamped below.
                .keyboardType(.default)
                #endif
                .onChange(of: value) { newValue in
                    value = min(max(newValue, range.lowerBound), range.upperBound)
                }
        }
    }
}

struct DecimalSettingRow: View {
    let title: String
    @Binding var value: Double
    let suffix: String

    init(_ title: String, value: Binding<Double>, suffix: String = "") {
        self.title = title; _value = value; self.suffix = suffix
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
                TextField("", value: $value, format: .number.precision(.fractionLength(0...3)))
                .multilineTextAlignment(.trailing).frame(width: 96)
                #if os(iOS)
                .keyboardType(.default)
                #endif
            if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary) }
        }
    }
}

extension View {
    @ViewBuilder
    func zanozaPlainInput() -> some View {
        #if os(iOS)
        self.textFieldStyle(.plain).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.textFieldStyle(.plain)
        #endif
    }
}
