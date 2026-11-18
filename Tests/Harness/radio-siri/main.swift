import Foundation
import BetterSonosCore
let port = CommandLine.arguments[1]
let favs = [Station(name: "Radio Woodstock 100.1", url: "Radio Woodstock 100.1", type: .favorite)]
let cfg = NetworkConfig(id: UUID(), displayName: "Second", baseURL: "http://127.0.0.1:\(port)", enabled: true, showDefaultPresetsForThisNetwork: false, lastKnownServerFavorites: favs)
UserDefaults.standard.set(try! JSONEncoder().encode([cfg]), forKey: "sonosNetworkConfigs")
@MainActor func run() async {
    _ = await SonosHTTP.get(URL(string: "http://127.0.0.1:\(port)/Den/pause"))
    var resume = ResumeIntent(); resume.room = RoomEntity(networkID: cfg.id, networkName: "Second", name: "Den", showNetwork: false)
    _ = try? await resume.perform()
    let den = try! await SonosDirectory.locate(resume.room)
    print(den.isPlaying ? "PASS Siri resume restarts the stopped stream" : "FAIL Siri resume left it \(den.coordinator.state.playbackState)")
    print(SonosDirectory.describe(den.coordinator.state.currentTrack, on: cfg) == "Radio Woodstock 100.1" ? "PASS Siri says only the station" : "FAIL Siri description")
}
Task { await run(); exit(0) }
RunLoop.main.run()
