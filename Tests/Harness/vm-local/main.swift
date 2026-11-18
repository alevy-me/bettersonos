import Foundation
import BetterSonosCore
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { fails += 1 } }
let base = CommandLine.arguments[1]
@MainActor func run() async {
    let store = NetworkConfigStore()
    var cfg = NetworkConfig.local(householdID: "Sonos_TEST", name: "Home", speakers: ["RINCON_K01400": "127.0.0.1:\(base)"])
    cfg.showDefaultPresetsForThisNetwork = false
    store.configs = [cfg]
    var vm: SonosViewModel? = SonosViewModel(configID: cfg.id, baseURL: cfg.baseURL, networkStore: store, settingsStore: AppSettingsStore.shared)
    weak var weakVM = vm
    try? await Task.sleep(for: .seconds(2))
    check(vm!.status == .connected, "local network connects with no server: \(vm!.status)")
    check(vm!.groups.map(\.coordinator) == ["Bedroom", "Kitchen", "TV Room"], "rooms from the speakers: \(vm!.groups.map(\.coordinator))")
    check(vm!.stationDisplay(for: "Bedroom") == "Radio Woodstock 100.1", "Bedroom shows its station: \(vm!.stationDisplay(for: "Bedroom"))")
    check(store.configs.first?.lastKnownServerFavorites?.map(\.name) == ["FIP", "Radio Woodstock 100.1", "WWNO"], "favorites merged from the speakers")
    vm = nil
    try? await Task.sleep(for: .milliseconds(500))
    check(weakVM == nil, "local view model deallocates")
}
Task { await run(); print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(0) }
RunLoop.main.run()
