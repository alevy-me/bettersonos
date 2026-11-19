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
    check(vm!.groups.map(\.coordinator) == ["Bedroom", "Big Speakers", "Kitchen", "Patio", "TV Room"], "rooms from the speakers: \(vm!.groups.map(\.coordinator))")
    check(vm!.volumeDisabled["Big Speakers"] == true && vm!.volumeDisabled["Kitchen"] == false, "Big Speakers grayed out as fixed, Kitchen not")
    check(vm!.volumeDisabled["Patio"] == true, "a silent speaker's never-read volume shows as unavailable")
    check(vm!.status == .connected, "one silent speaker doesn't make the network an error")
    check(store.configs.first?.speakerAddresses.count == 8, "addresses learned from the layout are saved: \(store.configs.first?.speakerAddresses.count ?? 0)")
    vm!.adjustVolume(room: "Kitchen", delta: 5)
    vm!.toggleMute(room: "TV Room")
    try? await Task.sleep(for: .seconds(1.5))
    check(vm!.volume["Kitchen"] == 39, "volume up from the app reaches the speaker: \(vm!.volume["Kitchen"] ?? -1)")
    check(vm!.isMuted["TV Room"] == false, "unmute from the app reaches the speaker")
    check(vm!.stationDisplay(for: "Bedroom") == "Radio Woodstock 100.1", "Bedroom shows its station: \(vm!.stationDisplay(for: "Bedroom"))")
    check(store.configs.first?.lastKnownServerFavorites?.map(\.name) == ["Dinner Jazz", "FIP", "Radio Woodstock 100.1", "WWNO"], "favorites merged from the speakers")
    // Unavailable needs three failed scheduled polls in a row; refreshes after actions never count.
    var unreachableReports = 0, reachableReports = 0
    let observers = [
        NotificationCenter.default.addObserver(forName: DiscoveryCoordinator.localNetworkUnreachable, object: nil, queue: .main) { _ in unreachableReports += 1 },
        NotificationCenter.default.addObserver(forName: DiscoveryCoordinator.localNetworkReachable, object: nil, queue: .main) { _ in reachableReports += 1 },
    ]
    let live = store.configs[0]
    var gone = live
    gone.speakerAddresses = ["x": "127.0.0.1:9"]
    store.configs = [gone]
    for _ in 0..<5 { await vm!.refresh(kind: .action) }
    await vm!.refresh(kind: .scheduled)
    await vm!.refresh(kind: .scheduled)
    check(vm!.status == .connected && unreachableReports == 0, "failed action refreshes and two failed polls change nothing: \(vm!.status)")
    await vm!.refresh(kind: .scheduled)
    if case .error = vm!.status { check(unreachableReports == 1, "the third failed poll shows the error and tells discovery once") }
    else { check(false, "the third failed poll must show the error: \(vm!.status)") }
    await vm!.refresh(kind: .scheduled)
    check(unreachableReports == 1, "discovery is told once, not on every poll")
    store.configs = [live]
    await vm!.refresh(kind: .scheduled)
    try? await Task.sleep(for: .milliseconds(200))
    check(vm!.status == .connected && reachableReports == 1, "speakers answering again clears it and tells discovery")
    observers.forEach(NotificationCenter.default.removeObserver)

    vm = nil
    try? await Task.sleep(for: .milliseconds(500))
    check(weakVM == nil, "local view model deallocates")
}
Task { await run(); print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(0) }
RunLoop.main.run()
