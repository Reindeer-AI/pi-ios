#!/usr/bin/env python3
"""A local MCP server with OAuth, for testing pi's MCP servers in the simulator (which shares the Mac's loopback).

    tools/mcp-mock/server.py [--port 8765]
    tools/mcp-mock/server.py --port 8766 --client-id ID --client-secret SECRET --redirect URL [--redirect URL ...]

The second form is a server without dynamic client registration (as Slack's and HubSpot's): one pre-registered client,
its secret checked at the token endpoint, and only the listed redirect URLs.

Streamable HTTP at http://127.0.0.1:PORT/mcp behind a bearer token, with what an MCP client needs to get one:
protected-resource and authorization-server metadata, dynamic client registration, an authorization page that approves
itself after a moment, and PKCE-checked tokens (refreshable, an hour long). Tools: get_secret_number, echo.

Registered clients are kept in .mcp-mock-clients.json next to this script, so they outlive a restart, as a real
server's do. POST /admin/expire ends every MCP session (the next request gets 404, as when a server forgets a session); POST
/admin/revoke also drops the tokens. Requests are logged to stdout.
"""

import argparse
import base64
import hashlib
import json
import secrets
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import os
CLIENTS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".mcp-mock-clients.json")
try:
    with open(CLIENTS_FILE) as f:
        clients: dict[str, dict] = json.load(f)
except (OSError, ValueError):
    clients = {}


def save_clients():
    with open(CLIENTS_FILE, "w") as f:
        json.dump(clients, f)



codes: dict[str, dict] = {}
tokens: dict[str, float] = {}
refresh_tokens: dict[str, str] = {}
sessions: set[str] = set()

PRESET: dict | None = None  # the pre-registered client, without dynamic registration

