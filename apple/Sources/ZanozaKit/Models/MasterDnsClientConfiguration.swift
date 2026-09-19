import Foundation

public enum LocalProxyProtocol: String, CaseIterable, Codable, Identifiable {
    case socks5 = "SOCKS5"
    case tcp = "TCP"

    public var id: String { rawValue }
    public var title: String { rawValue }
}

public enum MasterDnsConfigurationPreset: String, CaseIterable, Codable, Identifiable {
    case compatibility
    case andronReliability
    case performance
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compatibility: "Compatibility"
        case .andronReliability: "Andron Industries"
        case .performance: "Performance"
        case .custom: "Custom"
        }
    }

    public var detail: String {
        switch self {
        case .compatibility:
            "Conservative settings for small or inconsistent resolver pools."
        case .andronReliability:
            "Measured baseline for Russian mobile resolvers and the false.actor server."
        case .performance:
            "Lower redundancy and more workers for already-evaluated resolver pools."
        case .custom:
            "Keep every setting exactly as configured below."
        }
    }
}

/// Every active client-side setting understood by the embedded MasterDnsVPN
/// core. Values are grouped to keep persistence and the advanced editor
/// manageable. The profile domain, encryption method, and encryption key live
/// on `ConnectionProfile`, because they are server identity rather than client
/// runtime tuning.
public struct MasterDnsClientConfiguration: Codable, Equatable {
    public struct Listener: Codable, Equatable {
        public var protocolType: LocalProxyProtocol
        public var listenIP: String
        public var listenPort: Int
        public var socksAuth: Bool
        public var socksUser: String
        public var socksPass: String

        /// Zanoza extension. Starts a CONNECT-capable HTTP proxy backed by the
        /// same MasterDNS streams. It broadens compatibility without changing
        /// the DNS tunnel wire protocol.
        public var httpProxyEnabled: Bool
        public var httpProxyPort: Int

        /// Zanoza extension for clients with a short upstream handshake timer
        /// (notably some Streisand builds). The local success response is sent
        /// before the remote CONNECT acknowledgement; buffered data is released
        /// only after the server confirms the stream.
        public var optimisticSocksConnect: Bool
        public var localHandshakeTimeoutSeconds: Double

        public init(
            protocolType: LocalProxyProtocol = .socks5,
            listenIP: String = "127.0.0.1",
            listenPort: Int = 41080,
            socksAuth: Bool = false,
            socksUser: String = "zanoza",
            socksPass: String = "zanoza",
            httpProxyEnabled: Bool = true,
            httpProxyPort: Int = 41081,
            optimisticSocksConnect: Bool = true,
            localHandshakeTimeoutSeconds: Double = 30
        ) {
            self.protocolType = protocolType
            self.listenIP = listenIP
            self.listenPort = listenPort
            self.socksAuth = socksAuth
            self.socksUser = socksUser
            self.socksPass = socksPass
            self.httpProxyEnabled = httpProxyEnabled
            self.httpProxyPort = httpProxyPort
            self.optimisticSocksConnect = optimisticSocksConnect
            self.localHandshakeTimeoutSeconds = localHandshakeTimeoutSeconds
        }
    }

    public struct LocalDNS: Codable, Equatable {
        public var enabled: Bool
        public var listenIP: String
        public var port: Int
        public var cacheMaxRecords: Int
        public var cacheTTLSeconds: Double
        public var pendingTimeoutSeconds: Double
        public var fragmentTimeoutSeconds: Double
        public var persistCache: Bool
        public var cacheFlushIntervalSeconds: Double

