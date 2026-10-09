#!/usr/bin/env python3
"""A local mTLS test bed for pi's extension keys (pi.keys), for the simulator (which shares the Mac's loopback).

    python -m venv venv && venv/bin/pip install cryptography
    venv/bin/python tools/mtls-test/server.py [--dir DIR] [--issue-port 8770] [--tls-port 8771]

On first run it creates, in DIR (default: .mtls-test next to this script, git-ignored), a test CA and a server
certificate for 127.0.0.1 and localhost, signed by it. Trust the CA in the simulator once:

    xcrun simctl keychain booted add-root-cert DIR/ca.pem

- http://127.0.0.1:ISSUE/issue (POST { "publicKey": SPKI DER base64 }) → { "certificate": PEM }: a client certificate
  for that key from the test CA, valid for a day (as an enrollment would issue).
- http://127.0.0.1:ISSUE/redirect: a 302 to /target, for fetch's redirect modes.
- https://127.0.0.1:TLS/whoami: requires a client certificate from the test CA; answers its subject, its SHA-256
  fingerprint, and the SHA-256 of its public key.
"""

import argparse
import base64
import datetime
import hashlib
import ipaddress
import json
import os
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


def name(common: str) -> x509.Name:
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common)])


def setup(directory: str):
    os.makedirs(directory, exist_ok=True)
    paths = {k: os.path.join(directory, f) for k, f in [("ca", "ca.pem"), ("ca_key", "ca.key"), ("cert", "server.pem"), ("key", "server.key")]}
    if all(os.path.exists(p) for p in paths.values()):
        ca = x509.load_pem_x509_certificate(open(paths["ca"], "rb").read())
        ca_key = serialization.load_pem_private_key(open(paths["ca_key"], "rb").read(), None)
        return paths, ca, ca_key
    now = datetime.datetime.now(datetime.timezone.utc)
    ca_key = ec.generate_private_key(ec.SECP256R1())
    ca = (
        x509.CertificateBuilder().subject_name(name("pi mTLS test CA")).issuer_name(name("pi mTLS test CA"))
        .public_key(ca_key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5)).not_valid_after(now + datetime.timedelta(days=365))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(x509.KeyUsage(digital_signature=True, key_cert_sign=True, crl_sign=True, content_commitment=False, key_encipherment=False, data_encipherment=False, key_agreement=False, encipher_only=False, decipher_only=False), critical=True)
        .sign(ca_key, hashes.SHA256())
    )
    server_key = ec.generate_private_key(ec.SECP256R1())
    server = (
        x509.CertificateBuilder().subject_name(name("127.0.0.1")).issuer_name(ca.subject)
        .public_key(server_key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5)).not_valid_after(now + datetime.timedelta(days=300))
        .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address("127.0.0.1")), x509.DNSName("localhost")]), critical=False)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .sign(ca_key, hashes.SHA256())
    )
    open(paths["ca"], "wb").write(ca.public_bytes(serialization.Encoding.PEM))
    open(paths["ca_key"], "wb").write(ca_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    open(paths["cert"], "wb").write(server.public_bytes(serialization.Encoding.PEM) + ca.public_bytes(serialization.Encoding.PEM))
    open(paths["key"], "wb").write(server_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    return paths, ca, ca_key


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".mtls-test"))
    parser.add_argument("--issue-port", type=int, default=8770)
    parser.add_argument("--tls-port", type=int, default=8771)
    options = parser.parse_args()
    paths, ca, ca_key = setup(options.dir)

    class Issue(BaseHTTPRequestHandler):
        def do_GET(self):
            # A redirect, for checking fetch's redirect modes.
            if self.path == "/redirect":
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{options.issue_port}/target")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if self.path == "/target":
                return self.reply(200, {"reached": "target"})
            self.reply(404, {"error": "not found"})

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            try:
                public_key = serialization.load_der_public_key(base64.b64decode(body["publicKey"]))
            except Exception as error:  # noqa: BLE001
                return self.reply(400, {"error": f"bad publicKey: {error}"})
            now = datetime.datetime.now(datetime.timezone.utc)
            cert = (
                x509.CertificateBuilder().subject_name(name(body.get("subject", "pi test client"))).issuer_name(ca.subject)
                .public_key(public_key).serial_number(x509.random_serial_number())
                .not_valid_before(now - datetime.timedelta(minutes=5)).not_valid_after(now + datetime.timedelta(days=1))
                .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH]), critical=False)
                .sign(ca_key, hashes.SHA256())
            )
            print(f"issued a client certificate for key {hashlib.sha256(base64.b64decode(body['publicKey'])).hexdigest()[:16]}", flush=True)
            self.reply(200, {"certificate": cert.public_bytes(serialization.Encoding.PEM).decode()})

        def reply(self, status, payload):
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    class WhoAmI(Issue):
        def do_GET(self):
            der = self.connection.getpeercert(binary_form=True)
            cert = x509.load_der_x509_certificate(der)
            spki = cert.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
            print(f"mTLS request from {cert.subject.rfc4514_string()}", flush=True)
            self.reply(200, {"subject": cert.subject.rfc4514_string(), "fingerprint": hashlib.sha256(der).hexdigest(), "publicKeySha256": hashlib.sha256(spki).hexdigest()})

    issue = ThreadingHTTPServer(("127.0.0.1", options.issue_port), Issue)
    tls = ThreadingHTTPServer(("127.0.0.1", options.tls_port), WhoAmI)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(paths["cert"], paths["key"])
    context.load_verify_locations(paths["ca"])
    context.verify_mode = ssl.CERT_REQUIRED
    tls.socket = context.wrap_socket(tls.socket, server_side=True)
    threading.Thread(target=issue.serve_forever, daemon=True).start()
    print(f"issuer http://127.0.0.1:{options.issue_port}/issue · mTLS https://127.0.0.1:{options.tls_port}/whoami · CA {paths['ca']}", flush=True)
    tls.serve_forever()


if __name__ == "__main__":
    main()
