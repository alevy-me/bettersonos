import Foundation
import BetterSonosCore
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { fails += 1 } }
let serverPort = CommandLine.arguments[1], otherServerPort = CommandLine.arguments[2]

@MainActor func run() async {
    // two-groups.py reports players RINCON_Kitchen, RINCON_Dining and RINCON_Office.
    let householdSpeakers = ["RINCON_Kitchen": "127.0.0.1:9", "RINCON_Dining": "127.0.0.1:9", "RINCON_Office": "127.0.0.1:9", "RINCON_Bridge": "127.0.0.1:9"]
    let household = DiscoveredHousehold(householdID: "Sonos_HOME", speakers: householdSpeakers, roomNames: ["Dining", "Kitchen", "Office"])
    let server = NetworkConfig(id: UUID(), displayName: "Cabin Server", baseURL: "http://127.0.0.1:\(serverPort)", enabled: true, showDefaultPresetsForThisNetwork: false)
    let second = NetworkConfig(id: UUID(), displayName: "Same, by another address", baseURL: "http://127.0.0.1:\(otherServerPort)", enabled: true, showDefaultPresetsForThisNetwork: false)
    let local = NetworkConfig.local(householdID: "Sonos_HOME", name: "Home", speakers: householdSpeakers)

    // Server first (and a separate local entry already present): discovery merges them.
    let store = NetworkConfigStore()
    store.configs = [server, second, local]
    var outcome: DiscoveryOutcome = .found([household])
    let coordinator = DiscoveryCoordinator(networkStore: store, failureRetryInterval: 1) { outcome }
    coordinator.run(force: true)
    try? await Task.sleep(for: .seconds(2.5))
    let merged = store.configs.first { $0.id == server.id }
    check(merged?.householdID == "Sonos_HOME" && merged?.isHybrid == true && merged?.displayName == "Cabin Server", "the server network gains its household and keeps its name")
    check(!store.configs.contains { $0.isLocal }, "the separate local entry folds into it")
    check(store.configs.first { $0.id == second.id }?.householdID == nil, "a second matching server is left alone: the first match wins")
    check(coordinator.mergeNotice?.networkName == "Cabin Server" && coordinator.householdToName == nil, "a one-time notice names the network; no naming prompt")

    // Switching direct control off sticks: no re-merge, no new notice.
    coordinator.mergeNotice = nil
    var off = store.configs.first { $0.id == server.id }!
    off.directControlEnabled = false
    store.update(off)
    try? await Task.sleep(for: .seconds(2.5))
    coordinator.run(force: true)
    try? await Task.sleep(for: .seconds(2.5))
    let after = store.configs.first { $0.id == server.id }
    check(after?.directControlEnabled == false && after?.isHybrid == false && coordinator.mergeNotice == nil, "direct control switched off stays off, with no new notice")

    // Partial overlap: the server reports a speaker the household doesn't have. Not provably the same system.
    let store2 = NetworkConfigStore()
    let unrelated = NetworkConfig(id: UUID(), displayName: "Other", baseURL: "http://127.0.0.1:\(serverPort)", enabled: true, showDefaultPresetsForThisNetwork: false)
    store2.configs = [unrelated]
    let partial = DiscoveredHousehold(householdID: "Sonos_PARTIAL", speakers: ["RINCON_Kitchen": "127.0.0.1:9"], roomNames: ["Kitchen"])
    outcome = .found([partial])
    let coordinator2 = DiscoveryCoordinator(networkStore: store2, failureRetryInterval: 1) { outcome }
    coordinator2.run(force: true)
    try? await Task.sleep(for: .seconds(2.5))
    check(store2.configs.first?.householdID == nil && coordinator2.mergeNotice == nil && coordinator2.householdToName == nil, "partial overlap: neither merged nor offered as a duplicate")
}
Task { await run(); print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(0) }
RunLoop.main.run()
