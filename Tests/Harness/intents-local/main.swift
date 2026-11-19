import Foundation
import AppIntents
import BetterSonosCore
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { fails += 1 } }
let speakerPort = CommandLine.arguments[1], serverPort = CommandLine.arguments[2]

var home = NetworkConfig.local(householdID: "Sonos_TEST", name: "Home", speakers: ["RINCON_K01400": "127.0.0.1:\(speakerPort)"])
home.showDefaultPresetsForThisNetwork = false
home.lastKnownServerFavorites = ["WWNO", "FIP"].map { Station(name: $0, url: $0, type: .favorite) }
let server = NetworkConfig(id: UUID(), displayName: "Second", baseURL: "http://127.0.0.1:\(serverPort)", enabled: true, showDefaultPresetsForThisNetwork: false)
let away = NetworkConfig.local(householdID: "Sonos_AWAY", name: "Cabin", speakers: ["x": "127.0.0.1:9"])
UserDefaults.standard.set(try! JSONEncoder().encode([home, server, away]), forKey: "sonosNetworkConfigs")

@MainActor func run() async {
    let rooms = try! await RoomQuery().suggestedEntities()
    let homeRooms = rooms.filter { $0.networkID == home.id }.map(\.name).sorted()
    check(homeRooms == ["Bedroom", "Big Speakers", "Kitchen", "Patio", "TV Room", "Upstairs Bathroom"], "Siri sees the local network's rooms: \(homeRooms)")
    check(rooms.contains { $0.networkID == server.id }, "alongside the server network's rooms")
    check(!rooms.contains { $0.networkID == away.id }, "an unreachable local network contributes no rooms")
    func room(_ name: String) -> RoomEntity { rooms.first { $0.name == name && $0.networkID == home.id }! }

    var preset = PlayPresetIntent(); preset.room = room("Kitchen")
    preset.preset = PresetEntity(networkID: home.id, station: Station(name: "WWNO", url: "WWNO", type: .favorite))
    _ = try? await preset.perform()
    check(try! await SonosDirectory.locate(room("Kitchen")).isPlaying, "\"Play WWNO in the Kitchen\" plays it")
    var pause = PauseIntent(); pause.room = room("Kitchen")
    _ = try? await pause.perform()
    var resume = ResumeIntent(); resume.room = room("Kitchen")
    _ = try? await resume.perform()
    check(try! await SonosDirectory.locate(room("Kitchen")).isPlaying, "pause then resume restarts the stopped stream")

    var fixed = SetVolumeIntent(); fixed.room = room("Big Speakers"); fixed.level = 30
    do { _ = try await fixed.perform(); check(false, "fixed-output volume must be refused") }
    catch { if case SonosIntentError.fixedVolume = error { check(true, "Big Speakers refuses volume: fixed output read from the speaker") } else { check(false, "wrong error \(error)") } }

    var patioPlaying = WhatsPlayingIntent(); patioPlaying.room = room("Patio")
    do { _ = try await patioPlaying.perform(); check(false, "a silent room must not be reported as paused") }
    catch { check("\(error)" == "notResponding(\"Patio\")", "\"What's playing on Patio\": Patio isn't responding, not paused") }
    var patioVolume = VolumeUpIntent(); patioVolume.room = room("Patio"); patioVolume.amount = 10
    do { _ = try await patioVolume.perform(); check(false, "volume on a silent room must fail") }
    catch { check("\(error)" == "notResponding(\"Patio\")", "volume on a silent room: isn't responding, not fixed volume") }
    let playing = await SonosDirectory.playingGroups()
    check(!playing.contains { $0.roomName == "Patio" }, "a silent group never counts as playing")

    let cabin = RoomEntity(networkID: away.id, networkName: "Cabin", name: "Den", showNetwork: true)
    do { _ = try await SonosDirectory.locate(cabin); check(false, "unreachable local network must fail") }
    catch { check("\(error)" == "notOnNetwork(\"Cabin\")", "away from a local network, Siri names it: can't reach the Cabin speakers from here") }
}
Task { await run(); print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(0) }
RunLoop.main.run()
