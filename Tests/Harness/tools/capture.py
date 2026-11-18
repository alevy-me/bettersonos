# Read-only: polls /zones once a second and logs every distinct metadata state per room.
import json, sys, time, urllib.request
# Usage: capture.py OUT.jsonl SECONDS NAME=URL [NAME=URL ...]
servers = dict(arg.split("=", 1) for arg in sys.argv[3:])
out = open(sys.argv[1], "a")
seen = {}
end = time.time() + float(sys.argv[2])
while time.time() < end:
    for net, base in servers.items():
        try:
            zones = json.load(urllib.request.urlopen(base + "/zones", timeout=4))
        except Exception as e:
            continue
        for z in zones:
            c = z["coordinator"]; s = c["state"]; t = s.get("currentTrack") or {}
            key = (net, c["roomName"])
            snap = {k: t.get(k) for k in ("title", "artist", "album", "stationName", "type", "uri")}
            snap["playbackState"] = s.get("playbackState")
            if seen.get(key) != snap:
                seen[key] = snap
                out.write(json.dumps({"t": round(time.time(), 1), "net": net, "room": c["roomName"], **snap}) + "\n"); out.flush()
    time.sleep(1)
