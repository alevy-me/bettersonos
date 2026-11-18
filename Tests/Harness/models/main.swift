import Foundation
import BetterSonosCore
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { fails += 1 } }
check(StationCSV.parseStations("name,url,type\r\nA,http://a.com/s,stream\r\nB,http://b.com/s\r\n".data(using: .utf8)!).count == 2, "CRLF parses 2")
check(StationCSV.parseStations("name,url\rA,http://a\rB,http://b".data(using: .utf8)!).count == 2, "CR-only parses 2")
let qs = StationCSV.parseStations("\u{FEFF}name,url,type\n\"Radio Paradise, Main Mix\",http://rp.com/x,stream\nClassic Rock,,stream\n\"Say \"\"Hi\"\"\",http://h.com,\n".data(using: .utf8)!)
check(qs.count == 2 && qs.first?.name == "Radio Paradise, Main Mix" && qs.last?.name == "Say \"Hi\"", "quoting and empty fields")
let s = Station(name: "x", url: "y", type: StationType(rawValue: "playlist"))
let dec = try! JSONDecoder().decode([Station].self, from: try! JSONEncoder().encode([s]))
check(String(data: try! JSONEncoder().encode(dec), encoding: .utf8)!.contains("\"playlist\""), "unknown type round-trips")
let kcrw = Station(name: "KCRW", url: "x-sonosapi-stream:s1?sid=254", type: .stream)
let ecl = Station(name: "KCRW Eclectic24", url: "x-sonosapi-stream:s2?sid=254", type: .stream)
check(bestMatchingStation(in: [kcrw, ecl], for: Track(stationName: "KCRW Eclectic24", uri: "x-sonosapi-stream:s9?sid=254")) == ecl, "exact name beats prefix")
check(bestMatchingStation(in: [Station(name: "Classic Rock", url: "stream", type: .stream)], for: Track(uri: "x-sonosapi-stream:abc")) == nil, "short url does not match everything")
check(Station(name: "T", url: "x-rincon-stream:RINCON_ABC123", type: .lineIn).matchScore(for: Track(uri: "x-rincon-stream:RINCON_abc123:1")) == 4, "line-in UUID case-insensitive")
check(URLInput.join(scheme: "https://", address: "https://ice1.somafm.com/x") == "https://ice1.somafm.com/x", "no double scheme")
check(URLInput.normalizedBaseURL("http://pi.local:5005/ ") == "http://pi.local:5005", "trailing slash trimmed")
check(SonosHTTP.url(base: "http://pi:5005", ["Living Room", "favorite", "This Is AC/DC"])?.absoluteString == "http://pi:5005/Living%20Room/favorite/This%20Is%20AC%2FDC", "strict segment encoding")
let ro = NetworkConfigStore(cloudReadOnly: true)
check(ro.isCloudReadOnly, "read-only store flag")
print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