        public init(
            enabled: Bool = false,
            listenIP: String = "127.0.0.1",
            port: Int = 53,
            cacheMaxRecords: Int = 10_000,
            cacheTTLSeconds: Double = 14_400,
            pendingTimeoutSeconds: Double = 300,
            fragmentTimeoutSeconds: Double = 60,
            persistCache: Bool = false,
            cacheFlushIntervalSeconds: Double = 60
        ) {
            self.enabled = enabled
            self.listenIP = listenIP
            self.port = port
            self.cacheMaxRecords = cacheMaxRecords
            self.cacheTTLSeconds = cacheTTLSeconds
            self.pendingTimeoutSeconds = pendingTimeoutSeconds
            self.fragmentTimeoutSeconds = fragmentTimeoutSeconds
            self.persistCache = persistCache
            self.cacheFlushIntervalSeconds = cacheFlushIntervalSeconds
        }
    }

    public struct ResolverTransport: Codable, Equatable {
        public var balancingStrategy: BalancingStrategy
        public var packetDuplicationCount: Int
        public var setupPacketDuplicationCount: Int
        public var failoverResendThreshold: Int
        public var failoverCooldownSeconds: Double
        public var recheckInactiveServers: Bool
        public var autoDisableTimeoutServers: Bool
        public var autoDisableTimeoutWindowSeconds: Double
        public var baseEncodeData: Bool

        public init(
            balancingStrategy: BalancingStrategy = .leastLoss,
            packetDuplicationCount: Int = 2,
            setupPacketDuplicationCount: Int = 3,
            failoverResendThreshold: Int = 2,
            failoverCooldownSeconds: Double = 2.5,
            recheckInactiveServers: Bool = true,
            autoDisableTimeoutServers: Bool = true,
            autoDisableTimeoutWindowSeconds: Double = 30,
            baseEncodeData: Bool = true
        ) {
            self.balancingStrategy = balancingStrategy
            self.packetDuplicationCount = packetDuplicationCount
            self.setupPacketDuplicationCount = setupPacketDuplicationCount
            self.failoverResendThreshold = failoverResendThreshold
            self.failoverCooldownSeconds = failoverCooldownSeconds
            self.recheckInactiveServers = recheckInactiveServers
            self.autoDisableTimeoutServers = autoDisableTimeoutServers
            self.autoDisableTimeoutWindowSeconds = autoDisableTimeoutWindowSeconds
            self.baseEncodeData = baseEncodeData
        }
    }

    public struct Encoding: Codable, Equatable {
        public var uploadCompression: CompressionType
        public var downloadCompression: CompressionType
        public var compressionMinSize: Int

        public init(
            uploadCompression: CompressionType = .off,
            downloadCompression: CompressionType = .off,
            compressionMinSize: Int = 120
        ) {
            self.uploadCompression = uploadCompression
            self.downloadCompression = downloadCompression
            self.compressionMinSize = compressionMinSize
        }
    }

    public struct MTU: Codable, Equatable {
        public var minUpload: Int
        public var minDownload: Int
        public var maxUpload: Int
        public var maxDownload: Int
        public var autoRemoveLowMTUResolvers: Bool
        public var testRetries: Int
        public var testTimeoutSeconds: Double
        public var testParallelism: Int

        public init(
            minUpload: Int = 40,
            minDownload: Int = 200,
            maxUpload: Int = 133,
            maxDownload: Int = 2_048,
            autoRemoveLowMTUResolvers: Bool = false,
            testRetries: Int = 3,
            testTimeoutSeconds: Double = 2,
            testParallelism: Int = 32
        ) {
            self.minUpload = minUpload
            self.minDownload = minDownload
            self.maxUpload = maxUpload
            self.maxDownload = maxDownload
            self.autoRemoveLowMTUResolvers = autoRemoveLowMTUResolvers
            self.testRetries = testRetries
            self.testTimeoutSeconds = testTimeoutSeconds
            self.testParallelism = testParallelism
        }
    }

    public struct Runtime: Codable, Equatable {
        public var rxTxWorkers: Int
        public var tunnelProcessWorkers: Int
        public var tunnelPacketTimeoutSeconds: Double
        public var dispatcherIdlePollIntervalSeconds: Double
        public var rxChannelSize: Int
        public var socksUDPAssociateReadTimeoutSeconds: Double
        public var terminalStreamRetentionSeconds: Double
        public var cancelledSetupRetentionSeconds: Double

