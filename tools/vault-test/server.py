"""A checkout page and a charge endpoint for the vault test: the page says what it received without echoing it; the
endpoint logs the body it got (to check a vault placeholder arrived as the value)."""
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAGE = """<!doctype html><html><head><meta name=viewport content="width=device-width,initial-scale=1"><title>Checkout</title>
<style>body{font:17px -apple-system;margin:20px}label{display:block;margin:14px 0 4px}input{font:inherit;width:100%;padding:8px}#status{margin-top:16px;color:#080}</style></head>
<body><h1>Checkout</h1><form onsubmit="return false">
<label for=name>Name on card</label><input id=name name=name autocomplete=off>
<label for=number>Card number</label><input id=number name=number autocomplete=off>
<label for=expiry>Expiry</label><input id=expiry name=expiry autocomplete=off>
<label for=cvv>Security code</label><input id=cvv name=cvv autocomplete=off>
</form><p id=status>Waiting for the card.</p>
<script>
const report = () => {
  const n = document.getElementById("number").value.replace(/\\D/g, ""), c = document.getElementById("cvv").value;
  document.getElementById("status").textContent = (n ? "Card number received: " + n.length + " digits, ends " + n.slice(-4) : "No card number") + (c ? "; security code received (" + c.length + " digits)" : "");
};
document.addEventListener("input", report); document.addEventListener("change", report);
</script></body></html>"""

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        body = PAGE.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        with open(sys.argv[1], "a") as log: log.write(f"POST {self.path} {data}\n")
        try:
            number = json.loads(data).get("card", "")
        except Exception:
            number = ""
        reply = json.dumps({"ok": True, "digits": len([c for c in number if c.isdigit()])}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(reply))); self.end_headers(); self.wfile.write(reply)

ThreadingHTTPServer(("127.0.0.1", 8781), Handler).serve_forever()
