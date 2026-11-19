import Foundation
import BetterSonosCore
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { fails += 1 } }
let base = Int(CommandLine.arguments[1])!
let backend = DirectBackend(speakers: ["RINCON_K01400": "127.0.0.1:\(base)"])
func coordinator(_ room: String) async -> Member? {
    try? await backend.zones().first { $0.coordinator.roomName == room }?.coordinator
}
func source(_ room: String) async -> String? {
    NowPlaying(track: await coordinator(room)?.state.currentTrack)?.line
}

Task {
    let favorites = (try? await backend.favorites()) ?? []
    check(favorites.count == 4 && favorites.allSatisfy { $0.metadata.contains("<DIDL-Lite") }, "favorites carry playable metadata")
    check(favorites.filter(\.isContainer).map(\.title) == ["Dinner Jazz"], "the playlist favorite is recognized as a container")

    // A Sonos favorite stream: loaded with its stored URI and metadata.
    check(await backend.loadPreset(Station(name: "WWNO", url: "WWNO", type: .favorite), coordinator: "Kitchen"), "favorite loads")
    check(await backend.play(coordinator: "Kitchen"), "and plays")
    let wwnoSource = await source("Kitchen"), wwnoState = await coordinator("Kitchen")?.state.playbackState
    check(wwnoSource == "WWNO" && wwnoState == "PLAYING", "Kitchen plays WWNO, named by the favorite")

    // The stopped-radio problem: pause stops a stream, and Play alone wouldn't restart it.
    check(await backend.pause(coordinator: "Kitchen"), "pause")
    check((await coordinator("Kitchen"))?.state.playbackState == "STOPPED", "pausing radio leaves it STOPPED")
    check(await backend.play(coordinator: "Kitchen"), "play")
    check((await coordinator("Kitchen"))?.state.playbackState == "PLAYING", "play restarts the stopped stream (reloaded first)")

    // Any stopped station restarts, even one that's not a preset.
    check((await coordinator("Big Speakers"))?.state.playbackState == "STOPPED", "Big Speakers starts stopped on a non-preset station")
    check(await backend.play(coordinator: "Big Speakers"), "play")
    let bigState = await coordinator("Big Speakers")?.state.playbackState, bigSource = await source("Big Speakers")
    check(bigState == "PLAYING" && bigSource == "Classic American Top 40", "a stopped non-preset station restarts, same station")

    // A CSV or manual stream: x-rincon-mp3radio with metadata naming the preset.
    let groove = Station(name: "Groove Salad", url: "https://ice1.somafm.com/groovesalad-128-mp3", type: .stream)
    check(await backend.loadPreset(groove, coordinator: "Kitchen"), "stream preset loads")
    let track = (await coordinator("Kitchen"))?.state.currentTrack
    check(track?.uri == "x-rincon-mp3radio://https://ice1.somafm.com/groovesalad-128-mp3", "stream URI: \(track?.uri ?? "nil")")
    check(await source("Kitchen") == "Groove Salad", "the speaker names it by the preset: \(await source("Kitchen") ?? "nil")")
    check(track.map { bestMatchingStation(in: [groove], for: $0) } == groove, "and it matches its preset, for highlighting")

    // A line-in.
    let lineIn = Station(name: "Turntable", url: "x-rincon-stream:RINCON_TVL01400", type: .lineIn)
    check(await backend.loadPreset(lineIn, coordinator: "Kitchen"), "line-in loads")
    check((await coordinator("Kitchen"))?.state.currentTrack?.uri == "x-rincon-stream:RINCON_TVL01400", "Kitchen set to the TV Room line-in")

    // A playlist favorite replaces the queue and plays from it.
    check(await backend.loadPreset(Station(name: "Dinner Jazz", url: "Dinner Jazz", type: .favorite), coordinator: "Kitchen"), "playlist favorite loads")
    check((await coordinator("Kitchen"))?.state.currentTrack?.uri == "x-rincon-queue:RINCON_K01400#0", "Kitchen plays from its queue")

    // Through a group member: presets go to the coordinator.
    check(await backend.loadPreset(Station(name: "FIP", url: "FIP", type: .favorite), coordinator: "Upstairs Bathroom"), "preset on a group member")
    check(await source("Bedroom") == "FIP", "lands on the group's coordinator, Bedroom")

    check(await backend.loadPreset(Station(name: "Nope", url: "Nope", type: .favorite), coordinator: "Kitchen") == false, "an unknown favorite fails cleanly")
    print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
    exit(0)
}
RunLoop.main.run()
