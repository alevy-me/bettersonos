import http.server, socketserver, json, time, sys, threading
MODE = sys.argv[2]
log = open(sys.argv[3], 'a')
zone = {"coordinator": {"roomName":"Kitchen","uuid":"RINCON_1","state":{"volume":20,"mute":False,"playbackState":"PLAYING","currentTrack":None}},
        "members":[{"roomName":"Kitchen","uuid":"RINCON_1","state":{"volume":20,"mute":False,"playbackState":"PLAYING","currentTrack":None}}]}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        log.write(f"{time.time():.2f} GET {self.path}\n"); log.flush()
        if self.path == "/events":
            if MODE == "error":
                body = b"<html>502 Bad Gateway</html>"
                self.send_response(502); self.send_header("Content-Type","text/html"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body); return
            self.send_response(200); self.send_header("Content-Type","text/event-stream"); self.end_headers()
            ev = b'data: ' + json.dumps({"type":"transport-state","data":{"pad":"x"*20000}}).encode() + b'\n\n'
            try:
                self.wfile.write(ev[:7000]); self.wfile.flush(); time.sleep(0.3)
                self.wfile.write(ev[7000:]); self.wfile.flush()
                while True:
                    time.sleep(0.5); self.wfile.write(b": keepalive\n\n"); self.wfile.flush()
            except Exception as e:
                log.write(f"{time.time():.2f} SSE closed by client\n"); log.flush()
            return
        body = json.dumps([zone] if self.path == "/zones" else []).encode()
        self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
S(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
