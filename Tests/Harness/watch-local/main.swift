import Foundation
import BetterSonosCore
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { fails += 1 } }
let base = CommandLine.arguments[1]

@MainActor func run() async {
    var cfg = NetworkConfig.local(householdID: "Sonos_TEST", name: "Home", speakers: ["RINCON_K01400": "127.0.0.1:\(base)"])
    cfg.showDefaultPresetsForThisNetwork = false
    cfg.lastKnownServerFavorites = ["WWNO", "FIP"].map { Station(name: $0, url: $0, type: .favorite) }
    let c = WatchNetworkController(config: cfg)
    await c.refresh()
    check(c.rooms.map(\.name) == ["Bedroom", "Big Speakers", "Kitchen", "Patio", "TV Room", "Upstairs Bathroom"], "watch lists every room from the speakers: \(c.rooms.map(\.name))")
    check(c.config.speakerAddresses.count == 8, "the watch learns every address from the layout: \(c.config.speakerAddresses.count)")
    check(c.room(named: "Patio")?.isVolumeDisabled == true && c.loadState == .loaded, "a silent speaker is listed with volume unavailable; the network stays loaded")
    check(c.room(named: "Big Speakers")?.isVolumeDisabled == true && c.room(named: "Kitchen")?.isVolumeDisabled == false, "fixed-output speaker grayed out on the watch")
    check(c.room(named: "Upstairs Bathroom")?.coordinator == "Bedroom", "grouping from the speakers")

    c.setVolume(41, for: .room("Kitchen"))
    try? await Task.sleep(for: .seconds(1.2))
    check(c.room(named: "Kitchen")?.volume == 41, "Crown volume reaches the speaker: \(c.room(named: "Kitchen")?.volume ?? -1)")

    let settings = AppSettingsStore(cloudReadOnly: true)
    settings.manualStations = []; settings.remoteCSVURL = nil
    await c.loadPresets(settings: settings)
    check(c.presets.map(\.name) == ["FIP", "WWNO"], "watch presets for a local network: \(c.presets.map(\.name))")
    c.playPreset(c.presets.first { $0.name == "WWNO" }!, inRoom: "Kitchen")
    try? await Task.sleep(for: .seconds(1.5))
    check(c.room(named: "Kitchen")?.nowPlaying == "WWNO" && c.room(named: "Kitchen")?.isPlaying == true, "preset plays from the watch: \(c.room(named: "Kitchen")?.nowPlaying ?? "nil")")

    c.togglePlayback(room: "Kitchen")   // pause: radio stops
    try? await Task.sleep(for: .seconds(3))
    check(c.room(named: "Kitchen")?.isStopped == true, "pausing radio from the watch stops it")
    c.togglePlayback(room: "Kitchen")   // play: must restart
    try? await Task.sleep(for: .seconds(3))
    check(c.room(named: "Kitchen")?.isPlaying == true, "play from the watch restarts the stopped stream")

    // Transitions. Only scheduled polls count toward Offline; two failed in a row confirm it.
    let live = c.config
    // The speakers "move": every known speaker is now reported at an address that doesn't answer.
    var gone = live
    gone.speakerAddresses = live.speakerAddresses.mapValues { _ in "127.0.0.1:9" }
    c.update(config: gone)
    for _ in 0..<10 { await c.refresh(kind: .action) }
    check(c.loadState == .loaded && c.rooms.count == 6, "ten failed refreshes after actions change nothing: \(c.loadState)")
    await c.refresh(kind: .scheduled)
    check(c.loadState == .loaded && c.rooms.count == 6, "one failed scheduled poll keeps the last layout: \(c.loadState), \(c.rooms.count) rooms")
    // An accepted command is contact: the count starts over.
    c.update(config: live)
    c.setVolume(42, for: .room("Kitchen"))
    try? await Task.sleep(for: .seconds(1.2))
    c.update(config: gone)
    await c.refresh(kind: .scheduled)
    check(c.loadState == .loaded, "a poll failing after an accepted command is the first again, not the second")
    await c.refresh(kind: .scheduled)
    check(c.loadState == .offline && c.rooms.isEmpty, "two failed scheduled polls in a row confirm Offline, with no stale rooms")
    c.update(config: live)
    await c.refresh(kind: .scheduled)
    check(c.loadState == .loaded && c.rooms.count == 6 && c.room(named: "Kitchen")?.volume == 42, "back on the network, rooms and their real state return")

    // A cancelled poll (polling paused mid-request) is neither a success nor a failure: after it,
    // one real failure is still only the first.
    let hangPort = CommandLine.arguments[2]
    var hanging = live
    hanging.speakerAddresses = ["h": "127.0.0.1:\(hangPort)"]
    c.update(config: hanging)
    let inFlight = Task { await c.refresh(kind: .scheduled) }
    try? await Task.sleep(for: .milliseconds(300))
    inFlight.cancel()
    await inFlight.value
    c.update(config: gone)
    await c.refresh(kind: .scheduled)
    check(c.loadState == .loaded, "a cancelled poll doesn't count: one real failure after it keeps the rooms")
    c.update(config: live)
    await c.refresh(kind: .scheduled)

    // Learned addresses survive a sync from the phone that didn't change them; a real phone-side change wins.
    let learned = c.config.speakerAddresses
    var resynced = live
    resynced.displayName = "Home renamed"   // some other edit synced from the phone
    c.update(config: resynced)
    check(c.config.speakerAddresses == learned && c.config.displayName == "Home renamed", "a sync that didn't touch addresses keeps the learned ones")
    var moved = resynced
    moved.speakerAddresses = ["RINCON_K01400": "127.0.0.1:\(base)", "RINCON_NEW01400": "127.0.0.1:1"]
    c.update(config: moved)
    check(c.config.speakerAddresses["RINCON_NEW01400"] == "127.0.0.1:1" && c.config.speakerAddresses.count == learned.count + 1, "a phone-side change wins, and learned addresses fill the gaps")
    c.update(config: live)

    // Away from home from the start: nothing ever read. Two failed polls (retried quickly) mean Offline.
    let away = WatchNetworkController(config: NetworkConfig.local(householdID: "Sonos_AWAY", name: "Home", speakers: ["x": "127.0.0.1:9"]))
    await away.refresh(kind: .scheduled)
    check(away.loadState == .loading, "one failed poll at launch still shows loading")
    await away.refresh(kind: .scheduled)
    check(away.loadState == .offline && away.rooms.isEmpty, "two failed polls at launch: Offline")
    away.start()
    let launched = Date()
    let quick = WatchNetworkController(config: NetworkConfig.local(householdID: "Sonos_AWAY2", name: "Home", speakers: ["x": "127.0.0.1:9"]))
    quick.start()
    while quick.loadState != .offline && Date().timeIntervalSince(launched) < 20 { try? await Task.sleep(for: .milliseconds(200)) }
    quick.stop(); away.stop()
    check(quick.loadState == .offline && Date().timeIntervalSince(launched) < 10, "polling alone reaches Offline quickly at launch: \(String(format: "%.1f", Date().timeIntervalSince(launched)))s")

    // Once Offline, polling backs off to the normal 15 s pace instead of the 3 s first-load retry.
    let refusePort = CommandLine.arguments[3], refuseLog = CommandLine.arguments[4]
    let backoff = WatchNetworkController(config: NetworkConfig.local(householdID: "Sonos_REFUSE", name: "Home", speakers: ["r": "127.0.0.1:\(refusePort)"]))
    backoff.start()
    try? await Task.sleep(for: .seconds(12))
    backoff.stop()
    let requests = (try? String(contentsOfFile: refuseLog, encoding: .utf8))?.split(separator: "\n").count ?? -1
    check(backoff.loadState == .offline && requests == 2, "in 12 s: two polls to reach Offline, then none until the 15 s poll (\(requests) requests)")
}
Task { await run(); print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(0) }
RunLoop.main.run()