        public init(
            rxTxWorkers: Int = 8,
            tunnelProcessWorkers: Int = 8,
            tunnelPacketTimeoutSeconds: Double = 10,
            dispatcherIdlePollIntervalSeconds: Double = 0.02,
            rxChannelSize: Int = 4_096,
            socksUDPAssociateReadTimeoutSeconds: Double = 30,
            terminalStreamRetentionSeconds: Double = 45,
            cancelledSetupRetentionSeconds: Double = 120
        ) {
            self.rxTxWorkers = rxTxWorkers
            self.tunnelProcessWorkers = tunnelProcessWorkers
            self.tunnelPacketTimeoutSeconds = tunnelPacketTimeoutSeconds
            self.dispatcherIdlePollIntervalSeconds = dispatcherIdlePollIntervalSeconds
            self.rxChannelSize = rxChannelSize
            self.socksUDPAssociateReadTimeoutSeconds = socksUDPAssociateReadTimeoutSeconds
            self.terminalStreamRetentionSeconds = terminalStreamRetentionSeconds
            self.cancelledSetupRetentionSeconds = cancelledSetupRetentionSeconds
        }
    }

    public struct Session: Codable, Equatable {
        public var retryBaseSeconds: Double
        public var retryStepSeconds: Double
        public var retryLinearAfter: Int
        public var retryMaxSeconds: Double
        public var busyRetryIntervalSeconds: Double
        public var racingCount: Int

        public init(
            retryBaseSeconds: Double = 1,
            retryStepSeconds: Double = 1,
            retryLinearAfter: Int = 5,
            retryMaxSeconds: Double = 60,
            busyRetryIntervalSeconds: Double = 60,
            racingCount: Int = 3
        ) {
            self.retryBaseSeconds = retryBaseSeconds
            self.retryStepSeconds = retryStepSeconds
            self.retryLinearAfter = retryLinearAfter
            self.retryMaxSeconds = retryMaxSeconds
            self.busyRetryIntervalSeconds = busyRetryIntervalSeconds
            self.racingCount = racingCount
        }
    }

    public struct Ping: Codable, Equatable {
        public var aggressiveIntervalSeconds: Double
        public var lazyIntervalSeconds: Double
        public var cooldownIntervalSeconds: Double
        public var coldIntervalSeconds: Double
        public var warmThresholdSeconds: Double
        public var coolThresholdSeconds: Double
        public var coldThresholdSeconds: Double

        public init(
            aggressiveIntervalSeconds: Double = 0.1,
            lazyIntervalSeconds: Double = 0.75,
            cooldownIntervalSeconds: Double = 2,
            coldIntervalSeconds: Double = 15,
            warmThresholdSeconds: Double = 8,
            coolThresholdSeconds: Double = 20,
            coldThresholdSeconds: Double = 30
        ) {
            self.aggressiveIntervalSeconds = aggressiveIntervalSeconds
            self.lazyIntervalSeconds = lazyIntervalSeconds
            self.cooldownIntervalSeconds = cooldownIntervalSeconds
            self.coldIntervalSeconds = coldIntervalSeconds
            self.warmThresholdSeconds = warmThresholdSeconds
            self.coolThresholdSeconds = coolThresholdSeconds
            self.coldThresholdSeconds = coldThresholdSeconds
        }
    }

    public struct ARQ: Codable, Equatable {
        public var maxPacketsPerBatch: Int
        public var windowSize: Int
        public var initialRTOSeconds: Double
        public var maxRTOSeconds: Double
        public var controlInitialRTOSeconds: Double
        public var controlMaxRTOSeconds: Double
        public var maxControlRetries: Int
        public var inactivityTimeoutSeconds: Double
        public var dataPacketTTLSeconds: Double
        public var controlPacketTTLSeconds: Double
        public var maxDataRetries: Int
        public var dataNackMaxGap: Int
        public var dataNackInitialDelaySeconds: Double
        public var dataNackRepeatSeconds: Double
        public var terminalDrainTimeoutSeconds: Double
        public var terminalAckWaitTimeoutSeconds: Double

