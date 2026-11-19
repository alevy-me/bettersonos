import Foundation
import BetterSonosCore
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { fails += 1 } }
let base = Int(CommandLine.arguments[1])!
// Seeded the way discovery would seed it: one dead address and one live one.
let backend = DirectBackend(speakers: ["RINCON_DEAD01400": "127.0.0.1:9", "RINCON_K01400": "127.0.0.1:\(base)"])
Task {
    do {
        let topology = try await backend.topology()
        check(topology.groups.count == 6, "layout read past a dead address: \(topology.groups.count) groups")
        check(topology.addresses.count == 8, "every speaker's address learned, hidden ones included: \(topology.addresses.count)")
        let zones = try await backend.zones()
        let names = zones.map(\.coordinator.roomName)
        check(names == ["Bedroom", "Big Speakers", "Kitchen", "Patio", "TV Room"], "rooms, with the Bridge left out: \(names)")
        let tv = zones.first { $0.coordinator.roomName == "TV Room" }!
        check(tv.members.count == 1 && tv.coordinator.uuid == "RINCON_TVL01400", "stereo pair is one room, controlled through the visible speaker")
        check(tv.coordinator.state.mute && tv.coordinator.state.volume == 45, "TV Room volume 45, muted")
        check(NowPlaying(track: tv.coordinator.state.currentTrack)?.line == "Line In", "TV Room source: Line In")
        let kitchen = zones.first { $0.coordinator.roomName == "Kitchen" }!
        check(NowPlaying(track: kitchen.coordinator.state.currentTrack)?.line == "Spotify" && kitchen.coordinator.state.playbackState == "PAUSED_PLAYBACK", "Kitchen: Spotify, paused")
        let bedroom = zones.first { $0.coordinator.roomName == "Bedroom" }!
        check(bedroom.members.map(\.roomName).sorted() == ["Bedroom", "Upstairs Bathroom"], "Bedroom group has both rooms")
        check(NowPlaying(track: bedroom.coordinator.state.currentTrack)?.line == "Radio Woodstock 100.1" && bedroom.coordinator.state.playbackState == "PLAYING", "Bedroom: Radio Woodstock 100.1, playing")
        check(bedroom.coordinator.groupState?.volume == 40, "group volume from the coordinator: \(bedroom.coordinator.groupState?.volume ?? -1)")
        let bath = bedroom.members.first { $0.roomName == "Upstairs Bathroom" }!
        check(bath.state.volume == 0, "a room whose volume query fails still appears, with a default")
        let big = zones.first { $0.coordinator.roomName == "Big Speakers" }!
        check(big.coordinator.state.isOutputFixed == true && kitchen.coordinator.state.isOutputFixed == false, "fixed output read from the speaker: Big Speakers fixed, Kitchen not")
        let plain = NetworkConfig(id: UUID(), displayName: "T", baseURL: "", enabled: true, showDefaultPresetsForThisNetwork: false)
        check(plain.isVolumeDisabled(for: big.coordinator) && !plain.isVolumeDisabled(for: kitchen.coordinator), "fixed output grays out volume with no settings")
        // A speaker in the layout that answers nothing else: still reported, values marked unread.
        let patio = zones.first { $0.coordinator.roomName == "Patio" }!
        check(patio.coordinator.state.isPlaybackUnread == true && patio.coordinator.state.isLevelUnread == true, "a silent speaker stays in the layout, its values marked unread")
        check(plain.isVolumeDisabled(for: patio.coordinator), "a never-read volume is shown as unavailable, not 0")
        check(bath.state.isLevelUnread == true && bedroom.coordinator.state.isPlaybackUnread != true, "one silent room doesn't mark its group's playback unread")
        // Carrying forward: last real values replace unread ones; rooms still come from the new layout.
        let previous = [Zone(coordinator: Member(roomName: "Patio", uuid: "RINCON_PATIO01400",
                                                  state: PlayerState(volume: 27, mute: true, currentTrack: Track(stationName: "WWNO", uri: "x-sonosapi-stream:s3"), playbackState: "PLAYING"),
                                                  groupState: GroupState(volume: 27, mute: true)), members: [])]
        let carried = patio.carryingForward(from: previous).coordinator.state
        check(carried.volume == 27 && carried.mute && carried.playbackState == "PLAYING" && carried.isLevelUnread == false && carried.isPlaybackUnread == false, "unread values carry forward from the last reading")
        check(NowPlaying(track: carried.currentTrack)?.line == "WWNO", "including what it was playing")
        let favorites = try await backend.favoriteNames()
        check(favorites == ["WWNO", "FIP", "Radio Woodstock 100.1", "Dinner Jazz"], "favorites browsed: \(favorites)")
        let dead = DirectBackend(speakers: ["x": "127.0.0.1:9"])
        do { _ = try await dead.topology(); check(false, "no reachable speaker must throw") } catch { check(true, "no reachable speaker throws") }
    } catch { check(false, "unexpected error \(error)") }

    // Local network config: stable id, round trip, old configs still decode as server networks.
    let a = NetworkConfig.local(householdID: "Sonos_ABC", name: "Home", speakers: ["u": "h:1400"])
    let b = NetworkConfig.local(householdID: "Sonos_ABC", name: "Other", speakers: [:])
    check(a.id == b.id && a.id != NetworkConfig.local(householdID: "Sonos_XYZ", name: "Home", speakers: [:]).id, "household ID gives the same network id on every device")
    let round = try! JSONDecoder().decode(NetworkConfig.self, from: JSONEncoder().encode(a))
    check(round.isLocal && round.householdID == "Sonos_ABC" && round.speakerAddresses == ["u": "h:1400"] && round.backend is DirectBackend, "local config round-trips and uses the direct backend")
    let old = #"{"id":"2F1A6E1E-0000-4000-8000-000000000001","displayName":"Home","baseURL":"http://pi:5005","enabled":true}"#
    let legacy = try! JSONDecoder().decode(NetworkConfig.self, from: Data(old.utf8))
    check(!legacy.isLocal && legacy.backend is ServerBackend, "an existing server config still decodes as a server network")
    print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
    exit(0)
}
RunLoop.main.run()
