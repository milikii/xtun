#!/usr/bin/env python3
"""Offline native-core transport checks in a disposable network namespace.

The product's generated server/client configs supply protocol identities and
XHTTP settings. Test adapters replace addresses/ports, add a private TLS trust
anchor and redirect the test's public destination to a local content server.
The product's private routing blocks remain present. No external CDN, GUI or
production configuration is involved. Private configs/logs are never printed.
"""

import argparse
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import socket
import shutil
import struct
import sys
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
CHUNK = bytes(range(256)) * 256


def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Processes:
    def __init__(self, directory):
        self.directory, self.items = directory, []

    def start(self, name, argv, env=None):
        log = (self.directory / (name + ".log")).open("wb")
        p = subprocess.Popen(argv, stdout=log, stderr=log, env=env)
        log.close()
        self.items.append(p)
        return p

    @staticmethod
    def stop(p):
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(3)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()

    def close(self):
        for p in reversed(self.items):
            self.stop(p)


def wait_port(number, process):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("core/adapter exited during startup")
        try:
            with socket.create_connection(("127.0.0.1", number), 0.1):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("core/adapter did not listen")


class Relay:
    def __init__(self, destination):
        self.destination = destination
        self.up = self.down = 0
        self.blocked = False
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        self.listener.listen()
        self.listener.settimeout(0.2)
        self.closed = False
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while not self.closed:
            try:
                client, _ = self.listener.accept()
            except (OSError, TimeoutError):
                continue
            if self.blocked:
                client.close()
                continue
            try:
                server = socket.create_connection(("127.0.0.1", self.destination), 3)
                server.settimeout(None)
            except OSError:
                client.close()
                continue
            threading.Thread(target=self.pipe, args=(client, server, "up"), daemon=True).start()
            threading.Thread(target=self.pipe, args=(server, client, "down"), daemon=True).start()

    def pipe(self, source, target, direction):
        try:
            while data := source.recv(65536):
                setattr(self, direction, getattr(self, direction) + len(data))
                target.sendall(data)
        except OSError:
            pass
        finally:
            for s in (source, target):
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                s.close()

    def counts(self):
        return self.up, self.down

    def close(self):
        self.closed = True
        self.listener.close()


def recv_exact(sock, length):
    data = b""
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise ConnectionError("SOCKS connection closed")
        data += part
    return data


def socks_http(socks_port, timeout=30):
    sock = socket.create_connection(("127.0.0.1", socks_port), timeout)
    sock.sendall(b"\x05\x01\x00")
    if recv_exact(sock, 2) != b"\x05\x00":
        sock.close()
        raise ConnectionError("SOCKS negotiation failed")
    sock.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("93.184.216.34") + struct.pack("!H", 80))
    reply = recv_exact(sock, 4)
    if reply[:2] != b"\x05\x00":
        sock.close()
        raise ConnectionError("SOCKS request rejected")
    recv_exact(sock, (4 if reply[3] == 1 else 16) + 2)
    conn = http.client.HTTPConnection("93.184.216.34", timeout=timeout)
    conn.sock = sock
    return conn


