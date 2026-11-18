import Foundation
import BetterSonosCore
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { fails += 1 } }
let port = CommandLine.arguments[1]
@MainActor func run() async {
    let favs = ["Radio Woodstock 100.1", "WWNO"].map { Station(name: $0, url: $0, type: .favorite) }
    let cfg = NetworkConfig(id: UUID(), displayName: "Second", baseURL: "http://127.0.0.1:\(port)", enabled: true, showDefaultPresetsForThisNetwork: false, lastKnownServerFavorites: favs)
    let settings = AppSettingsStore(cloudReadOnly: true)
    settings.manualStations = []; settings.remoteCSVURL = nil
    let c = WatchNetworkController(config: cfg)
    await c.refresh()
    await c.loadPresets(settings: settings)
    check(c.room(named: "Den")?.nowPlaying == "Radio Woodstock 100.1", "radio shows only the station: \(c.room(named: "Den")?.nowPlaying ?? "nil")")
    check(c.playingPreset(forRoom: "Den")?.name == "Radio Woodstock 100.1", "Den matches the Woodstock favorite")

    c.togglePlayback(room: "Den")          // pause -> server reports STOPPED
    try? await Task.sleep(for: .seconds(3))
    check(c.room(named: "Den")?.isStopped == true && c.room(named: "Den")?.isPlaying == false, "pausing radio leaves it STOPPED")

    c.togglePlayback(room: "Den")          // play on a stopped stream must reload the favorite
    try? await Task.sleep(for: .seconds(3))
    check(c.room(named: "Den")?.isPlaying == true, "play restarts the stopped stream")

    c.togglePlayback(room: "Downstairs")   // stopped, no matching preset: plain play, no reload possible
    try? await Task.sleep(for: .seconds(3))
    check(c.room(named: "Downstairs")?.isPlaying == false, "unmatched stopped stream: play sent, stays stopped (nothing to reload)")
}
Task { await run(); print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(0) }
RunLoop.main.run()
