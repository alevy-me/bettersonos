// Throwaway test: can Apple Watch reach node-sonos-http-api directly?
//
// For each target base URL it sends GET /zones and records the network path the watch was on
// (Wi-Fi, or relayed through the iPhone), latency, HTTP status, room count, and the URLError code.
// An internet control request separates "no network at all" from "can't reach the LAN".
//
// Targets come from the iOS app's synced iCloud configs (if the key-value store syncs to the watch)
// plus the manual list below. Add a raw-IP version of your server so .local resolution is tested too.

import SwiftUI
import Network
import os.log

/// Edit before building. Include both the .local name and the raw IP of your server.
private let manualTargets: [String] = [
    "http://192.168.1.13:5005",
]

private let internetControlURL = URL(string: "https://www.apple.com/library/test/success.html")!
private let log = Logger(subsystem: "show.nola.BetterSonos.nettest", category: "NetTest")

@main
struct WatchNetTestApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - Model

struct Target: Hashable {
    let label: String
    let baseURL: String
}

struct ProbeResult: Identifiable {
    let id = UUID()
    let target: String
    let path: String
    let ok: Bool
    let summary: String
    let ms: Int
}

/// Minimal mirror of the iOS app's NetworkConfig; only the fields this test needs.
private struct SyncedConfig: Decodable {
    let displayName: String
    let baseURL: String
}

@MainActor
final class NetTest: ObservableObject {
    @Published var targets: [Target] = []
    @Published var results: [ProbeResult] = []
    @Published var pathDescription = "unknown"
    @Published var kvsStatus = "not checked"
    @Published var isRunning = false
    @Published var progress = "Not run yet"

    private let monitor = NWPathMonitor()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let description = Self.describe(path)
            Task { @MainActor in self?.pathDescription = description }
        }
        monitor.start(queue: .main)
        // The first iCloud sync for a newly installed app can arrive minutes after launch.
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] notification in
            let reason = (notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int) ?? -1
            Task { @MainActor in
                self?.loadTargets()
                self?.kvsStatus += " (sync event, reason \(reason))"
            }
        }
        loadTargets()
    }

    nonisolated private static func describe(_ path: NWPath) -> String {
        var parts: [String] = []
        switch path.status {
        case .satisfied: parts.append("up")
        case .unsatisfied: parts.append("down")
        case .requiresConnection: parts.append("needs connection")
        @unknown default: parts.append("?")
        }
        if path.usesInterfaceType(.wifi) { parts.append("Wi-Fi") }
        if path.usesInterfaceType(.cellular) { parts.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { parts.append("wired") }
        // Traffic relayed through the paired iPhone shows up as "other".
        if path.usesInterfaceType(.other) { parts.append("other (iPhone relay?)") }
        if path.isExpensive { parts.append("expensive") }
        if path.isConstrained { parts.append("constrained") }
        return parts.joined(separator: ", ")
    }

    func loadTargets() {
        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()
        var found: [Target] = []
        if let data = store.data(forKey: "sonosNetworkConfigs_iCloud") {
            if let configs = try? JSONDecoder().decode([SyncedConfig].self, from: data) {
                found = configs.map { Target(label: $0.displayName, baseURL: $0.baseURL) }
                kvsStatus = "iCloud: \(configs.count) config(s)"
            } else {
                kvsStatus = "iCloud: data present, decode failed"
            }
        } else {
            kvsStatus = "iCloud: no data (yet)"
        }
        for url in manualTargets where !found.contains(where: { $0.baseURL == url }) {
            found.append(Target(label: "manual", baseURL: url))
        }
        targets = found
    }

    func runAll() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let path = pathDescription
        let total = targets.count + 1
        progress = "Testing 1 of \(total): internet"
        results.insert(await probe(label: "internet", url: internetControlURL, path: path, expectZones: false), at: 0)
        for (index, target) in targets.enumerated() {
            progress = "Testing \(index + 2) of \(total): \(target.baseURL)"
            let base = target.baseURL.hasSuffix("/") ? String(target.baseURL.dropLast()) : target.baseURL
            guard let url = URL(string: base + "/zones") else {
                results.insert(ProbeResult(target: target.baseURL, path: path, ok: false, summary: "bad URL", ms: 0), at: 0)
                continue
            }
            results.insert(await probe(label: "\(target.label) \(target.baseURL)", url: url, path: path, expectZones: true), at: 0)
        }
        progress = "Done: \(results.prefix(total).filter(\.ok).count) of \(total) OK"
        appendToLog(Array(results.prefix(total)))
    }

    /// Appends a run to Documents/results.log so it can be pulled with `xcrun devicectl device copy from`.
    private func appendToLog(_ run: [ProbeResult]) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = docs.appendingPathComponent("results.log")
        var text = "=== \(ISO8601DateFormatter().string(from: Date())) | path: \(pathDescription) | \(kvsStatus)\n"
        for result in run.reversed() {
            text += "\(result.ok ? "OK  " : "FAIL") \(result.ms)ms | \(result.target) | \(result.summary) | \(result.path)\n"
        }
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    private func probe(label: String, url: URL, path: String, expectZones: Bool) async -> ProbeResult {
        let start = Date()
        do {
            let (data, response) = try await session.data(from: url)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            var summary = "HTTP \(status), \(data.count) B"
            var ok = (200...299).contains(status)
            if expectZones {
                if let zones = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    summary += ", \(zones.count) zone(s)"
                } else {
                    summary += ", not zones JSON"
                    ok = false
                }
            }
            log.info("\(label, privacy: .public) [\(path, privacy: .public)] \(summary, privacy: .public) in \(ms)ms")
            return ProbeResult(target: label, path: path, ok: ok, summary: summary, ms: ms)
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let summary: String
            if let urlError = error as? URLError {
                summary = "URLError \(urlError.code.rawValue): \(Self.name(for: urlError.code))"
            } else {
                summary = error.localizedDescription
            }
            log.error("\(label, privacy: .public) [\(path, privacy: .public)] \(summary, privacy: .public) in \(ms)ms")
            return ProbeResult(target: label, path: path, ok: false, summary: summary, ms: ms)
        }
    }

    private static func name(for code: URLError.Code) -> String {
        switch code {
        case .cannotFindHost: return "cannot find host (DNS/.local)"
        case .cannotConnectToHost: return "cannot connect"
        case .timedOut: return "timed out"
        case .notConnectedToInternet: return "not connected"
        case .networkConnectionLost: return "connection lost"
        case .appTransportSecurityRequiresSecureConnection: return "ATS blocked"
        case .secureConnectionFailed: return "TLS failed"
        default: return "other"
        }
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var test = NetTest()

    var body: some View {
        List {
            Section {
                Button {
                    Task { await test.runAll() }
                } label: {
                    Label(test.isRunning ? "Running..." : "Run tests", systemImage: "network")
                }
                .disabled(test.isRunning)
                Text(test.progress).font(.caption2).bold()
                Text(test.pathDescription).font(.caption2)
                Text(test.kvsStatus).font(.caption2)
            }
            Section("Results (newest first)") {
                ForEach(test.results) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(result.ok ? "OK" : "FAIL") \(result.ms) ms")
                            .font(.caption).bold()
                            .foregroundStyle(result.ok ? .green : .red)
                        Text(result.target).font(.caption2)
                        Text(result.summary).font(.caption2)
                        Text(result.path).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Targets") {
                ForEach(test.targets, id: \.self) { target in
                    Text("\(target.label): \(target.baseURL)").font(.caption2)
                }
                Button("Reload targets") { test.loadTargets() }
                    .font(.caption2)
            }
        }
    }
}