TOOLS = [
    {"name": "get_secret_number", "description": "Returns the secret number (only for a signed-in client).",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "echo", "description": "Echoes the text back.",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"{time.strftime('%H:%M:%S')} {self.command} {self.path.split('?')[0]} {fmt % args}", flush=True)

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.server.server_port}"

    def send(self, status: int, body: bytes | str | dict = b"", content_type="application/json", headers: dict | None = None):
        if isinstance(body, dict):
            body = json.dumps(body)
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def body(self) -> bytes:
        return self.rfile.read(int(self.headers.get("Content-Length") or 0))

    # ---- OAuth ----

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        if url.path.startswith("/.well-known/oauth-protected-resource"):
            return self.send(200, {"resource": f"{self.base}/mcp", "authorization_servers": [self.base]})
        if url.path.startswith("/.well-known/oauth-authorization-server") or url.path.startswith("/.well-known/openid-configuration"):
            return self.send(200, {
                "issuer": self.base,
                "authorization_endpoint": f"{self.base}/authorize",
                "token_endpoint": f"{self.base}/token",
                **({} if PRESET else {"registration_endpoint": f"{self.base}/register"}),
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["client_secret_post", "client_secret_basic"] if PRESET else ["none"],
                # As Fireflies does: the authorization response carries iss, which the client must check (RFC 9207).
                "authorization_response_iss_parameter_supported": True,
            })
        if url.path == "/authorize":
            client = PRESET if PRESET and query.get("client_id") == PRESET["client_id"] else (None if PRESET else clients.get(query.get("client_id", "")))
            if not client or query.get("redirect_uri") not in client["redirect_uris"]:
                return self.send(400, "unknown client or redirect_uri", "text/plain")
            print(f"  authorize: client {query.get('client_id')}, redirect {query.get('redirect_uri')}, scope {query.get('scope')!r}", flush=True)
            code = secrets.token_urlsafe(16)
            codes[code] = {"challenge": query.get("code_challenge"), "client": query["client_id"], "redirect": query["redirect_uri"]}
            target = query["redirect_uri"] + "?" + urllib.parse.urlencode({"code": code, "state": query.get("state", ""), "iss": self.base})
            page = f"""<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<body style="font:17px -apple-system;padding:40px 24px;text-align:center">
<h2>Mock MCP</h2><p><b>{client.get('client_name', 'A client')}</b> wants to use your tools.</p>
<p id="s">Approving…</p><a id="allow" href="{target}" style="display:inline-block;margin-top:16px;padding:12px 28px;background:#0a84ff;color:#fff;border-radius:12px;text-decoration:none">Allow</a>
<script>setTimeout(() => location.href = document.getElementById("allow").href, 1500)</script></body>"""
            return self.send(200, page, "text/html; charset=utf-8")
        if url.path == "/mcp":
            return self.send(405, b"", headers={"Allow": "POST, DELETE"})
        self.send(404, {"error": "not found"})

    def do_DELETE(self):
        self.body()
        sessions.discard(self.headers.get("Mcp-Session-Id", ""))
        self.send(200)

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        # Read whatever the request carries first, so an early answer leaves the kept-alive connection clean.
        self.payload = self.body()
        if url.path == "/register" and PRESET:
            return self.send(404, {"error": "registration not supported"})
        if url.path == "/register":
            metadata = json.loads(self.payload or b"{}")
            client_id = "client-" + secrets.token_hex(6)
            clients[client_id] = {**metadata, "client_id": client_id}
            save_clients()
            return self.send(201, {**metadata, "client_id": client_id, "client_id_issued_at": int(time.time()), "token_endpoint_auth_method": "none"})
        if url.path == "/token":
            form = dict(urllib.parse.parse_qsl(self.payload.decode()))
            if PRESET:
                basic = self.headers.get("Authorization", "")
                if basic.startswith("Basic "):
                    form.setdefault("client_id", urllib.parse.unquote(base64.b64decode(basic[6:]).decode().split(":", 1)[0]))
                    form.setdefault("client_secret", urllib.parse.unquote(base64.b64decode(basic[6:]).decode().split(":", 1)[1]))
                if form.get("client_id") != PRESET["client_id"] or form.get("client_secret") != PRESET["client_secret"]:
                    return self.send(401, {"error": "invalid_client"})
            if form.get("grant_type") == "authorization_code":
                grant = codes.pop(form.get("code", ""), None)
                if not grant:
                    return self.send(400, {"error": "invalid_grant"})
                verifier = form.get("code_verifier", "")
                challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
                if challenge != grant["challenge"]:
                    return self.send(400, {"error": "invalid_grant", "error_description": "PKCE check failed"})
            elif form.get("grant_type") == "refresh_token":
                if form.get("refresh_token") not in refresh_tokens:
                    return self.send(400, {"error": "invalid_grant"})
            else:
                return self.send(400, {"error": "unsupported_grant_type"})
            access, refresh = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
            tokens[access] = time.time() + 3600
            refresh_tokens[refresh] = access
            return self.send(200, {"access_token": access, "token_type": "Bearer", "expires_in": 3600, "refresh_token": refresh})
        if url.path == "/admin/expire":
            sessions.clear()
            return self.send(200, {"expired": True})
        if url.path == "/admin/revoke":
            sessions.clear()
            tokens.clear()
            refresh_tokens.clear()
            return self.send(200, {"revoked": True})
        if url.path == "/mcp":
            return self.mcp()
        self.send(404, {"error": "not found"})

    # ---- MCP ----

    def mcp(self):
        auth = self.headers.get("Authorization", "")
        token = auth.removeprefix("Bearer ").strip()
        if tokens.get(token, 0) < time.time():
            return self.send(401, {"error": "unauthorized"}, headers={
                "WWW-Authenticate": f'Bearer resource_metadata="{self.base}/.well-known/oauth-protected-resource"'})
        message = json.loads(self.payload or b"{}")
        method, request_id = message.get("method"), message.get("id")
        session = self.headers.get("Mcp-Session-Id")
        if method == "initialize":
            session = secrets.token_hex(8)
            sessions.add(session)
            return self.send(200, {"jsonrpc": "2.0", "id": request_id, "result": {
                "protocolVersion": message.get("params", {}).get("protocolVersion", "2025-06-18"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "mock", "version": "1.0"},
                "instructions": "A mock server for testing: a secret number and an echo.",
            }}, headers={"Mcp-Session-Id": session})
        if session not in sessions:
            return self.send(404, {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32001, "message": "Session not found"}})
        if request_id is None:
            return self.send(202)
        if method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            params = message.get("params", {})
            name, args = params.get("name"), params.get("arguments") or {}
            if name == "get_secret_number":
                result = {"content": [{"type": "text", "text": "The secret number is 4217."}]}
            elif name == "echo":
                result = {"content": [{"type": "text", "text": str(args.get("text", ""))}]}
            else:
                result = {"content": [{"type": "text", "text": f"No tool {name}"}], "isError": True}
        else:
            return self.send(200, {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": f"Unknown method {method}"}})
        self.send(200, {"jsonrpc": "2.0", "id": request_id, "result": result})


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--client-id")
    parser.add_argument("--client-secret")
    parser.add_argument("--redirect", action="append", default=[])
    options = parser.parse_args()
    port = options.port
    if options.client_id:
        PRESET = {"client_id": options.client_id, "client_secret": options.client_secret or "", "redirect_uris": options.redirect, "client_name": "a pre-registered app"}
        print(f"pre-registered client {options.client_id}; redirects {options.redirect}", flush=True)
    print(f"mock MCP server on http://127.0.0.1:{port}/mcp", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
