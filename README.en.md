<div align="right">

[🇷🇺 Русский](README.md) · **🇬🇧 English**

</div>

# Zanoza

iOS client for [MasterDnsVPN](https://github.com/masterking32/MasterDnsVPN) — a DNS-tunneling VPN for extreme-censorship networks.

It wraps the upstream MasterDnsVPN Go client into an iOS app, exposes its local SOCKS5 proxy at `127.0.0.1:41080`, and keeps the tunnel running while you switch to another app (Happ, Hiddify, Streisand, Shadowrocket, etc.) that consumes the proxy.
The app does **not** create an iOS VPN profile, since it is unsigned.

This branch adds the Andron Industries reliability preset, full typed MasterDNS settings, profile/config import and export, hierarchical resolver presets, native encrypted resolver evaluation, bounded per-resolver throughput tests, and an explicit proxy-only speed test that cannot fall back to cellular data.

## Repository layout

```
Zanoza/
├── apple/                            # Xcode / SwiftPM project
│   ├── Package.swift                 # ZanozaKit shared library
│   ├── project.yml                   # XcodeGen project definition
│   ├── Frameworks/                   # Mobile.xcframework lands here
│   ├── Scripts/
│   │   ├── build-xcframework.sh         # gomobile bind → Mobile.xcframework
│   │   ├── build-ios-unsigned-local-ipa.sh
│   │   ├── prepare-xcode.sh             # xcodegen wrapper
│   │   └── generate-icon.py             # AppIcon generator (Pillow)
│   ├── Sources/
│   │   ├── ZanozaApp/            # iOS app target
│   │   │   ├── Assets.xcassets/AppIcon.appiconset/
│   │   │   ├── Info.plist            # UIBackgroundModes=[audio]
│   │   │   └── ZanozaApp.swift
│   │   └── ZanozaKit/            # Shared SwiftPM library
│   │       ├── Models/               # ConnectionProfile, ClientStatus
│   │       ├── Services/             # MasterDnsEngine, BackgroundRuntimeKeeper, …
│   │       ├── ViewModels/           # ClientViewModel
│   │       ├── Views/                # ContentView, ImportProfileSheet, …
│   │       └── Resources/{en,ru}.lproj/Localizable.strings
│   └── Tests/ZanozaKitTests/
└── masterdns/                        # Vendored MasterDnsVPN fork
    ├── go.mod                        # adds golang.org/x/mobile dep
    └── mobile/                       # gomobile-bindable wrapper package
        ├── mobile.go                 #   Start/Stop/IsRunning/SetLogWriter
        └── stdout_pump.go            #   forwards stdout → LogWriter
```

## Prerequisites

- macOS 14 + Xcode 16 (the iOS toolchain ships with Xcode)
- [Homebrew](https://brew.sh)
- `brew install go xcodegen`
- `go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init`
- Python 3 with Pillow (`python3 -m pip install --user pillow`) — only needed if you want to regenerate the AppIcon

## Build

```bash
# 1. Build the Go xcframework
apple/Scripts/build-xcframework.sh

# 2. Generate the Xcode project
apple/Scripts/prepare-xcode.sh

# 3. Build an unsigned IPA
apple/Scripts/build-ios-unsigned-local-ipa.sh
#   → apple/.build/ios-unsigned-local/Zanoza-unsigned.ipa
```

The IPA is unsigned. Sign and install it on a device using:

- **[Sideloadly](https://sideloadly.io)** — drop the IPA in, sign with your Apple ID, install via USB.
- **AltStore / SideStore** — install on-device, no Mac needed for re-signing after the first push.

Enable **Settings → Privacy & Security → Developer Mode** on the iPhone before the first install.

## Usage

1. Launch Zanoza and tap **Import**.
2. Enter the delegated domain from your MasterDnsVPN server (the same value as the NS record, e.g. `v.example.com`).
3. Enter the shared encryption key (must match the server-side key).
4. Tap **Import**, then the connect (power) button. **Encryption Type** and compression must match the server. The Andron preset uses AES-256-GCM (`DATA_ENCRYPTION_METHOD = 5`), compression off, and a 40–133 / 200–2048 MTU envelope.
5. Wait until Zanoza says **Ready**. This now means resolver MTU discovery, session setup, and the local listener have actually completed.
6. The SOCKS5 proxy comes up at `127.0.0.1:41080`. Open the consumer VPN app and add a SOCKS5 proxy pointing at that address.
7. Zanoza keeps the listener alive while you switch to other apps. Killing Zanoza from the app switcher stops the tunnel.

For URI-based imports, prefer this no-auth form (do not add an empty `:@` user-info component):

```text
socks://127.0.0.1:41080#Andron%20Industries
```

The embedded proxy nevertheless accepts the user/password-only SOCKS greeting produced by clients that parse `socks://:@...`. The optional optimistic acknowledgement remains payload-safe: Zanoza replies locally before the remote CONNECT result, but does not read or transmit application bytes until the MasterDNS server confirms the stream. A manual HTTP CONNECT fallback is available at `127.0.0.1:41081`.

## Resolver manager and tests

- Import parent pools from the clipboard, plain text, CSV-like files, JSON, IPv4/IPv6 addresses, or bounded IPv4 CIDRs.
- Create evaluated child presets and Top 5/10/20/50/100 lists by balanced, latency, reliability, or measured-throughput rank.
- Direct DNS reachability is only a prefilter. The native stage sends real encrypted MasterDNS MTU probes using the profile domain/key.
- The optional throughput stage is deliberately bounded to the top 1–20 candidates. It launches a separate one-resolver MasterDNS session and runs the explicit SOCKS test for each candidate.
- `194.226.0.0/16` is excluded from active scanning. CIDRs larger than 4,096 addresses are rejected, and Zanoza never discovers or scans arbitrary address ranges on its own.
- The standalone speed test first verifies a remote egress IP and then downloads/uploads through a raw SOCKS5 connection. It never uses `URLSession`, so a direct Wi-Fi/cellular result cannot be mistaken for tunnel throughput.

Streisand compatibility still depends on the particular Streisand build accepting a loopback upstream proxy. Use SOCKS without credentials first; if that build rejects it, manually try the HTTP CONNECT listener. Zanoza cannot alter a third-party Network Extension's routing policy from outside its sandbox.

## Credits

- Upstream protocol and Go client: [MasterDnsVPN by MasterkinG32](https://github.com/masterking32/MasterDnsVPN)
- iOS application shell follows the structure of [Godwit](https://github.com/plumbicon/godwit) (MIT)
