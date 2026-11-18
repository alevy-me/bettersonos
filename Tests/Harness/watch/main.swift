import Foundation
import BetterSonosCore
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { fails += 1 } }
let port = CommandLine.arguments[1]
@MainActor func run() async {
    var c: WatchNetworkController? = WatchNetworkController(config: NetworkConfig(id: UUID(), displayName: "T", baseURL: "http://127.0.0.1:\(port)/", enabled: true, showDefaultPresetsForThisNetwork: false))
    weak var weakC = c
    let ctl = c!
    await ctl.refresh()
    check(ctl.rooms.map(\.name) == ["Dining", "Kitchen"], "rooms: \(ctl.rooms.map(\.name))")
    let dining = ctl.room(named: "Dining")!
    check(dining.coordinator == "Kitchen" && dining.isGrouped && dining.otherMembers == ["Kitchen"], "Dining grouped under Kitchen")
    check(dining.nowPlaying == "Spotify", "now playing shows only the source: \(dining.nowPlaying ?? "nil")")

    // Crown burst: ten detents 20 ms apart.
    for v in 21...30 { ctl.setVolume(v, for: .room("Dining")); try? await Task.sleep(for: .milliseconds(20)) }
    check(ctl.room(named: "Dining")!.volume == 30, "volume shown immediately")
    try? await Task.sleep(for: .milliseconds(450))
    // The volume request is in flight (server takes 1 s); a poll now returns the old value.
    await ctl.refresh()
    check(ctl.room(named: "Dining")!.volume == 30, "stale poll does not snap volume back")
    try? await Task.sleep(for: .seconds(1.5))
    check(ctl.room(named: "Dining")!.volume == 30, "server confirms 30")

    ctl.setVolume(50, for: .group(coordinator: "Kitchen"))
    try? await Task.sleep(for: .seconds(0.8))
    check(ctl.room(named: "Dining")!.groupVolume == 50, "group volume 50")
    ctl.toggleMute(.group(coordinator: "Kitchen"))
    ctl.toggleMute(.room("Dining"))
    try? await Task.sleep(for: .seconds(0.5))
    check(ctl.room(named: "Dining")!.isGroupMuted && ctl.room(named: "Dining")!.isMuted && !ctl.room(named: "Kitchen")!.isMuted, "group mute and room mute")
    ctl.togglePlayback(room: "Dining")
    check(ctl.room(named: "Kitchen")!.isPlaying == false, "pause shown immediately for whole group")
    try? await Task.sleep(for: .seconds(3))
    check(ctl.room(named: "Kitchen")!.isPlaying == false, "pause confirmed")

    // Fixed volume: disable Dining via config, as Disable Volume Control would.
    var cfg = ctl.config; cfg.manuallyDisabledVolumeUUIDs = ["RINCON_Dining"]; ctl.update(config: cfg)
    check(ctl.room(named: "Dining")!.isVolumeDisabled && !ctl.room(named: "Kitchen")!.isVolumeDisabled, "Dining volume disabled, Kitchen not")
    check(!ctl.room(named: "Dining")!.isGroupVolumeDisabled, "group volume stays enabled while one member is adjustable")
    let before = ctl.room(named: "Dining")!.volume
    ctl.setVolume(before + 10, for: .room("Dining"))
    check(ctl.room(named: "Dining")!.volume == before, "setVolume ignored for disabled room")
    ctl.start(); try? await Task.sleep(for: .milliseconds(300)); ctl.stop()
    // Deallocation is checked in watchd, where nothing else holds the controller.
}
Task { await run(); print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(0) }
RunLoop.main.run()
