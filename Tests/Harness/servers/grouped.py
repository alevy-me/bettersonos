import http.server, socketserver, json, time, sys, threading
log = open(sys.argv[2], 'w')
lock = threading.Lock()
st = {"Kitchen": {"volume": 20, "mute": False}, "Dining": {"volume": 20, "mute": False}, "play": "PLAYING", "gv": 20, "gm": False}
def player(name, coord):
    return {"roomName": name, "uuid": "RINCON_" + name, "coordinator": coord,
            "state": {"volume": st[name]["volume"], "mute": st[name]["mute"], "playbackState": st["play"],
                      "currentTrack": {"title": "So What", "artist": "Miles Davis", "uri": "x-sonos-spotify:1"}},
            "groupState": {"volume": st["gv"], "mute": st["gm"]}}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def reply(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        log.write(f"{time.time():.3f} {self.path}\n"); log.flush()
        if parts == ["zones"]:
            with lock:
                z = [{"coordinator": player("Kitchen", "RINCON_Kitchen"), "members": [player("Kitchen", "RINCON_Kitchen"), player("Dining", "RINCON_Kitchen")]}]
            return self.reply(z)
        room, action = parts[0], parts[1]
        if action == "volume":
            time.sleep(1.0)  # slow, like the iPhone relay
            with lock: st[room]["volume"] = int(parts[2])
        elif action == "groupvolume":
            with lock: st["gv"] = int(parts[2])
        elif action in ("mute", "unmute"):
            with lock: st[room]["mute"] = action == "mute"
        elif action in ("groupmute", "groupunmute"):
            with lock: st["gm"] = action == "groupmute"
        elif action in ("play", "pause"):
            with lock: st["play"] = "PLAYING" if action == "play" else "PAUSED_PLAYBACK"
        self.reply({"status": "success"})
class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
S(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
