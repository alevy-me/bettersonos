import Foundation
import AppIntents
import BetterSonosCore
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { fails += 1 } }
let a = CommandLine.arguments[1], b = CommandLine.arguments[2]
func get(_ port: String, _ path: String) async { _ = await SonosHTTP.get(URL(string: "http://127.0.0.1:\(port)/\(path)")) }

let favs = ["This Is AC/DC"].map { Station(name: $0, url: $0, type: .favorite) }
let netA = NetworkConfig(id: UUID(), displayName: "Home", baseURL: "http://127.0.0.1:\(a)/", enabled: true, showDefaultPresetsForThisNetwork: false, lastKnownServerFavorites: favs)
let netB = NetworkConfig(id: UUID(), displayName: "Second", baseURL: "http://127.0.0.1:\(b)", enabled: true, showDefaultPresetsForThisNetwork: false, lastKnownServerFavorites: favs, manuallyDisabledVolumeUUIDs: ["RINCON_Dining"])
let netDown = NetworkConfig(id: UUID(), displayName: "Down", baseURL: "http://127.0.0.1:9", enabled: true, showDefaultPresetsForThisNetwork: false)
UserDefaults.standard.set(try! JSONEncoder().encode([netA, netB, netDown]), forKey: "sonosNetworkConfigs")

func expectError(_ m: String, _ body: () async throws -> Void, _ match: (Error) -> Bool) async {
    do { try await body(); check(false, m + " (no error)") } catch { check(match(error), m + " -> \(error)") }
}

@MainActor func run() async {
    let rooms = try! await RoomQuery().suggestedEntities()
    check(rooms.count == 6 && rooms.allSatisfy(\.showNetwork), "6 rooms across 2 live networks, down one skipped: \(rooms.map { "\($0.name)@\($0.networkName)" })")
    let kitchens = try! await RoomQuery().entities(matching: "kitchen")
    check(kitchens.count == 2, "\"kitchen\" matches one room per network")
    func room(_ name: String, _ net: NetworkConfig) -> RoomEntity { rooms.first { $0.name == name && $0.networkID == net.id }! }

    // Both networks start with Kitchen+Dining playing: a roomless pause must ask.
    var pause = PauseIntent()
    await expectError("roomless pause with two playing groups asks which room", { _ = try await pause.perform() }) { "\($0)".contains("missing parameter value") }
    await get(b, "Kitchen/pause")
    pause = PauseIntent()
    _ = try? await pause.perform()
    let aZones = try! await SonosDirectory.zones(for: netA)
    check(aZones.first?.coordinator.state.playbackState == "PAUSED_PLAYBACK", "roomless pause paused the only playing group (Home Kitchen)")

    var resume = ResumeIntent(); resume.room = room("Dining", netA)
    _ = try? await resume.perform()
    check(try! await SonosDirectory.zones(for: netA).first?.coordinator.state.playbackState == "PLAYING", "resume Dining plays its group via Kitchen")

    var up = VolumeUpIntent(); up.room = room("Dining", netA); up.amount = 10
    _ = try? await up.perform()
    let dining = try! await SonosDirectory.locate(room("Dining", netA))
    check(dining.member.state.volume == 30, "volume up Dining 20 -> \(dining.member.state.volume)")

    var upFixed = VolumeUpIntent(); upFixed.room = room("Dining", netB); upFixed.amount = 10
    await expectError("fixed-volume room refuses volume", { _ = try await upFixed.perform() }) { if case SonosIntentError.fixedVolume = $0 { return true }; return false }

    var set = SetVolumeIntent(); set.room = room("Office", netA); set.level = 140
    _ = try? await set.perform()
    check(try! await SonosDirectory.locate(room("Office", netA)).member.state.volume == 100, "set volume clamps to 100")

    var mute = MuteIntent(); mute.room = room("Kitchen", netA)
    _ = try? await mute.perform()
    check(try! await SonosDirectory.locate(room("Kitchen", netA)).member.state.mute, "mute Kitchen")
    var unmute = UnmuteIntent(); unmute.room = room("Kitchen", netA)
    _ = try? await unmute.perform()
    check(!(try! await SonosDirectory.locate(room("Kitchen", netA)).member.state.mute), "unmute Kitchen")

    let presetsA = await SonosDirectory.presets(for: netA)
    check(presetsA.map(\.name) == ["This Is AC/DC"], "presets for Home: \(presetsA.map(\.name))")
    var play = PlayPresetIntent(); play.room = room("Dining", netA); play.preset = presetsA[0]
    _ = try? await play.perform()
    var cross = PlayPresetIntent(); cross.room = room("Dining", netB); cross.preset = presetsA[0]
    await expectError("preset from another network is refused", { _ = try await cross.perform() }) { if case SonosIntentError.presetOnOtherNetwork = $0 { return true }; return false }

    let down = RoomEntity(networkID: netDown.id, networkName: "Down", name: "Den", showNetwork: true)
    await expectError("unreachable network reports it", { _ = try await SonosDirectory.locate(down) }) { if case SonosIntentError.unreachable = $0 { return true }; return false }
    await expectError("unknown room reports it", { _ = try await SonosDirectory.locate(RoomEntity(networkID: netA.id, networkName: "Home", name: "Attic", showNetwork: true)) }) { if case SonosIntentError.roomNotFound = $0 { return true }; return false }

    let playing = await SonosDirectory.playingGroups()
    let spoken = SonosDirectory.describe(playing.first?.coordinator.state.currentTrack, on: netA)
    check(playing.map(\.roomName) == ["Kitchen"] && spoken == "Spotify", "what's playing: Kitchen is playing \(spoken ?? "nil")")

    let cached = RoomEntity.loadCache()
    check(cached.count == 6, "room cache written for offline suggestions")
}
Task { await run(); print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(0) }
RunLoop.main.run()
