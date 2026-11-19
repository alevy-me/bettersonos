import Foundation
import BetterSonosCore
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { fails += 1 } }
// The fake household (speaker.py) answers directly; the fake server (grouped.py) is a different set of
// rooms, so which one answered is visible from the room names.
let speakerPort = CommandLine.arguments[1], serverPort = CommandLine.arguments[2]
let live = DirectBackend(speakers: ["RINCON_K01400": "127.0.0.1:\(speakerPort)"])
let dead = DirectBackend(speakers: ["RINCON_K01400": "127.0.0.1:9"])
let server = ServerBackend(baseURL: "http://127.0.0.1:\(serverPort)")
let deadServer = ServerBackend(baseURL: "http://127.0.0.1:9")
let id = UUID()
let cache = HybridPathCache()
cache.directRecheckInterval = 0.5
func names(_ zones: [Zone]) -> [String] { zones.map(\.coordinator.roomName).sorted() }

Task {
    // Both answer: the speakers win.
    let home = HybridBackend(networkID: id, direct: live, server: server, cache: cache)
    let atHome = try! await home.snapshot()
    check(home.currentPath == .direct && names(atHome.zones).contains("Patio") && atHome.addresses?.isEmpty == false, "both answer: direct, with addresses to save")
    check(await home.setVolume(44, room: "Kitchen"), "a command goes to the speakers")
    check((try? await live.zones())?.first { $0.coordinator.roomName == "Kitchen" }?.coordinator.state.volume == 44, "and the speakers have it")

    // Leaving home mid-session: the direct read fails and the same read falls back to the server.
    let leaving = HybridBackend(networkID: id, direct: dead, server: server, cache: cache)
    let away = try! await leaving.snapshot()
    check(leaving.currentPath == .server && names(away.zones) == ["Kitchen"] && away.addresses == nil, "the speakers stop answering: the same read falls back to the server")
    check(await leaving.pause(coordinator: "Kitchen"), "a command now goes to the server")

    // On the server, a later read doesn't retry the speakers until the re-check interval passes.
    _ = try! await leaving.snapshot()
    check(cache.path(for: id) == .server, "within the re-check interval it stays on the server")

    // Coming home: once the interval passes, the speakers are asked again and win.
    try? await Task.sleep(for: .seconds(0.7))
    let back = HybridBackend(networkID: id, direct: live, server: server, cache: cache)
    _ = try! await back.snapshot()
    check(back.currentPath == .direct, "after the re-check interval, the speakers answer again: back to direct")

    // Neither answers: reported as silence, with both reasons, so missed-poll counting applies.
    let lost = HybridBackend(networkID: UUID(), direct: dead, server: deadServer, cache: cache)
    do { _ = try await lost.snapshot(); check(false, "both down must fail") }
    catch DirectBackend.DirectError.noSpeakerAnswered(let reasons) {
        check(reasons.contains { $0.hasPrefix("server:") } && reasons.count >= 2, "both down: no speaker answered, with the server's reason too: \(reasons)")
    } catch { check(false, "wrong error \(error)") }

    // Away from the start: the server answers and is chosen without waiting out the speakers' timeout.
    let fresh = HybridBackend(networkID: UUID(), direct: dead, server: server, cache: cache)
    let started = Date()
    _ = try! await fresh.snapshot()
    check(fresh.currentPath == .server && Date().timeIntervalSince(started) < 3, "away: the server is chosen promptly (\(String(format: "%.1f", Date().timeIntervalSince(started)))s)")

    // A server network with its household, switched to direct control, gets a hybrid backend; switched off, a server one.
    var config = NetworkConfig(id: id, displayName: "Home", baseURL: "http://127.0.0.1:\(serverPort)", enabled: true, showDefaultPresetsForThisNetwork: false)
    config.householdID = "Sonos_TEST"; config.speakerAddresses = ["RINCON_K01400": "127.0.0.1:\(speakerPort)"]
    check(config.isHybrid && config.backend is HybridBackend && config.usesDirectControl, "server + household: hybrid")
    config.directControlEnabled = false
    check(!config.isHybrid && config.backend is ServerBackend && !config.usesDirectControl, "direct control switched off: server only")
    check(NetworkConfig.serverMatches(serverPlayers: ["A", "B"], householdPlayers: ["A", "B", "C"]), "containment: every server speaker in the household matches")
    check(!NetworkConfig.serverMatches(serverPlayers: ["A", "D"], householdPlayers: ["A", "B", "C"]) && !NetworkConfig.serverMatches(serverPlayers: [], householdPlayers: ["A"]), "a stray speaker, or no speakers, doesn't")
    print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
    exit(0)
}
RunLoop.main.run()
