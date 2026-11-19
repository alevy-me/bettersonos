# Answers every request with HTTP 500 and logs one line per request, so a test can count how often
# it's polled. Usage: refuse.py PORT LOG
import http.server, socketserver, sys
log = open(sys.argv[2], "a")
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        log.write("request\n"); log.flush()
        self.send_response(500); self.send_header("Content-Length", "0"); self.end_headers()
class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
S(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
