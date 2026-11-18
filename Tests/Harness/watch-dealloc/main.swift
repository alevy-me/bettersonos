import BetterSonosCore
import Foundation
let port = CommandLine.arguments[1]
@MainActor func run() async {
    var c: WatchNetworkController? = WatchNetworkController(config: NetworkConfig(id: UUID(), displayName: "T", baseURL: "http://127.0.0.1:\(port)", enabled: true, showDefaultPresetsForThisNetwork: false))
    weak var weakC = c
    c!.start()
    try? await Task.sleep(for: .milliseconds(500))
    print("rooms loaded while polling:", c!.rooms.count)
    c!.setVolume(33, for: .room("Kitchen"))
    try? await Task.sleep(for: .seconds(2))
    c!.stop()
    c = nil
    try? await Task.sleep(for: .milliseconds(300))
    print(weakC == nil ? "PASS controller deallocates after stop" : "FAIL controller still alive")
}
Task { await run(); exit(0) }
RunLoop.main.run()
