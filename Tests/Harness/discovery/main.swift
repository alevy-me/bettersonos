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
    var nextOutcome: DiscoveryOutcome = .found([household])
    // Outage-triggered runs are rate-limited to one per 2 s here (30 s in the app), so the test is quick.
    let coordinator = DiscoveryCoordinator(networkStore: store, failureRetryInterval: 2) {
        discoverCalls += 1
        return nextOutcome
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

    let beforeFailure = discoverCalls
    for _ in 0..<5 { NotificationCenter.default.post(name: DiscoveryCoordinator.localNetworkUnreachable, object: "Sonos_TEST") }
    try? await Task.sleep(for: .seconds(1.5))
    check(discoverCalls - beforeFailure == 1, "five failure reports cause one run: \(discoverCalls - beforeFailure)")

    // Availability. The household's only known address is dead (127.0.0.1:9), and Bonjour now finds
    // nothing, so every discovery probe of it fails.
    let home = store.configs.first { $0.householdID == "Sonos_TEST" }!
    NotificationCenter.default.post(name: DiscoveryCoordinator.localNetworkReachable, object: "Sonos_TEST")
    try? await Task.sleep(for: .milliseconds(200))
    nextOutcome = .nothingFound
    coordinator.run(force: true)
    try? await Task.sleep(for: .seconds(2.5))
    check(coordinator.isAvailable(home), "a loaded network stays available when a discovery probe fails: not confirmed")
    try? await Task.sleep(for: .seconds(2.5)) // past the rate limit, and any deferred run from earlier
    NotificationCenter.default.post(name: DiscoveryCoordinator.localNetworkUnreachable, object: "Sonos_TEST")
    try? await Task.sleep(for: .seconds(2.5))
    check(!coordinator.isAvailable(home), "after its view model confirms the silence, it becomes unavailable")
    NotificationCenter.default.post(name: DiscoveryCoordinator.localNetworkReachable, object: "Sonos_TEST")
    try? await Task.sleep(for: .milliseconds(200))
    check(coordinator.isAvailable(home), "and comes back as soon as the speakers answer")

    // An outage reported inside the rate limit isn't dropped: its run happens when the limit allows.
    // (The last failure-triggered run was moments ago, so this report is inside the window.)
    NotificationCenter.default.post(name: DiscoveryCoordinator.localNetworkReachable, object: "Sonos_TEST")
    try? await Task.sleep(for: .milliseconds(200))
    NotificationCenter.default.post(name: DiscoveryCoordinator.localNetworkUnreachable, object: "Sonos_TEST")
    let runsBefore = discoverCalls
    try? await Task.sleep(for: .milliseconds(300))
    check(discoverCalls == runsBefore, "inside the rate limit: no immediate run")
    try? await Task.sleep(for: .seconds(3))
    check(discoverCalls == runsBefore + 1, "the deferred run happens once the limit allows: \(discoverCalls - runsBefore)")
    check(!coordinator.isAvailable(home), "and it applies the confirmed outage")

    // Finding the household again clears the confirmed outage, so a later single missed probe can't
    // make it flicker.
    nextOutcome = .found([household])
    coordinator.run(force: true)
    try? await Task.sleep(for: .seconds(2.5))
    check(coordinator.isAvailable(home), "found by discovery: available again")
    nextOutcome = .nothingFound
    coordinator.run(force: true)
    try? await Task.sleep(for: .seconds(2.5))
    check(coordinator.isAvailable(home), "then one missed probe keeps it available: the confirmation was cleared")
}
Task { await run(); print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(0) }
RunLoop.main.run()
