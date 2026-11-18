import Foundation
import BetterSonosCore
let port = CommandLine.arguments[1]
@MainActor func run() async {
    let store = NetworkConfigStore()
    let cfg = NetworkConfig(id: UUID(), displayName: "T", baseURL: "http://127.0.0.1:\(port)/", enabled: true, showDefaultPresetsForThisNetwork: false)
    store.configs = [cfg]
    var vm: SonosViewModel? = SonosViewModel(configID: cfg.id, baseURL: cfg.baseURL, networkStore: store, settingsStore: AppSettingsStore.shared)
    weak var weakVM = vm
    try? await Task.sleep(for: .seconds(3))
    let connected = vm!.status == .connected && vm!.groups.map(\.coordinator) == ["Kitchen"]
    print(connected ? "PASS connects and loads rooms" : "FAIL status \(vm!.status), groups \(vm!.groups.map(\.coordinator))")
    vm = nil
    try? await Task.sleep(for: .seconds(2))
    print(weakVM == nil ? "PASS deallocates and closes its stream" : "FAIL view model still alive")
}
Task { await run(); exit(0) }
RunLoop.main.run()
