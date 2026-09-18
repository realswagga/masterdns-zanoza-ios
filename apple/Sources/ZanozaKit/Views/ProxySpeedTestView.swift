import SwiftUI

public struct ProxySpeedTestView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: ConnectionProfile
    let tunnelReady: Bool

    @State private var stage: ProxySpeedTestStage?
    @State private var result: ProxySpeedTestResult?
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var egressURL = "http://checkip.amazonaws.com/"
    @State private var downloadURL = "http://speedtest.tele2.net/1MB.zip"
    @State private var uploadURL = "http://httpbin.org/post"
    @State private var uploadKilobytes = 128

    private let tester = ProxySpeedTestService()

    public init(profile: ConnectionProfile, tunnelReady: Bool) {
        self.profile = profile
        self.tunnelReady = tunnelReady
    }

    public var body: some View {
        Form {
            Section {
                Label("This test opens an explicit SOCKS5 connection to Zanoza. It cannot silently fall back to cellular or Wi-Fi.", systemImage: "checkmark.shield")
                    .font(.callout)
                LabeledContent("Proxy", value: proxyDisplay)
                LabeledContent("Tunnel state", value: tunnelReady ? "Ready" : "Not ready")
                    .foregroundStyle(tunnelReady ? .green : .orange)
            } header: {
                Text("Verified path")
            }

            if let stage {
                Section("Progress") {
                    ProgressView()
                    Text(stageTitle(stage)).foregroundStyle(.secondary)
                }
            }

            if let result {
                Section("Result") {
                    LabeledContent("Proxy egress IP", value: result.egressIP)
                    LabeledContent("SOCKS / remote handshake", value: formatMS(result.proxyHandshakeMS))
                    LabeledContent("Download", value: formatMbps(result.downloadMbps))
                    LabeledContent("Upload", value: formatMbps(result.uploadMbps))
                    LabeledContent("Downloaded", value: ByteCountFormatter.string(fromByteCount: Int64(result.downloadedBytes), countStyle: .file))
                    LabeledContent("Uploaded", value: ByteCountFormatter.string(fromByteCount: Int64(result.uploadedBytes), countStyle: .file))
                }
            }

            Section("Endpoints") {
                TextField("Egress URL", text: $egressURL).zanozaPlainInput()
                TextField("Download URL", text: $downloadURL).zanozaPlainInput()
                TextField("Upload URL", text: $uploadURL).zanozaPlainInput()
                Stepper("Upload payload: \(uploadKilobytes) KiB", value: $uploadKilobytes, in: 16...2_048, step: 16)
            }

            Section {
                if task == nil {
                    Button("Run proxy-verified test", action: start)
                        .disabled(!tunnelReady || parsedURLs == nil)
                } else {
                    Button("Cancel", role: .destructive, action: cancel)
                }
            } footer: {
                Text("Plain HTTP is intentional here: the raw SOCKS implementation measures the tunnel directly and verifies the returned egress IP. Do not enter credentials or private URLs.")
            }
        }
        .navigationTitle("Tunnel speed test")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .alert("Speed test failed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        .onDisappear(perform: cancel)
    }

    private var proxyDisplay: String {
        let listener = profile.configuration.listener
        let host = listener.listenIP == "0.0.0.0" || listener.listenIP == "::" ? "127.0.0.1" : listener.listenIP
        return "\(host):\(listener.listenPort)"
    }

    private var parsedURLs: (URL, URL, URL)? {
        guard let egress = URL(string: egressURL), egress.scheme == "http",
              let download = URL(string: downloadURL), download.scheme == "http",
              let upload = URL(string: uploadURL), upload.scheme == "http" else { return nil }
        return (egress, download, upload)
    }

    private func start() {
        guard let urls = parsedURLs else { return }
        let listener = profile.configuration.listener
        let host = listener.listenIP == "0.0.0.0" || listener.listenIP == "::" ? "127.0.0.1" : listener.listenIP
        let options = ProxySpeedTestOptions(
            proxyHost: host,
            proxyPort: listener.listenPort,
            username: listener.socksAuth ? listener.socksUser : nil,
            password: listener.socksAuth ? listener.socksPass : nil,
            egressURL: urls.0,
            downloadURL: urls.1,
            uploadURL: urls.2,
            uploadBytes: uploadKilobytes * 1_024
        )
        result = nil
        errorMessage = nil
        task = Task {
            do {
                let value = try await tester.run(options: options) { next in
                    Task { @MainActor in stage = next }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { result = value; stage = nil; task = nil }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { errorMessage = error.localizedDescription; stage = nil; task = nil }
            }
        }
    }

    private func cancel() {
        task?.cancel()
        tester.cancel()
        task = nil
        stage = nil
    }

    private func stageTitle(_ value: ProxySpeedTestStage) -> String {
        switch value {
        case .proxyHandshake: "Connecting only to the local SOCKS listener…"
        case .egressVerification: "Verifying remote egress through MasterDNS…"
        case .download: "Downloading through the DNS tunnel…"
        case .upload: "Uploading and waiting for the remote response…"
        }
    }

    private func formatMS(_ value: Double) -> String { String(format: "%.0f ms", value) }
    private func formatMbps(_ value: Double) -> String { String(format: "%.2f Mbit/s", value) }
}