        public init(
            maxPacketsPerBatch: Int = 8,
            windowSize: Int = 1_000,
            initialRTOSeconds: Double = 0.5,
            maxRTOSeconds: Double = 3,
            controlInitialRTOSeconds: Double = 0.5,
            controlMaxRTOSeconds: Double = 2,
            maxControlRetries: Int = 126,
            inactivityTimeoutSeconds: Double = 1_800,
            dataPacketTTLSeconds: Double = 2_400,
            controlPacketTTLSeconds: Double = 1_200,
            maxDataRetries: Int = 126,
            dataNackMaxGap: Int = 32,
            dataNackInitialDelaySeconds: Double = 0.1,
            dataNackRepeatSeconds: Double = 0.8,
            terminalDrainTimeoutSeconds: Double = 120,
            terminalAckWaitTimeoutSeconds: Double = 90
        ) {
            self.maxPacketsPerBatch = maxPacketsPerBatch
            self.windowSize = windowSize
            self.initialRTOSeconds = initialRTOSeconds
            self.maxRTOSeconds = maxRTOSeconds
            self.controlInitialRTOSeconds = controlInitialRTOSeconds
            self.controlMaxRTOSeconds = controlMaxRTOSeconds
            self.maxControlRetries = maxControlRetries
            self.inactivityTimeoutSeconds = inactivityTimeoutSeconds
            self.dataPacketTTLSeconds = dataPacketTTLSeconds
            self.controlPacketTTLSeconds = controlPacketTTLSeconds
            self.maxDataRetries = maxDataRetries
            self.dataNackMaxGap = dataNackMaxGap
            self.dataNackInitialDelaySeconds = dataNackInitialDelaySeconds
            self.dataNackRepeatSeconds = dataNackRepeatSeconds
            self.terminalDrainTimeoutSeconds = terminalDrainTimeoutSeconds
            self.terminalAckWaitTimeoutSeconds = terminalAckWaitTimeoutSeconds
        }
    }

    public struct Diagnostics: Codable, Equatable {
        public var saveMTUResults: Bool
        public var mtuResultsFileName: String
        public var mtuResultsFileFormat: String
        public var mtuSectionSeparator: String
        public var mtuRemovedLogFormat: String
        public var mtuAddedLogFormat: String
        public var mtuReactiveAddedLogFormat: String

        public init(
            saveMTUResults: Bool = false,
            mtuResultsFileName: String = "masterdnsvpn_success_test_{time}.log",
            mtuResultsFileFormat: String = "{IP} ({DOMAIN}) - UP: {UP_MTU} DOWN: {DOWN_MTU}",
            mtuSectionSeparator: String = "",
            mtuRemovedLogFormat: String = "Resolver {IP} ({DOMAIN}) removed at {TIME} due to {CAUSE}",
            mtuAddedLogFormat: String = "Resolver {IP} ({DOMAIN}) added back at {TIME} (UP {UP_MTU}, DOWN {DOWN_MTU})",
            mtuReactiveAddedLogFormat: String = "Resolver {IP} ({DOMAIN}) added back at {TIME} after reactive recheck (UP {UP_MTU}, DOWN {DOWN_MTU})"
        ) {
            self.saveMTUResults = saveMTUResults
            self.mtuResultsFileName = mtuResultsFileName
            self.mtuResultsFileFormat = mtuResultsFileFormat
            self.mtuSectionSeparator = mtuSectionSeparator
            self.mtuRemovedLogFormat = mtuRemovedLogFormat
            self.mtuAddedLogFormat = mtuAddedLogFormat
            self.mtuReactiveAddedLogFormat = mtuReactiveAddedLogFormat
        }
    }

