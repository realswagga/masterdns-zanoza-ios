import Foundation

// Builds the TOML configuration text consumed by the embedded MasterDnsVPN
// Go client. Every emitted key is typed in MasterDnsClientConfiguration and is
// accepted either by upstream MasterDNS or by Zanoza's small compatibility
// extension (HTTP proxy + optimistic SOCKS acknowledgement).
public enum ConfigBuilder {
    public static func buildTOML(for profile: ConnectionProfile, settings _: AppSettings) -> String {
        let domain = escape(profile.domain)
        let key = escape(profile.encryptionKey)
        var config = profile.configuration
        config.normalize()
        let listener = config.listener
        let dns = config.localDNS
        let resolver = config.resolver
        let encoding = config.encoding
        let mtu = config.mtu
        let runtime = config.runtime
        let session = config.session
        let ping = config.ping
        let arq = config.arq
        let diagnostics = config.diagnostics

        return """
        # Zanoza generated client_config.toml — do not edit manually.
        DOMAINS = ["\(domain)"]
        DATA_ENCRYPTION_METHOD = \(profile.encryptionMethod.rawValue)
        ENCRYPTION_KEY = "\(key)"

        PROTOCOL_TYPE = "\(listener.protocolType.rawValue)"
        LISTEN_IP = "\(escape(listener.listenIP))"
        LISTEN_PORT = \(listener.listenPort)
        SOCKS5_AUTH = \(bool(listener.socksAuth))
        SOCKS5_USER = "\(escape(listener.socksUser))"
        SOCKS5_PASS = "\(escape(listener.socksPass))"
        HTTP_PROXY_ENABLED = \(bool(listener.httpProxyEnabled))
        HTTP_PROXY_PORT = \(listener.httpProxyPort)
        SOCKS_OPTIMISTIC_CONNECT = \(bool(listener.optimisticSocksConnect))
        LOCAL_HANDSHAKE_TIMEOUT_SECONDS = \(decimal(listener.localHandshakeTimeoutSeconds))

        LOCAL_DNS_ENABLED = \(bool(dns.enabled))
        LOCAL_DNS_IP = "\(escape(dns.listenIP))"
        LOCAL_DNS_PORT = \(dns.port)
        LOCAL_DNS_CACHE_MAX_RECORDS = \(dns.cacheMaxRecords)
        LOCAL_DNS_CACHE_TTL_SECONDS = \(decimal(dns.cacheTTLSeconds))
        LOCAL_DNS_PENDING_TIMEOUT_SECONDS = \(decimal(dns.pendingTimeoutSeconds))
        DNS_RESPONSE_FRAGMENT_TIMEOUT_SECONDS = \(decimal(dns.fragmentTimeoutSeconds))
        LOCAL_DNS_CACHE_PERSIST_TO_FILE = \(bool(dns.persistCache))
        LOCAL_DNS_CACHE_FLUSH_INTERVAL_SECONDS = \(decimal(dns.cacheFlushIntervalSeconds))

        RESOLVER_BALANCING_STRATEGY = \(resolver.balancingStrategy.rawValue)
        PACKET_DUPLICATION_COUNT = \(resolver.packetDuplicationCount)
        SETUP_PACKET_DUPLICATION_COUNT = \(resolver.setupPacketDuplicationCount)
        STREAM_RESOLVER_FAILOVER_RESEND_THRESHOLD = \(resolver.failoverResendThreshold)
        STREAM_RESOLVER_FAILOVER_COOLDOWN = \(decimal(resolver.failoverCooldownSeconds))
        RECHECK_INACTIVE_SERVERS_ENABLED = \(bool(resolver.recheckInactiveServers))
        AUTO_DISABLE_TIMEOUT_SERVERS = \(bool(resolver.autoDisableTimeoutServers))
        AUTO_DISABLE_TIMEOUT_WINDOW_SECONDS = \(decimal(resolver.autoDisableTimeoutWindowSeconds))
        BASE_ENCODE_DATA = \(bool(resolver.baseEncodeData))

        UPLOAD_COMPRESSION_TYPE = \(encoding.uploadCompression.rawValue)
        DOWNLOAD_COMPRESSION_TYPE = \(encoding.downloadCompression.rawValue)
        COMPRESSION_MIN_SIZE = \(encoding.compressionMinSize)

        MIN_UPLOAD_MTU = \(mtu.minUpload)
        MIN_DOWNLOAD_MTU = \(mtu.minDownload)
        MAX_UPLOAD_MTU = \(mtu.maxUpload)
        MAX_DOWNLOAD_MTU = \(mtu.maxDownload)
        AUTO_REMOVE_LOW_MTU_SERVERS = \(bool(mtu.autoRemoveLowMTUResolvers))
        MTU_TEST_RETRIES = \(mtu.testRetries)
        MTU_TEST_TIMEOUT = \(decimal(mtu.testTimeoutSeconds))
        MTU_TEST_PARALLELISM = \(mtu.testParallelism)

        RX_TX_WORKERS = \(runtime.rxTxWorkers)
        TUNNEL_PROCESS_WORKERS = \(runtime.tunnelProcessWorkers)
        TUNNEL_PACKET_TIMEOUT_SECONDS = \(decimal(runtime.tunnelPacketTimeoutSeconds))
        DISPATCHER_IDLE_POLL_INTERVAL_SECONDS = \(decimal(runtime.dispatcherIdlePollIntervalSeconds))
        RX_CHANNEL_SIZE = \(runtime.rxChannelSize)
        SOCKS_UDP_ASSOCIATE_READ_TIMEOUT_SECONDS = \(decimal(runtime.socksUDPAssociateReadTimeoutSeconds))
        CLIENT_TERMINAL_STREAM_RETENTION_SECONDS = \(decimal(runtime.terminalStreamRetentionSeconds))
        CLIENT_CANCELLED_SETUP_RETENTION_SECONDS = \(decimal(runtime.cancelledSetupRetentionSeconds))

        SESSION_INIT_RETRY_BASE_SECONDS = \(decimal(session.retryBaseSeconds))
        SESSION_INIT_RETRY_STEP_SECONDS = \(decimal(session.retryStepSeconds))
        SESSION_INIT_RETRY_LINEAR_AFTER = \(session.retryLinearAfter)
        SESSION_INIT_RETRY_MAX_SECONDS = \(decimal(session.retryMaxSeconds))
        SESSION_INIT_BUSY_RETRY_INTERVAL_SECONDS = \(decimal(session.busyRetryIntervalSeconds))
        SESSION_INIT_RACING_COUNT = \(session.racingCount)

        PING_AGGRESSIVE_INTERVAL_SECONDS = \(decimal(ping.aggressiveIntervalSeconds))
        PING_LAZY_INTERVAL_SECONDS = \(decimal(ping.lazyIntervalSeconds))
        PING_COOLDOWN_INTERVAL_SECONDS = \(decimal(ping.cooldownIntervalSeconds))
        PING_COLD_INTERVAL_SECONDS = \(decimal(ping.coldIntervalSeconds))
        PING_WARM_THRESHOLD_SECONDS = \(decimal(ping.warmThresholdSeconds))
        PING_COOL_THRESHOLD_SECONDS = \(decimal(ping.coolThresholdSeconds))
        PING_COLD_THRESHOLD_SECONDS = \(decimal(ping.coldThresholdSeconds))

        MAX_PACKETS_PER_BATCH = \(arq.maxPacketsPerBatch)
        ARQ_WINDOW_SIZE = \(arq.windowSize)
        ARQ_INITIAL_RTO_SECONDS = \(decimal(arq.initialRTOSeconds))
        ARQ_MAX_RTO_SECONDS = \(decimal(arq.maxRTOSeconds))
        ARQ_CONTROL_INITIAL_RTO_SECONDS = \(decimal(arq.controlInitialRTOSeconds))
        ARQ_CONTROL_MAX_RTO_SECONDS = \(decimal(arq.controlMaxRTOSeconds))
        ARQ_MAX_CONTROL_RETRIES = \(arq.maxControlRetries)
        ARQ_INACTIVITY_TIMEOUT_SECONDS = \(decimal(arq.inactivityTimeoutSeconds))
        ARQ_DATA_PACKET_TTL_SECONDS = \(decimal(arq.dataPacketTTLSeconds))
        ARQ_CONTROL_PACKET_TTL_SECONDS = \(decimal(arq.controlPacketTTLSeconds))
        ARQ_MAX_DATA_RETRIES = \(arq.maxDataRetries)
        ARQ_DATA_NACK_MAX_GAP = \(arq.dataNackMaxGap)
        ARQ_DATA_NACK_INITIAL_DELAY_SECONDS = \(decimal(arq.dataNackInitialDelaySeconds))
        ARQ_DATA_NACK_REPEAT_SECONDS = \(decimal(arq.dataNackRepeatSeconds))
        ARQ_TERMINAL_DRAIN_TIMEOUT_SECONDS = \(decimal(arq.terminalDrainTimeoutSeconds))
        ARQ_TERMINAL_ACK_WAIT_TIMEOUT_SECONDS = \(decimal(arq.terminalAckWaitTimeoutSeconds))

        SAVE_MTU_SERVERS_TO_FILE = \(bool(diagnostics.saveMTUResults))
        MTU_SERVERS_FILE_NAME = "\(escape(diagnostics.mtuResultsFileName))"
        MTU_SERVERS_FILE_FORMAT = "\(escape(diagnostics.mtuResultsFileFormat))"
        MTU_USING_SECTION_SEPARATOR_TEXT = "\(escape(diagnostics.mtuSectionSeparator))"
        MTU_REMOVED_SERVER_LOG_FORMAT = "\(escape(diagnostics.mtuRemovedLogFormat))"
        MTU_ADDED_SERVER_LOG_FORMAT = "\(escape(diagnostics.mtuAddedLogFormat))"
        MTU_REACTIVE_ADDED_SERVER_LOG_FORMAT = "\(escape(diagnostics.mtuReactiveAddedLogFormat))"

        LOG_LEVEL = "\(config.logLevel.rawValue)"
        """
    }

    public static func resolversText(settings: AppSettings) -> String {
        let custom = settings.customResolvers.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return DefaultResolvers.text
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func bool(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "0.0" }
        var text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.contains(".") && text.last == "0" { text.removeLast() }
        if text.last == "." { text.append("0") }
        return text
    }
}