def run(args):
    directory = Path(args.workdir or tempfile.mkdtemp(prefix="xtun-native-"))
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    env = dict(os.environ, TEST_HOST_XRAY_BIN=str(Path(args.core).resolve()),
               TEST_HOST_XRAY_ASSET_DIR=str(Path(args.assets).resolve()),
               XRAY_LOCATION_ASSET=str(Path(args.assets).resolve()))
    subprocess.run(["bash", str(ROOT / "tests/native-fixture.sh"), str(directory)],
                   env=env, check=True, stdout=subprocess.DEVNULL)
    payload = CHUNK * ((args.bytes + len(CHUNK) - 1) // len(CHUNK))
    payload = payload[:args.bytes]
    payload_hash = hashlib.sha256(payload).hexdigest()
    observed = set()

    class Content(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_GET(self):
            observed.add(self.path)
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            try:
                self.wfile.write(payload)
            except OSError:
                pass

        def do_POST(self):
            length = int(self.headers["Content-Length"])
            received, digest = 0, hashlib.sha256()
            while received < length:
                part = self.rfile.read(min(length - received, 65536))
                if not part:
                    return
                received += len(part)
                digest.update(part)
            observed.add(self.path)
            result = json.dumps({"bytes": received, "sha256": digest.hexdigest(), "marker": self.path}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(result)))
            self.end_headers()
            self.wfile.write(result)

    httpd = http.server.ThreadingHTTPServer(("93.184.216.34", 0), Content)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    processes, relays = Processes(directory), []
    results = []
    try:
        cert, key = directory / "tls.pem", directory / "tls.key"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                        "-nodes", "-days", "2", "-subj", "/CN=cdn.example.com", "-addext",
                        "subjectAltName=DNS:cdn.example.com,DNS:www.example.com", "-keyout", str(key),
                        "-out", str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        reality_port, xhttp_port, fallback_port, target_port, cdn_port, ech_port = [port() for _ in range(6)]
        target_config = {"log": {"loglevel": "warning"}, "inbounds": [{"listen": "127.0.0.1", "port": target_port,
            "protocol": "dokodemo-door", "settings": {"address": "93.184.216.34", "port": httpd.server_port, "network": "tcp"},
            "streamSettings": {"network": "raw", "security": "tls", "tlsSettings": {"alpn": ["h2"],
                "certificates": [{"certificateFile": str(cert), "keyFile": str(key)}]}}}], "outbounds": [{"protocol": "freedom"}]}
        target_file = directory / "tls-target.json"
        target_file.write_text(json.dumps(target_config))
        target = processes.start("tls-target", [args.core, "run", "-config", str(target_file)], env)
        wait_port(target_port, target)
        ech = subprocess.check_output([args.core, "tls", "ech", "-serverName", "cdn.example.com"], text=True).splitlines()
        ech_config, ech_key = ech[1], ech[3]
        server = json.loads((directory / "xray/config.json").read_text())
        server["log"] = {"loglevel": "debug"}
        for inbound in server["inbounds"]:
            if inbound["tag"] == "reality-vision":
                inbound["port"] = reality_port
                inbound["settings"]["fallbacks"][0]["dest"] = xhttp_port
                inbound["streamSettings"]["realitySettings"]["target"] = f"127.0.0.1:{fallback_port}"
            elif inbound["tag"] == "reality-fallback":
                inbound["port"] = fallback_port
                inbound["settings"].update(address="127.0.0.1", port=target_port)
            else:
                inbound["port"] = xhttp_port
        # Native ECH is a separate single-layer reference. The five baseline
        # nodes use nginx -> the same XHTTP listener, so split sessions share it.
        ech_inbound = json.loads(json.dumps(next(i for i in server["inbounds"] if i["tag"] == "xhttp-cdn")))
        ech_inbound.update(tag="fixture-ech", port=ech_port)
        ech_inbound["streamSettings"].update(security="tls", tlsSettings={"alpn": ["h2"],
            "echServerKeys": ech_key, "certificates": [{"certificateFile": str(cert), "keyFile": str(key)}]})
        server["inbounds"].append(ech_inbound)
        for rule in server["routing"]["rules"]:
            if rule.get("inboundTag") == ["reality-fallback"] and rule["outboundTag"] == "direct":
                rule["outboundTag"] = "fixture-local"
        for outbound in server["outbounds"]:
            if outbound["tag"] == "direct":
                outbound["settings"] = {"redirect": f"93.184.216.34:{httpd.server_port}"}
        server["outbounds"].append({"tag": "fixture-local", "protocol": "freedom"})
        server_file = directory / "server.json"
        server_file.write_text(json.dumps(server))
        subprocess.run([args.core, "run", "-test", "-config", str(server_file)], env=env, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        core_server = processes.start("server", [args.core, "run", "-config", str(server_file)], env)
        wait_port(reality_port, core_server)
        nginx_file = directory / "nginx.conf"
        # A self-built nginx may name a user absent from this test host. The
        # disposable namespace's private adapter uses our existing root identity;
        # no host nginx service, user or configuration is changed.
        nginx_file.write_text(f'''user root;
worker_processes 1;
pid {directory}/nginx.pid;
error_log {directory}/nginx-error.log info;
events {{ worker_connections 1024; }}
http {{
 access_log off;
 client_body_temp_path {directory}/body;
 proxy_temp_path {directory}/proxy;
 fastcgi_temp_path {directory}/fastcgi;
 uwsgi_temp_path {directory}/uwsgi;
 scgi_temp_path {directory}/scgi;
 server {{
  listen 127.0.0.1:{cdn_port} ssl http2;
  server_name cdn.example.com;
  ssl_certificate {cert};
  ssl_certificate_key {key};
  ssl_protocols TLSv1.3;
  client_max_body_size 0;
  location /test-path {{
   grpc_pass grpc://127.0.0.1:{xhttp_port};
   grpc_read_timeout 60s;
   grpc_send_timeout 60s;
  }}
 }}
}}
''')
        nginx = shutil.which("nginx")
        if nginx is None:
            raise RuntimeError("native transport requires nginx with http_ssl/http_v2 modules")
        nginx_process = processes.start("nginx", [nginx, "-p", str(directory), "-c", str(nginx_file), "-g", "daemon off;"])
        wait_port(cdn_port, nginx_process)
        reality, cdn = Relay(reality_port), Relay(cdn_port)
        ech_relay = Relay(ech_port)
        relays = [reality, cdn, ech_relay]

        def client(number, ech_value=None, wrong=None):
            config = json.loads((directory / f"client-{number}.json").read_text())
            config["log"] = {"loglevel": "debug"}
            socks_port = port()
            config["inbounds"][0]["port"] = socks_port
            outbound = config["outbounds"][0]
            stream = outbound["streamSettings"]

            def adapt(s):
                if s["security"] == "tls":
                    s["tlsSettings"]["certificates"] = [{"certificateFile": str(cert), "usage": "verify"}]
                    s["tlsSettings"]["disableSystemRoot"] = True
                    if ech_value is not None:
                        s["tlsSettings"]["echConfigList"] = ech_value
                    return ech_relay.port if ech_value is not None else cdn.port
                return reality.port

            outbound["settings"]["vnext"][0].update(address="127.0.0.1", port=adapt(stream))
            if "downloadSettings" in stream.get("xhttpSettings", {}):
                down = stream["xhttpSettings"]["downloadSettings"]
                down.update(address="127.0.0.1", port=adapt(down))
            if wrong == "uuid":
                outbound["settings"]["vnext"][0]["users"][0]["id"] = str(uuid.uuid4())
            elif wrong == "short-id":
                stream["realitySettings"]["shortId"] = "ffffffffffffffff"
            elif wrong == "key":
                key_output = subprocess.check_output([args.core, "x25519"], text=True)
                stream["realitySettings"]["password"] = key_output.split("Password (PublicKey): ")[1].splitlines()[0]
            elif wrong == "path":
                stream["xhttpSettings"]["path"] = "/wrong-path"
            file = directory / f"client-run-{number}-{uuid.uuid4().hex}.json"
            file.write_text(json.dumps(config))
            p = processes.start(file.stem, [args.core, "run", "-config", str(file)], env)
            wait_port(socks_port, p)
            return p, socks_port

        def transfer(number, ech_value=None):
            p, socks = client(number, ech_value)
            marker = "/" + uuid.uuid4().hex
            before = [r.counts() for r in relays]
            try:
                conn = socks_http(socks)
                conn.request("GET", marker + "-download")
                response = conn.getresponse()
                data = response.read()
                assert response.status == 200 and len(data) == args.bytes and hashlib.sha256(data).hexdigest() == payload_hash
                conn.close()
                middle = [r.counts() for r in relays]
                conn = socks_http(socks)
                conn.request("POST", marker + "-upload", body=payload)
                response = conn.getresponse()
                result = json.loads(response.read())
                conn.close()
                assert result == {"bytes": args.bytes, "sha256": payload_hash, "marker": marker + "-upload"}
                assert marker + "-download" in observed and marker + "-upload" in observed
                after = [r.counts() for r in relays]
                if number in (4, 5):
                    down_index, up_index = ((0, 1) if number == 4 else (1, 0))
                    assert middle[down_index][1] - before[down_index][1] >= args.bytes
                    assert after[up_index][0] - middle[up_index][0] >= args.bytes
                    assert middle[up_index][1] - before[up_index][1] < args.bytes // 2
                result = {"node": number, "variant": "ech" if ech_value else "plain", "bytes_each_direction": args.bytes,
                          "sha256": payload_hash, "split_path_checked": number in (4, 5)}
                results.append(result)
                print(json.dumps(result), flush=True)
            finally:
                processes.stop(p)

        def reject(number, reason, ech_value=None, wrong=None, blocked=None):
            if blocked:
                blocked.blocked = True
            p, socks = client(number, ech_value, wrong)
            marker = "/negative-" + uuid.uuid4().hex
            conn = None
            try:
                try:
                    conn = socks_http(socks, 3)
                    conn.request("GET", marker)
                    response = conn.getresponse()
                    response.read(1)
                    raise AssertionError("negative case transmitted successfully: " + reason)
                except (OSError, http.client.HTTPException):
                    pass
                assert marker not in observed, "negative request reached content server"
                results.append({"node": number, "negative": reason, "rejected": True})
                print(json.dumps(results[-1]), flush=True)
            finally:
                if conn:
                    conn.close()
                processes.stop(p)
                if blocked:
                    blocked.blocked = False

        for number in range(1, 6):
            transfer(number)
        transfer(3, ech_config)
        for number, reason in [(1, "uuid"), (1, "short-id"), (1, "key"), (3, "uuid"), (3, "path")]:
            reject(number, reason, wrong=reason)
        reject(3, "invalid ECH must not fall back", ech_value="AQEEBQQF")
        reject(3, "unreachable ECH DNS must not fall back", ech_value=f"https://127.0.0.1:{port()}/dns-query")
        for number in (4, 5):
            reject(number, "REALITY path blocked", blocked=reality)
            reject(number, "CDN TLS path blocked", blocked=cdn)
        summary = {"core": subprocess.check_output([args.core, "version"], text=True).splitlines()[0],
                   "scope": "isolated network namespace; TLS adapter, private CA; no real CDN/GUI", "results": results}
        (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"PASS native transport: {len(results)} scenarios; summary={directory / 'summary.json'}", flush=True)
    finally:
        for relay in relays:
            relay.close()
        processes.close()
        httpd.shutdown()
        httpd.server_close()


if __name__ == "__main__":
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", default=os.environ.get("TEST_HOST_XRAY_BIN", "/usr/local/bin/xray"))
    parser.add_argument("--assets", default=os.environ.get("TEST_HOST_XRAY_ASSET_DIR", "/usr/local/share/xray"))
    parser.add_argument("--workdir")
    parser.add_argument("--bytes", type=int, default=64 * 1024 * 1024)
    parser.add_argument("--namespace-parent", help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.bytes < 1:
        parser.error("--bytes must be positive")
    namespace = os.readlink("/proc/self/ns/net")
    if arguments.namespace_parent is None:
        os.execvp("unshare", ["unshare", "--net", sys.executable, str(Path(__file__).resolve()),
                             *sys.argv[1:], "--namespace-parent", namespace])
    if namespace == arguments.namespace_parent:
        parser.error("refusing to configure the parent network namespace")
    subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
    # This address exists only in the disposable namespace. Public-address
    # routing/freedom protections remain enabled; no parent route is modified.
    subprocess.run(["ip", "addr", "add", "93.184.216.34/32", "dev", "lo"], check=True)
    run(arguments)
