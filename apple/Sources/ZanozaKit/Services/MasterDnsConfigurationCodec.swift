import Foundation

public enum MasterDnsConfigurationCodec {
    private static let assignment = try! NSRegularExpression(
        pattern: #"^\s*([A-Za-z][A-Za-z0-9_]*)\s*(?:=|:)\s*(.*?)\s*$"#
    )

    public static func looksLikeConfiguration(_ text: String) -> Bool {
        let upper = text.uppercased()
        return upper.contains("DOMAINS") || upper.contains("ENCRYPTION_KEY")
            || upper.contains("DATA_ENCRYPTION_METHOD")
    }

    public static func importProfile(from text: String) throws -> ImportedProfileBundle {
        let values = assignments(in: text)
        let domain = firstString(values["DOMAINS"] ?? values["DOMAIN"] ?? "")
            .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !domain.isEmpty else { throw ProfileShareCodecError.missingDomain }
        let encryptionKey = string(values["ENCRYPTION_KEY"] ?? "")
        guard !encryptionKey.isEmpty else { throw ProfileShareCodecError.missingEncryptionKey }

        var config = MasterDnsClientConfiguration.preset(.andronReliability)
        var consumed: Set<String> = [
            "DOMAINS", "DOMAIN", "ENCRYPTION_KEY", "DATA_ENCRYPTION_METHOD", "PROFILE_NAME", "NAME"
        ]
        func use(_ key: String, _ action: (String) -> Void) {
            guard let value = values[key] else { return }
            consumed.insert(key)
            action(value)
        }

        use("PROTOCOL_TYPE") { config.listener.protocolType = LocalProxyProtocol(rawValue: string($0).uppercased()) ?? .socks5 }
        use("LISTEN_IP") { config.listener.listenIP = string($0) }
        use("LISTEN_PORT") { config.listener.listenPort = int($0, config.listener.listenPort) }
        use("SOCKS5_AUTH") { config.listener.socksAuth = bool($0, config.listener.socksAuth) }
        use("SOCKS5_USER") { config.listener.socksUser = string($0) }
        use("SOCKS5_PASS") { config.listener.socksPass = string($0) }
        use("HTTP_PROXY_ENABLED") { config.listener.httpProxyEnabled = bool($0, config.listener.httpProxyEnabled) }
        use("HTTP_PROXY_PORT") { config.listener.httpProxyPort = int($0, config.listener.httpProxyPort) }
        use("SOCKS_OPTIMISTIC_CONNECT") { config.listener.optimisticSocksConnect = bool($0, config.listener.optimisticSocksConnect) }
        use("LOCAL_HANDSHAKE_TIMEOUT_SECONDS") { config.listener.localHandshakeTimeoutSeconds = double($0, config.listener.localHandshakeTimeoutSeconds) }

        use("LOCAL_DNS_ENABLED") { config.localDNS.enabled = bool($0, config.localDNS.enabled) }
        use("LOCAL_DNS_IP") { config.localDNS.listenIP = string($0) }
        use("LOCAL_DNS_PORT") { config.localDNS.port = int($0, config.localDNS.port) }
        use("LOCAL_DNS_CACHE_MAX_RECORDS") { config.localDNS.cacheMaxRecords = int($0, config.localDNS.cacheMaxRecords) }
        use("LOCAL_DNS_CACHE_TTL_SECONDS") { config.localDNS.cacheTTLSeconds = double($0, config.localDNS.cacheTTLSeconds) }
        use("LOCAL_DNS_PENDING_TIMEOUT_SECONDS") { config.localDNS.pendingTimeoutSeconds = double($0, config.localDNS.pendingTimeoutSeconds) }
        use("DNS_RESPONSE_FRAGMENT_TIMEOUT_SECONDS") { config.localDNS.fragmentTimeoutSeconds = double($0, config.localDNS.fragmentTimeoutSeconds) }
        use("LOCAL_DNS_CACHE_PERSIST_TO_FILE") { config.localDNS.persistCache = bool($0, config.localDNS.persistCache) }
        use("LOCAL_DNS_CACHE_FLUSH_INTERVAL_SECONDS") { config.localDNS.cacheFlushIntervalSeconds = double($0, config.localDNS.cacheFlushIntervalSeconds) }

        use("RESOLVER_BALANCING_STRATEGY") { config.resolver.balancingStrategy = BalancingStrategy(rawValue: int($0, 3)) ?? .leastLoss }
        use("PACKET_DUPLICATION_COUNT") { config.resolver.packetDuplicationCount = int($0, config.resolver.packetDuplicationCount) }
        use("UPLOAD_PACKET_DUPLICATION_COUNT") { config.resolver.packetDuplicationCount = int($0, config.resolver.packetDuplicationCount) }
        use("SETUP_PACKET_DUPLICATION_COUNT") { config.resolver.setupPacketDuplicationCount = int($0, config.resolver.setupPacketDuplicationCount) }
        use("STREAM_RESOLVER_FAILOVER_RESEND_THRESHOLD") { config.resolver.failoverResendThreshold = int($0, config.resolver.failoverResendThreshold) }
        use("STREAM_RESOLVER_FAILOVER_COOLDOWN") { config.resolver.failoverCooldownSeconds = double($0, config.resolver.failoverCooldownSeconds) }
        use("RECHECK_INACTIVE_SERVERS_ENABLED") { config.resolver.recheckInactiveServers = bool($0, config.resolver.recheckInactiveServers) }
        use("AUTO_DISABLE_TIMEOUT_SERVERS") { config.resolver.autoDisableTimeoutServers = bool($0, config.resolver.autoDisableTimeoutServers) }
        use("AUTO_DISABLE_TIMEOUT_WINDOW_SECONDS") { config.resolver.autoDisableTimeoutWindowSeconds = double($0, config.resolver.autoDisableTimeoutWindowSeconds) }
        use("BASE_ENCODE_DATA") { config.resolver.baseEncodeData = bool($0, config.resolver.baseEncodeData) }

        use("UPLOAD_COMPRESSION_TYPE") { config.encoding.uploadCompression = CompressionType(rawValue: int($0, 0)) ?? .off }
        use("DOWNLOAD_COMPRESSION_TYPE") { config.encoding.downloadCompression = CompressionType(rawValue: int($0, 0)) ?? .off }
        use("COMPRESSION_MIN_SIZE") { config.encoding.compressionMinSize = int($0, config.encoding.compressionMinSize) }

        use("MIN_UPLOAD_MTU") { config.mtu.minUpload = int($0, config.mtu.minUpload) }
        use("MIN_DOWNLOAD_MTU") { config.mtu.minDownload = int($0, config.mtu.minDownload) }
        use("MAX_UPLOAD_MTU") { config.mtu.maxUpload = int($0, config.mtu.maxUpload) }
        use("MAX_DOWNLOAD_MTU") { config.mtu.maxDownload = int($0, config.mtu.maxDownload) }
        use("AUTO_REMOVE_LOW_MTU_SERVERS") { config.mtu.autoRemoveLowMTUResolvers = bool($0, config.mtu.autoRemoveLowMTUResolvers) }
        for key in ["MTU_TEST_RETRIES", "MTU_TEST_RETRIES_RESOLVERS"] {
            use(key) { config.mtu.testRetries = int($0, config.mtu.testRetries) }
        }
        for key in ["MTU_TEST_TIMEOUT", "MTU_TEST_TIMEOUT_RESOLVERS"] {
            use(key) { config.mtu.testTimeoutSeconds = double($0, config.mtu.testTimeoutSeconds) }
        }
        for key in ["MTU_TEST_PARALLELISM", "MTU_TEST_PARALLELISM_RESOLVERS"] {
            use(key) { config.mtu.testParallelism = int($0, config.mtu.testParallelism) }
        }

        use("RX_TX_WORKERS") { config.runtime.rxTxWorkers = int($0, config.runtime.rxTxWorkers) }
        use("TUNNEL_PROCESS_WORKERS") { config.runtime.tunnelProcessWorkers = int($0, config.runtime.tunnelProcessWorkers) }
        use("TUNNEL_PACKET_TIMEOUT_SECONDS") { config.runtime.tunnelPacketTimeoutSeconds = double($0, config.runtime.tunnelPacketTimeoutSeconds) }
        use("DISPATCHER_IDLE_POLL_INTERVAL_SECONDS") { config.runtime.dispatcherIdlePollIntervalSeconds = double($0, config.runtime.dispatcherIdlePollIntervalSeconds) }
        use("RX_CHANNEL_SIZE") { config.runtime.rxChannelSize = int($0, config.runtime.rxChannelSize) }
        use("SOCKS_UDP_ASSOCIATE_READ_TIMEOUT_SECONDS") { config.runtime.socksUDPAssociateReadTimeoutSeconds = double($0, config.runtime.socksUDPAssociateReadTimeoutSeconds) }
        use("CLIENT_TERMINAL_STREAM_RETENTION_SECONDS") { config.runtime.terminalStreamRetentionSeconds = double($0, config.runtime.terminalStreamRetentionSeconds) }
        use("CLIENT_CANCELLED_SETUP_RETENTION_SECONDS") { config.runtime.cancelledSetupRetentionSeconds = double($0, config.runtime.cancelledSetupRetentionSeconds) }

        use("SESSION_INIT_RETRY_BASE_SECONDS") { config.session.retryBaseSeconds = double($0, config.session.retryBaseSeconds) }
        use("SESSION_INIT_RETRY_STEP_SECONDS") { config.session.retryStepSeconds = double($0, config.session.retryStepSeconds) }
        use("SESSION_INIT_RETRY_LINEAR_AFTER") { config.session.retryLinearAfter = int($0, config.session.retryLinearAfter) }
        use("SESSION_INIT_RETRY_MAX_SECONDS") { config.session.retryMaxSeconds = double($0, config.session.retryMaxSeconds) }
        use("SESSION_INIT_BUSY_RETRY_INTERVAL_SECONDS") { config.session.busyRetryIntervalSeconds = double($0, config.session.busyRetryIntervalSeconds) }
        use("SESSION_INIT_RACING_COUNT") { config.session.racingCount = int($0, config.session.racingCount) }

        use("PING_AGGRESSIVE_INTERVAL_SECONDS") { config.ping.aggressiveIntervalSeconds = double($0, config.ping.aggressiveIntervalSeconds) }
        use("PING_LAZY_INTERVAL_SECONDS") { config.ping.lazyIntervalSeconds = double($0, config.ping.lazyIntervalSeconds) }
        use("PING_COOLDOWN_INTERVAL_SECONDS") { config.ping.cooldownIntervalSeconds = double($0, config.ping.cooldownIntervalSeconds) }
        use("PING_COLD_INTERVAL_SECONDS") { config.ping.coldIntervalSeconds = double($0, config.ping.coldIntervalSeconds) }
        use("PING_WARM_THRESHOLD_SECONDS") { config.ping.warmThresholdSeconds = double($0, config.ping.warmThresholdSeconds) }
        use("PING_COOL_THRESHOLD_SECONDS") { config.ping.coolThresholdSeconds = double($0, config.ping.coolThresholdSeconds) }
        use("PING_COLD_THRESHOLD_SECONDS") { config.ping.coldThresholdSeconds = double($0, config.ping.coldThresholdSeconds) }

        use("MAX_PACKETS_PER_BATCH") { config.arq.maxPacketsPerBatch = int($0, config.arq.maxPacketsPerBatch) }
        use("ARQ_WINDOW_SIZE") { config.arq.windowSize = int($0, config.arq.windowSize) }
        use("ARQ_INITIAL_RTO_SECONDS") { config.arq.initialRTOSeconds = double($0, config.arq.initialRTOSeconds) }
        use("ARQ_MAX_RTO_SECONDS") { config.arq.maxRTOSeconds = double($0, config.arq.maxRTOSeconds) }
        use("ARQ_CONTROL_INITIAL_RTO_SECONDS") { config.arq.controlInitialRTOSeconds = double($0, config.arq.controlInitialRTOSeconds) }
        use("ARQ_CONTROL_MAX_RTO_SECONDS") { config.arq.controlMaxRTOSeconds = double($0, config.arq.controlMaxRTOSeconds) }
        use("ARQ_MAX_CONTROL_RETRIES") { config.arq.maxControlRetries = int($0, config.arq.maxControlRetries) }
        use("ARQ_INACTIVITY_TIMEOUT_SECONDS") { config.arq.inactivityTimeoutSeconds = double($0, config.arq.inactivityTimeoutSeconds) }
        use("ARQ_DATA_PACKET_TTL_SECONDS") { config.arq.dataPacketTTLSeconds = double($0, config.arq.dataPacketTTLSeconds) }
        use("ARQ_CONTROL_PACKET_TTL_SECONDS") { config.arq.controlPacketTTLSeconds = double($0, config.arq.controlPacketTTLSeconds) }
        use("ARQ_MAX_DATA_RETRIES") { config.arq.maxDataRetries = int($0, config.arq.maxDataRetries) }
        use("ARQ_DATA_NACK_MAX_GAP") { config.arq.dataNackMaxGap = int($0, config.arq.dataNackMaxGap) }
        use("ARQ_DATA_NACK_INITIAL_DELAY_SECONDS") { config.arq.dataNackInitialDelaySeconds = double($0, config.arq.dataNackInitialDelaySeconds) }
        use("ARQ_DATA_NACK_REPEAT_SECONDS") { config.arq.dataNackRepeatSeconds = double($0, config.arq.dataNackRepeatSeconds) }
        use("ARQ_TERMINAL_DRAIN_TIMEOUT_SECONDS") { config.arq.terminalDrainTimeoutSeconds = double($0, config.arq.terminalDrainTimeoutSeconds) }
        use("ARQ_TERMINAL_ACK_WAIT_TIMEOUT_SECONDS") { config.arq.terminalAckWaitTimeoutSeconds = double($0, config.arq.terminalAckWaitTimeoutSeconds) }

        use("SAVE_MTU_SERVERS_TO_FILE") { config.diagnostics.saveMTUResults = bool($0, config.diagnostics.saveMTUResults) }
        use("MTU_SERVERS_FILE_NAME") { config.diagnostics.mtuResultsFileName = string($0) }
        use("MTU_SERVERS_FILE_FORMAT") { config.diagnostics.mtuResultsFileFormat = string($0) }
        use("MTU_USING_SECTION_SEPARATOR_TEXT") { config.diagnostics.mtuSectionSeparator = string($0) }
        use("MTU_REMOVED_SERVER_LOG_FORMAT") { config.diagnostics.mtuRemovedLogFormat = string($0) }
        use("MTU_ADDED_SERVER_LOG_FORMAT") { config.diagnostics.mtuAddedLogFormat = string($0) }
        use("MTU_REACTIVE_ADDED_SERVER_LOG_FORMAT") { config.diagnostics.mtuReactiveAddedLogFormat = string($0) }
        use("LOG_LEVEL") { config.logLevel = LogLevel(rawValue: string($0).uppercased()) ?? .info }

        for (name, value) in values where !consumed.contains(name) {
            config.preservedUnsupportedSettings[name] = value
        }
        config.normalize()

        let method = EncryptionMethod(rawValue: int(values["DATA_ENCRYPTION_METHOD"] ?? "5", 5)) ?? .aes256gcm
        let displayName = string(values["PROFILE_NAME"] ?? values["NAME"] ?? domain)
        let profile = ConnectionProfile(
            name: displayName,
            domain: domain,
            encryptionKey: encryptionKey,
            encryptionMethod: method,
            uploadCompression: config.encoding.uploadCompression,
            downloadCompression: config.encoding.downloadCompression,
            packetDuplicationCount: config.resolver.packetDuplicationCount,
            setupPacketDuplicationCount: config.resolver.setupPacketDuplicationCount,
            resolverBalancingStrategy: config.resolver.balancingStrategy,
            logLevel: config.logLevel,
            configuration: config,
            appliedConfigurationPreset: .custom
        )
        var warnings: [String] = []
        if !config.preservedUnsupportedSettings.isEmpty {
            warnings.append("Preserved \(config.preservedUnsupportedSettings.count) unsupported settings; they are not active in this embedded MasterDNS core.")
        }
        return ImportedProfileBundle(profile: profile, warnings: warnings)
    }

