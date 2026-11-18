import Foundation
import BetterSonosCore
struct Row: Decodable { let room: String; let playbackState: String; let title: String?; let artist: String?; let stationName: String?; let type: String?; let uri: String? }
let rows = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n").map { try! JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
// Preset names the matcher would supply for direct streams from the user's CSV.
func preset(_ uri: String?) -> String? {
    guard let u = uri?.removingPercentEncoding else { return nil }
    if u.contains("wwoz") { return "WWOZ" }
    if u.contains("fip") { return "FIP" }
    return nil
}
// What each captured state must show: the source and nothing else.
func expected(_ r: Row) -> String? {
    if let s = r.stationName, !s.isEmpty { return preset(r.uri) ?? s }
    if let p = preset(r.uri) { return p }
    if r.uri?.lowercased().contains("spotify") == true { return "Spotify" }
    if r.uri?.hasPrefix("x-rincon-stream:") == true { return "Line In · TV" }
    if r.uri?.contains("mexside") == true { return "s2.mexside.net" }
    return nil
}
var fails = 0, checked = 0
for r in rows {
    let np = NowPlaying(track: Track(title: r.title, artist: r.artist, stationName: r.stationName, uri: r.uri, type: r.type), presetName: preset(r.uri))
    let want = expected(r)
    checked += 1
    if np?.line != want {
        fails += 1
        print("FAIL \(r.room) \(r.playbackState) title=\(r.title ?? "nil") station=\(r.stationName ?? "nil") -> \(np?.line ?? "nil"), want \(want ?? "nil")")
    }
}
var distinct = Set<String>()
for r in rows { if let l = NowPlaying(track: Track(title: r.title, artist: r.artist, stationName: r.stationName, uri: r.uri, type: r.type), presetName: preset(r.uri))?.line { distinct.insert(l) } }
print("shown across all \(checked) states:", distinct.sorted())
print(fails == 0 ? "ALL \(checked) MATCH" : "\(fails) MISMATCHED")
