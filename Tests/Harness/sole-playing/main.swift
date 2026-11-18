import Foundation
import BetterSonosCore
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { fails += 1 } }
let home = CommandLine.arguments[1], other = CommandLine.arguments[2]
func cfg(_ port: String) -> NetworkConfig { NetworkConfig(id: UUID(), displayName: port, baseURL: "http://127.0.0.1:\(port)", enabled: true, showDefaultPresetsForThisNetwork: false) }
func get(_ port: String, _ path: String) async { _ = await SonosHTTP.get(URL(string: "http://127.0.0.1:\(port)/\(path)")) }
@MainActor func run() async {
    let a = WatchNetworkController(config: cfg(home)), b = WatchNetworkController(config: cfg(other))
    let both = [a, b]
    // Network A: Kitchen+Dining playing, Office paused. Network B starts the same; pause everything there.
    await get(other, "Kitchen/pause")
    var r = await WatchNetworkController.solePlayingRoom(across: both, lastNetworkID: a.configID, lastRoom: "Dining")
    check(r?.networkID == a.configID && r?.room == "Dining", "one group playing on A, last room in it -> Dining on A")
    r = await WatchNetworkController.solePlayingRoom(across: both, lastNetworkID: b.configID, lastRoom: "Dining")
    check(r?.networkID == a.configID && r?.room == "Kitchen", "last room was on B -> A's coordinator, not B")
    await get(other, "Office/play")
    r = await WatchNetworkController.solePlayingRoom(across: both, lastNetworkID: a.configID, lastRoom: "Dining")
    check(r == nil, "one playing on A and one on B -> no jump")
    await get(home, "Kitchen/pause")
    r = await WatchNetworkController.solePlayingRoom(across: both, lastNetworkID: a.configID, lastRoom: "Dining")
    check(r?.networkID == b.configID && r?.room == "Office", "only B's Office playing -> Office on B, even though A was last")
    await get(other, "Office/pause")
    r = await WatchNetworkController.solePlayingRoom(across: both, lastNetworkID: a.configID, lastRoom: "Dining")
    check(r == nil, "nothing playing anywhere -> no jump")
}
Task { await run(); print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(0) }
RunLoop.main.run()
