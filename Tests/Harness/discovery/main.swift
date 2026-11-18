import Foundation
import BetterSonosCore
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { fails += 1 } }
let serverPort = CommandLine.arguments[1]

@MainActor func run() async {
    // The grouped fake server reports players RINCON_Kitchen and RINCON_Dining.
    let server = NetworkConfig(id: UUID(), displayName: "Server", baseURL: "http://127.0.0.1:\(serverPort)", enabled: true, showDefaultPresetsForThisNetwork: false)
    let household = DiscoveredHousehold(householdID: "Sonos_TEST", speakers: ["RINCON_Kitchen": "127.0.0.1:9"], roomNames: ["Kitchen"])
    let store = NetworkConfigStore()
    store.configs = [server]

    var discoverCalls = 0
    let coordinator = DiscoveryCoordinator(networkStore: store) {
        discoverCalls += 1
        return .found([household])
    }

    coordinator.run(force: true)
    try? await Task.sleep(for: .seconds(1.5))
    check(discoverCalls == 1, "launch runs discovery once: \(discoverCalls)")
    check(coordinator.householdToName == nil, "a household a server network covers is not offered")

    // The bug: turning the server network off must offer the household, with no relaunch.
    var disabled = server
    disabled.enabled = false
    store.update(disabled)
    try? await Task.sleep(for: .seconds(1.5))
    check(coordinator.householdToName?.householdID == "Sonos_TEST", "disabling the server network offers the household")
    check(coordinator.suggestedName() == "Home", "offered as Home: \(coordinator.suggestedName())")

    // A burst of edits is folded into a run or two, not one per edit.
    let before = discoverCalls
    for i in 0..<10 {
        var edited = disabled
        edited.displayName = "Server \(i)"
        edited.baseURL = "http://127.0.0.1:\(serverPort)/\(i)"
        store.update(edited)
        try? await Task.sleep(for: .milliseconds(50))
    }
    try? await Task.sleep(for: .seconds(2))
    let burst = discoverCalls - before
    check(burst >= 1 && burst <= 2, "ten quick edits cause \(burst) discovery runs")

    // Favorites merges are the app's own routine writes and must not trigger discovery.
    let quiet = discoverCalls
    store.mergeFavorites(for: server.id, newFavoritesFromServer: [Station(name: "WWNO", url: "WWNO", type: .favorite)])
    try? await Task.sleep(for: .seconds(1.5))
    check(discoverCalls == quiet, "a favorites merge does not trigger discovery")

    // Confirming creates the local network, which then counts as reachable.
    coordinator.confirm(household, name: "Home")
    let local = store.configs.first { $0.householdID == "Sonos_TEST" }
    check(local?.isLocal == true && local?.displayName == "Home", "confirm creates the local network named Home")
    check(local.map(coordinator.isAvailable) == true, "the new local network is available")

    // A local network that stops answering asks for a run, at most every 30 seconds.
    let beforeFailure = discoverCalls
    for _ in 0..<5 { NotificationCenter.default.post(name: DiscoveryCoordinator.localNetworkUnreachable, object: "Sonos_TEST") }
    try? await Task.sleep(for: .seconds(1.5))
    check(discoverCalls - beforeFailure == 1, "five failure reports cause one run: \(discoverCalls - beforeFailure)")
}
Task { await run(); print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(0) }
RunLoop.main.run()