    public var listener: Listener
    public var localDNS: LocalDNS
    public var resolver: ResolverTransport
    public var encoding: Encoding
    public var mtu: MTU
    public var runtime: Runtime
    public var session: Session
    public var ping: Ping
    public var arq: ARQ
    public var diagnostics: Diagnostics
    public var logLevel: LogLevel

    /// Parsed keys not supported by the embedded MasterDNS version. They are
    /// round-tripped for forward compatibility but deliberately never emitted
    /// into the active TOML unless the core gains typed support for them.
    public var preservedUnsupportedSettings: [String: String]

    public init(
        listener: Listener = Listener(),
        localDNS: LocalDNS = LocalDNS(),
        resolver: ResolverTransport = ResolverTransport(),
        encoding: Encoding = Encoding(),
        mtu: MTU = MTU(),
        runtime: Runtime = Runtime(),
        session: Session = Session(),
        ping: Ping = Ping(),
        arq: ARQ = ARQ(),
        diagnostics: Diagnostics = Diagnostics(),
        // INFO is the useful default for a DNS tunnel: MTU acceptance,
        // resolver counters, and session transitions are otherwise invisible
        // while diagnosing a mobile connection.
        logLevel: LogLevel = .info,
        preservedUnsupportedSettings: [String: String] = [:]
    ) {
        self.listener = listener
        self.localDNS = localDNS
        self.resolver = resolver
        self.encoding = encoding
        self.mtu = mtu
        self.runtime = runtime
        self.session = session
        self.ping = ping
        self.arq = arq
        self.diagnostics = diagnostics
        self.logLevel = logLevel
        self.preservedUnsupportedSettings = preservedUnsupportedSettings
        normalize()
    }

    public static func preset(_ preset: MasterDnsConfigurationPreset) -> Self {
        switch preset {
        case .andronReliability, .custom:
            return Self()
        case .compatibility:
            return Self(
                listener: Listener(httpProxyEnabled: true, optimisticSocksConnect: true),
                resolver: ResolverTransport(
                    balancingStrategy: .lossThenLatency,
                    packetDuplicationCount: 2,
                    setupPacketDuplicationCount: 3,
                    baseEncodeData: true
                ),
                encoding: Encoding(uploadCompression: .off, downloadCompression: .off),
                mtu: MTU(
                    minUpload: 38,
                    minDownload: 100,
                    maxUpload: 120,
                    maxDownload: 1_024,
                    autoRemoveLowMTUResolvers: false,
                    testRetries: 3,
                    testTimeoutSeconds: 2.5,
                    testParallelism: 16
                ),
                runtime: Runtime(rxTxWorkers: 4, tunnelProcessWorkers: 4),
                logLevel: .info
            )
        case .performance:
            return Self(
                listener: Listener(httpProxyEnabled: true, optimisticSocksConnect: false),
                resolver: ResolverTransport(
                    balancingStrategy: .leastLoss,
                    packetDuplicationCount: 1,
                    setupPacketDuplicationCount: 1,
                    baseEncodeData: true
                ),
                encoding: Encoding(uploadCompression: .lz4, downloadCompression: .lz4),
                mtu: MTU(
                    minUpload: 80,
                    minDownload: 300,
                    maxUpload: 133,
                    maxDownload: 2_048,
                    autoRemoveLowMTUResolvers: true,
                    testRetries: 2,
                    testTimeoutSeconds: 2,
                    testParallelism: 32
                ),
                runtime: Runtime(rxTxWorkers: 8, tunnelProcessWorkers: 8),
                logLevel: .info
            )
        }
    }

