import Foundation
import BetterSonosCore
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { fails += 1 } }
let port = CommandLine.arguments[1]
let base = "http://127.0.0.1:\(port)"
@MainActor func run() async {
    let id = UUID()
    UserDefaults.standard.removeObject(forKey: "watchPresets_\(id.uuidString)")
    let favorites = ["This Is AC/DC", "Hidden Fav"].map { Station(name: $0, url: $0, type: .favorite) }
    var cfg = NetworkConfig(id: id, displayName: "T", baseURL: base, enabled: true, showDefaultPresetsForThisNetwork: false,
                            explicitlyDisabledFavoriteURLs: ["Hidden Fav"], lastKnownServerFavorites: favorites)
    let settings = AppSettingsStore(cloudReadOnly: true)
    settings.manualStations = [Station(name: "WWOZ", url: "https://wwoz-sc.streamguys1.com/wwoz-hi.mp3", type: .stream)]
    settings.remoteCSVURL = "\(base)/stations.csv"

    let c = WatchNetworkController(config: cfg)
    await c.refresh()
    await c.loadPresets(settings: settings)
    check(c.presets.map(\.name) == ["Groove Salad", "Jazz, Live", "This Is AC/DC", "WWOZ"], "presets: \(c.presets.map(\.name))")

    let cached = WatchNetworkController(config: cfg)
    check(cached.presets == c.presets, "a new controller shows cached presets before loading")

    let groove = c.presets[0]
    c.playPreset(groove, inRoom: "Dining")
    try? await Task.sleep(for: .seconds(1))
    check(c.room(named: "Kitchen")?.isPlaying == true, "group playing after preset")
    check(c.playingPreset(forRoom: "Dining") == groove, "Groove Salad highlighted for Dining")

    let acdc = c.presets.first { $0.isFavorite }!
    c.playPreset(acdc, inRoom: "Kitchen")
    try? await Task.sleep(for: .seconds(1))
    check(c.playingPreset(forRoom: "Kitchen") == acdc, "favorite with a slash plays and is highlighted")

    // A failed rebuild keeps the good cached list.
    settings.manualStations = []
    settings.remoteCSVURL = "\(base)/missing.csv"
    cfg.lastKnownServerFavorites = []
    c.update(config: cfg)
    await c.loadPresets(settings: settings)
    check(c.presets.count == 4 && c.presetsError == "Couldn't refresh presets.", "failed rebuild keeps list: \(c.presets.count), \(c.presetsError ?? "nil")")
}
Task { await run(); print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(0) }
RunLoop.main.run()
