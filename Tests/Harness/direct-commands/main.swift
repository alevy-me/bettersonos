import Foundation
import BetterSonosCore
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { fails += 1 } }
let base = Int(CommandLine.arguments[1])!
let backend = DirectBackend(speakers: ["RINCON_K01400": "127.0.0.1:\(base)"])
func zone(_ room: String) async -> Zone? {
    try? await backend.zones().first { z in z.members.contains { $0.roomName == room } }
}
func member(_ room: String) async -> Member? {
    await zone(room)?.members.first { $0.roomName == room }
}

Task {
    // Transport, through the group's coordinator.
    check(await backend.play(coordinator: "Kitchen"), "play accepted")
    check(await zone("Kitchen")?.coordinator.state.playbackState == "PLAYING", "Kitchen playing")
    check(await backend.pause(coordinator: "Kitchen"), "pause accepted")
    check(await zone("Kitchen")?.coordinator.state.playbackState == "PAUSED_PLAYBACK", "Kitchen paused")
    check(await backend.play(coordinator: "Upstairs Bathroom"), "play on a group member goes to its coordinator")
    check(await zone("Bedroom")?.coordinator.state.playbackState == "PLAYING", "Bedroom group playing")

    // Room volume and mute, on the room's own speaker; the stereo pair through its visible half.
    check(await backend.setVolume(52, room: "Kitchen"), "set volume accepted")
    check(await member("Kitchen")?.state.volume == 52, "Kitchen volume 52")
    check(await backend.setVolume(150, room: "Kitchen"), "out-of-range volume is clamped, not refused")
    check(await member("Kitchen")?.state.volume == 100, "Kitchen volume clamped to 100")
    check(await backend.setMute(false, room: "TV Room"), "unmute the stereo pair")
    check(await member("TV Room")?.state.mute == false, "TV Room unmuted")
    check(await backend.setVolume(50, room: "Big Speakers") == false, "fixed-output speaker refuses volume, and the backend reports it")

    // Group volume and mute, on the coordinator.
    check(await backend.setGroupVolume(25, coordinator: "Bedroom"), "group volume accepted")
    check(await zone("Bedroom")?.coordinator.groupState?.volume == 25, "Bedroom group volume 25")
    check(await backend.setGroupMute(true, coordinator: "Bedroom"), "group mute accepted")
    check(await zone("Bedroom")?.coordinator.groupState?.mute == true, "Bedroom group muted")

    // Grouping.
    check(await backend.join(room: "Kitchen", to: "Upstairs Bathroom"), "Kitchen joins the group Upstairs Bathroom is in")
    let joined = await zone("Kitchen")
    check(joined?.coordinator.roomName == "Bedroom" && joined?.members.count == 3, "Kitchen now in Bedroom's group: \(joined?.members.map(\.roomName) ?? [])")
    check(await backend.leave(room: "Kitchen"), "Kitchen leaves")
    let alone = await zone("Kitchen")
    check(alone?.coordinator.roomName == "Kitchen" && alone?.members.count == 1, "Kitchen on its own again")

    // A stopped source that isn't radio (here a Spotify Connect session the speaker won't reload) must
    // still resume: the reload is only for radio, and Play is always sent.
    _ = try? await SonosSOAP.call("127.0.0.1:\(base)", SonosSOAP.avTransport, "Stop", [("InstanceID", "0")])
    check(await zone("Kitchen")?.coordinator.state.playbackState == "STOPPED", "Kitchen stopped on its Spotify session")
    check(await backend.play(coordinator: "Kitchen"), "play on a stopped non-radio source is accepted")
    check(await zone("Kitchen")?.coordinator.state.playbackState == "PLAYING", "and it plays, with no reload attempted")

    // Unknown rooms fail cleanly.
    check(await backend.setVolume(10, room: "Attic") == false, "an unknown room fails without throwing")
    print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
    exit(0)
}
RunLoop.main.run()