    /// Applies a tuning preset while retaining local listener credentials and
    /// addresses, which are device-specific rather than transport tuning.
    public mutating func apply(_ preset: MasterDnsConfigurationPreset) {
        guard preset != .custom else { return }
        let localListener = listener
        let localDNSSettings = localDNS
        let unsupported = preservedUnsupportedSettings
        self = Self.preset(preset)
        listener.listenIP = localListener.listenIP
        listener.listenPort = localListener.listenPort
        listener.socksAuth = localListener.socksAuth
        listener.socksUser = localListener.socksUser
        listener.socksPass = localListener.socksPass
        listener.httpProxyPort = localListener.httpProxyPort
        localDNS = localDNSSettings
        preservedUnsupportedSettings = unsupported
        normalize()
    }

    public mutating func normalize() {
        listener.listenIP = listener.listenIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if listener.listenIP.isEmpty { listener.listenIP = "127.0.0.1" }
        listener.listenPort = Self.clamp(listener.listenPort, 1_024, 65_535)
        listener.httpProxyPort = Self.clamp(listener.httpProxyPort, 1_024, 65_535)
        listener.localHandshakeTimeoutSeconds = Self.clamp(listener.localHandshakeTimeoutSeconds, 1, 300)
        listener.socksUser = String(listener.socksUser.prefix(255))
        listener.socksPass = String(listener.socksPass.prefix(255))

        localDNS.listenIP = localDNS.listenIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if localDNS.listenIP.isEmpty { localDNS.listenIP = "127.0.0.1" }
        localDNS.port = Self.clamp(localDNS.port, 1, 65_535)
        localDNS.cacheMaxRecords = max(1, localDNS.cacheMaxRecords)
        localDNS.cacheTTLSeconds = max(0.1, localDNS.cacheTTLSeconds)
        localDNS.pendingTimeoutSeconds = max(0.1, localDNS.pendingTimeoutSeconds)
        localDNS.fragmentTimeoutSeconds = Self.clamp(localDNS.fragmentTimeoutSeconds, 1, 600)
        localDNS.cacheFlushIntervalSeconds = max(0.1, localDNS.cacheFlushIntervalSeconds)

        resolver.packetDuplicationCount = Self.clamp(resolver.packetDuplicationCount, 1, 10)
        resolver.setupPacketDuplicationCount = Self.clamp(
            resolver.setupPacketDuplicationCount,
            resolver.packetDuplicationCount,
            12
        )
        resolver.failoverResendThreshold = Self.clamp(resolver.failoverResendThreshold, 1, 256)
        resolver.failoverCooldownSeconds = Self.clamp(resolver.failoverCooldownSeconds, 0.1, 120)
        resolver.autoDisableTimeoutWindowSeconds = Self.clamp(resolver.autoDisableTimeoutWindowSeconds, 1, 86_400)

        encoding.compressionMinSize = max(100, encoding.compressionMinSize)

        mtu.minUpload = max(0, mtu.minUpload)
        mtu.minDownload = max(0, mtu.minDownload)
        mtu.maxUpload = max(mtu.minUpload, mtu.maxUpload)
        mtu.maxDownload = max(mtu.minDownload, mtu.maxDownload)
        mtu.testRetries = max(1, mtu.testRetries)
        mtu.testTimeoutSeconds = max(0.1, mtu.testTimeoutSeconds)
        mtu.testParallelism = Self.clamp(mtu.testParallelism, 1, 512)

        runtime.rxTxWorkers = Self.clamp(runtime.rxTxWorkers, 1, 128)
        runtime.tunnelProcessWorkers = Self.clamp(runtime.tunnelProcessWorkers, 1, 128)
        runtime.tunnelPacketTimeoutSeconds = Self.clamp(runtime.tunnelPacketTimeoutSeconds, 0.5, 120)
        runtime.dispatcherIdlePollIntervalSeconds = Self.clamp(runtime.dispatcherIdlePollIntervalSeconds, 0.001, 1)
        runtime.rxChannelSize = Self.clamp(runtime.rxChannelSize, 64, 65_536)
        runtime.socksUDPAssociateReadTimeoutSeconds = Self.clamp(runtime.socksUDPAssociateReadTimeoutSeconds, 1, 3_600)
        runtime.terminalStreamRetentionSeconds = Self.clamp(runtime.terminalStreamRetentionSeconds, 1, 3_600)
        runtime.cancelledSetupRetentionSeconds = Self.clamp(runtime.cancelledSetupRetentionSeconds, 1, 3_600)

        session.retryBaseSeconds = Self.clamp(session.retryBaseSeconds, 0.1, 60)
        session.retryStepSeconds = Self.clamp(session.retryStepSeconds, 0, 60)
        session.retryLinearAfter = Self.clamp(session.retryLinearAfter, 0, 1_000)
        session.retryMaxSeconds = Self.clamp(session.retryMaxSeconds, session.retryBaseSeconds, 3_600)
        session.busyRetryIntervalSeconds = Self.clamp(session.busyRetryIntervalSeconds, 1, 3_600)
        session.racingCount = Self.clamp(session.racingCount, 1, 5)

        ping.aggressiveIntervalSeconds = Self.clamp(ping.aggressiveIntervalSeconds, 0.01, 30)
        ping.lazyIntervalSeconds = Self.clamp(ping.lazyIntervalSeconds, ping.aggressiveIntervalSeconds, 60)
        ping.cooldownIntervalSeconds = Self.clamp(ping.cooldownIntervalSeconds, ping.lazyIntervalSeconds, 300)
        ping.coldIntervalSeconds = Self.clamp(ping.coldIntervalSeconds, ping.cooldownIntervalSeconds, 3_600)
        ping.warmThresholdSeconds = Self.clamp(ping.warmThresholdSeconds, 0.1, 600)
        ping.coolThresholdSeconds = Self.clamp(ping.coolThresholdSeconds, ping.warmThresholdSeconds, 1_800)
        ping.coldThresholdSeconds = Self.clamp(ping.coldThresholdSeconds, ping.coolThresholdSeconds, 3_600)

        arq.maxPacketsPerBatch = Self.clamp(arq.maxPacketsPerBatch, 1, 64)
        arq.windowSize = Self.clamp(arq.windowSize, 2, 8_000)
        arq.initialRTOSeconds = Self.clamp(arq.initialRTOSeconds, 0.01, 60)
        arq.maxRTOSeconds = Self.clamp(arq.maxRTOSeconds, arq.initialRTOSeconds, 120)
        arq.controlInitialRTOSeconds = Self.clamp(arq.controlInitialRTOSeconds, 0.01, 60)
        arq.controlMaxRTOSeconds = Self.clamp(arq.controlMaxRTOSeconds, arq.controlInitialRTOSeconds, 120)
        arq.maxControlRetries = Self.clamp(arq.maxControlRetries, 5, 5_000)
        arq.inactivityTimeoutSeconds = Self.clamp(arq.inactivityTimeoutSeconds, 10, 86_400)
        arq.dataPacketTTLSeconds = Self.clamp(arq.dataPacketTTLSeconds, 10, 86_400)
        arq.controlPacketTTLSeconds = Self.clamp(arq.controlPacketTTLSeconds, 10, 86_400)
        arq.maxDataRetries = Self.clamp(arq.maxDataRetries, 5, 100_000)
        arq.dataNackMaxGap = Self.clamp(arq.dataNackMaxGap, 0, min(128, arq.windowSize - 1))
        arq.dataNackInitialDelaySeconds = Self.clamp(arq.dataNackInitialDelaySeconds, 0.01, 60)
        arq.dataNackRepeatSeconds = Self.clamp(arq.dataNackRepeatSeconds, 0.01, 60)
        arq.terminalDrainTimeoutSeconds = Self.clamp(arq.terminalDrainTimeoutSeconds, 10, 3_600)
        arq.terminalAckWaitTimeoutSeconds = Self.clamp(arq.terminalAckWaitTimeoutSeconds, 5, 3_600)
    }

    private static func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
        min(max(value, lower), upper)
    }
}
