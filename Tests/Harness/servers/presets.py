import http.server, socketserver, json, time, sys, threading, urllib.parse
log = open(sys.argv[2], 'w')
st = {"play": "PAUSED_PLAYBACK", "track": {"title": "", "uri": ""}}
def player(name):
    return {"roomName": name, "uuid": "RINCON_" + name, "state": {"volume": 20, "mute": False, "playbackState": st["play"], "currentTrack": st["track"]}, "groupState": {"volume": 20, "mute": False}}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def send(self, code, body, ctype):
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        log.write(self.path + "\n"); log.flush()
        if self.path == "/stations.csv":
            return self.send(200, b"name,url,type\r\nGroove Salad,http://ice1.somafm.com/groovesalad,stream\r\n\"Jazz, Live\",http://jazz.example.com/live,\r\n", "text/csv")
        if self.path == "/missing.csv":
            return self.send(404, b"<html>404</html>", "text/html")
        if self.path == "/zones":
            z = [{"coordinator": player("Kitchen"), "members": [player("Kitchen"), player("Dining")]}]
            return self.send(200, json.dumps(z).encode(), "application/json")
        parts = [urllib.parse.unquote(p) for p in self.path.strip("/").split("/")]
        if len(parts) >= 3 and parts[1] == "setavtransporturi":
            st["track"] = {"title": "", "uri": parts[2]}
        elif len(parts) >= 3 and parts[1] == "favorite":
            st["track"] = {"title": "Track", "stationName": parts[2], "uri": "x-sonosapi-stream:fav"}
            st["play"] = "PLAYING"
        elif len(parts) >= 2 and parts[1] == "play":
            st["play"] = "PLAYING"
        self.send(200, b'{"status":"success"}', "application/json")
class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
S(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
