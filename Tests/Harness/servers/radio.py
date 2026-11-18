import http.server, socketserver, json, sys, urllib.parse
log = open(sys.argv[2], 'w')
woodstock = {"title": "TYPE=SNG|TITLE #9 Dream|ARTIST John Lennon|ALBUM", "artist": "", "stationName": "Radio Woodstock 100.1", "uri": "x-sonosapi-stream:live_stations.7332?sid=6&flags=8232&sn=4", "type": "radio"}
unknown = {"title": "", "stationName": "Jazz Radio by Maestro - Steamin'", "uri": "x-sonosapi-stream:tunein%3a95000?sid=303", "type": "radio"}
st = {"Den": {"play": "PLAYING", "track": woodstock}, "Downstairs": {"play": "STOPPED", "track": unknown}}
def player(n): return {"roomName": n, "uuid": "RINCON_" + n, "state": {"volume": 20, "mute": False, "playbackState": st[n]["play"], "currentTrack": st[n]["track"]}, "groupState": {"volume": 20, "mute": False}}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def send(self, body):
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        log.write(self.path + "\n"); log.flush()
        if self.path == "/zones":
            return self.send(json.dumps([{"coordinator": player(n), "members": [player(n)]} for n in st]).encode())
        parts = [urllib.parse.unquote(p) for p in self.path.strip("/").split("/")]
        room, action = parts[0], parts[1]
        if action == "pause": st[room]["play"] = "STOPPED"          # live radio stops instead of pausing
        elif action == "play" and st[room]["play"] != "STOPPED": st[room]["play"] = "PLAYING"
        elif action == "play": pass                                  # 200, but a stopped stream stays stopped
        elif action == "favorite": st[room]["track"] = dict(woodstock, stationName=parts[2]); st[room]["play"] = "PLAYING"
        self.send(b'{"status":"success"}')
class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
S(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
