#!/usr/bin/env python3
"""Dev stub for auditor testing: serves dist/ear as the EAR plus canned
EPR endpoints on :9911. Real ES/Kibana come from start-local."""
import json, http.server, os, zipfile, io, sys

ROOT = os.environ.get("EAR_DIR", "dist/ear")
PORT = int(os.environ.get("STUB_PORT", "9911"))

class H(http.server.BaseHTTPRequestHandler):
    def send_json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p = self.path
        if p == "/health": return self.send_json({"status":"ok"})
        if p.startswith("/epr/"):
            buf = io.BytesIO(); zipfile.ZipFile(buf,"w").writestr("manifest.yml","x"*2000)
            b = buf.getvalue()
            self.send_response(200); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b); return
        if p.startswith("/search"):
            return self.send_json([{"name":"system","version":"3.5.0"}])
        f = os.path.normpath(ROOT + p)
        if f.startswith(os.path.abspath(ROOT)[:0] + ROOT) and os.path.isfile(f):
            b = open(f,"rb").read()
            self.send_response(200); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b); return
        self.send_json({"error":"not found"},404)
    def log_message(self,*a): pass

http.server.HTTPServer(("127.0.0.1",PORT),H).serve_forever()