    /// Applies a settings-only TOML/KEY=VALUE snippet to an existing profile.
    /// Server identity is retained so copying tuning advice from a chat cannot
    /// silently replace the user's domain or shared secret. An explicitly
    /// supplied encryption method is applied because it is a protocol setting.
    public static func applyConfiguration(
        from text: String,
        to baseProfile: ConnectionProfile
    ) throws -> ImportedProfileBundle {
        let values = assignments(in: text)
        var augmented = text
        if values["DOMAINS"] == nil && values["DOMAIN"] == nil {
            augmented += "\nDOMAINS = [\"\(tomlEscape(baseProfile.domain))\"]\n"
        }
        if values["ENCRYPTION_KEY"] == nil {
            augmented += "ENCRYPTION_KEY = \"\(tomlEscape(baseProfile.encryptionKey))\"\n"
        }
        var imported = try importProfile(from: augmented)
        var merged = baseProfile
        merged.configuration = imported.profile.configuration
        merged.appliedConfigurationPreset = .custom
        if values["DATA_ENCRYPTION_METHOD"] != nil {
            merged.encryptionMethod = imported.profile.encryptionMethod
        }
        imported.profile = merged
        return imported
    }

    public static func exportTOML(_ profile: ConnectionProfile) -> String {
        ConfigBuilder.buildTOML(for: profile, settings: AppSettings())
    }

    private static func assignments(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        for sourceLine in text.components(separatedBy: .newlines) {
            let line = stripComment(sourceLine)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = assignment.firstMatch(in: line, range: range),
                  let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { continue }
            result[String(line[keyRange]).uppercased()] = String(line[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func stripComment(_ line: String) -> String {
        var quoted = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if character == "\\" && quoted { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if character == "#" && !quoted { return String(line[..<index]) }
        }
        return line
    }

    private static func string(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func firstString(_ value: String) -> String {
        if let firstQuote = value.firstIndex(of: "\"") {
            let rest = value[value.index(after: firstQuote)...]
            if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
        }
        return string(value).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",", maxSplits: 1).first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    private static func int(_ value: String, _ fallback: Int) -> Int {
        Int(string(value).replacingOccurrences(of: "_", with: "")) ?? fallback
    }

    private static func double(_ value: String, _ fallback: Double) -> Double {
        Double(string(value).replacingOccurrences(of: "_", with: "")) ?? fallback
    }

    private static func bool(_ value: String, _ fallback: Bool) -> Bool {
        switch string(value).lowercased() {
        case "true", "1", "yes", "on": true
        case "false", "0", "no", "off": false
        default: fallback
        }
    }

    private static func tomlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
