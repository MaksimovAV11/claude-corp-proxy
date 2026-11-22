#!/usr/bin/env python3
"""Claude Corp Proxy — local loopback bridge to a corporate HTTP proxy.

Claude Code talks to a plain proxy on 127.0.0.1; the bridge forwards every
request to the upstream corporate proxy and adds Proxy-Authorization when the
upstream URL carries credentials. Credentials never appear in the environment
of the Claude process, in `ps` output or in shell history.

Usage:
  bridge.py            run in the foreground
  bridge.py --ensure   start in the background if it is not running yet
  bridge.py --stop     stop the background bridge
  bridge.py --status   print whether the bridge is running
  bridge.py --check    test the upstream proxy: CONNECT api.anthropic.com:443
"""

import base64
import os
import select
import signal
import socket
import socketserver
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import unquote, urlsplit

CONFIG_FILE = Path(os.environ.get("CCP_CONFIG", Path.home() / ".config/claude-corp-proxy/config"))
STATE_DIR = Path(os.environ.get("CCP_STATE", Path.home() / ".cache/claude-corp-proxy"))
LOG_FILE = STATE_DIR / "bridge.log"
PID_FILE = STATE_DIR / "bridge.pid"
LISTEN_HOST = "127.0.0.1"
MAX_HEADER = 65536
CHECK_TARGET = ("api.anthropic.com", 443)


def read_config():
    values = {}
    if not CONFIG_FILE.exists():
        raise ValueError(f"config not found: {CONFIG_FILE} (run the installer again)")
    for raw in CONFIG_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def listen_port():
    try:
        return int(read_config().get("PORT", "10808"))
    except ValueError:
        return 10808


def upstream_settings():
    """(host, port, basic-auth or None) of the corporate proxy."""
    url = read_config().get("PROXY_URL", "")
    if not url:
        raise ValueError("PROXY_URL is empty in the config")
    if "://" not in url:
        url = "http://" + url
    parsed = urlsplit(url)
    if parsed.scheme != "http":
        raise ValueError("only http:// upstream proxies are supported")
    if not parsed.hostname or not parsed.port:
        raise ValueError("proxy URL must look like http://[user:pass@]host:port")
    auth = None
    if parsed.username is not None:
        userpass = f"{unquote(parsed.username)}:{unquote(parsed.password or '')}".encode()
        auth = base64.b64encode(userpass).decode("ascii")
    return parsed.hostname, parsed.port, auth


def recv_headers(sock):
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("connection closed before HTTP headers")
        data.extend(chunk)
        if len(data) > MAX_HEADER:
            raise ValueError("HTTP headers too large")
    end = data.index(b"\r\n\r\n") + 4
    return bytes(data[:end]), bytes(data[end:])


def relay(left, right, initial=b""):
    if initial:
        right.sendall(initial)
    peers = {left: right, right: left}
    while True:
        readable, _, _ = select.select((left, right), (), ())
        for source in readable:
            chunk = source.recv(65536)
            if not chunk:
                return
            peers[source].sendall(chunk)


class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        upstream = None
        try:
            request, client_tail = recv_headers(client)
            lines = request[:-4].split(b"\r\n")
            parts = lines[0].split(b" ", 2) if lines else []
            if len(parts) != 3:
                client.sendall(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
                return
            method, target, version = parts
            host, port, auth = upstream_settings()
            upstream = socket.create_connection((host, port), timeout=20)
            upstream.settimeout(None)

            headers = [h for h in lines[1:]
                       if h.split(b":", 1)[0].strip().lower()
                       not in (b"proxy-authorization", b"proxy-connection", b"connection")]
            if auth:
                headers.append(b"Proxy-Authorization: Basic " + auth.encode("ascii"))
            headers.append(b"Proxy-Connection: Keep-Alive")

            if method.upper() == b"CONNECT":
                upstream.sendall(b" ".join((method, target, version)) + b"\r\n"
                                 + b"\r\n".join(headers) + b"\r\n\r\n")
                response, upstream_tail = recv_headers(upstream)
                client.sendall(response)
                status = response.split(b"\r\n", 1)[0].split()
                if len(status) > 1 and status[1] == b"200":
                    if upstream_tail:
                        client.sendall(upstream_tail)
                    relay(client, upstream, client_tail)
                return

            headers.append(b"Connection: close")
            upstream.sendall(b" ".join((method, target, version)) + b"\r\n"
                             + b"\r\n".join(headers) + b"\r\n\r\n" + client_tail)
            while True:
                chunk = upstream.recv(65536)
                if not chunk:
                    break
                client.sendall(chunk)
        except (OSError, ValueError, ConnectionError) as exc:
            print(f"{time.strftime('%F %T')} request failed: {exc}", file=sys.stderr, flush=True)
            try:
                client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
            except OSError:
                pass
        finally:
            if upstream is not None:
                upstream.close()


class ThreadingProxy(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def is_listening(port):
    try:
        with socket.create_connection((LISTEN_HOST, port), timeout=0.3):
            return True
    except OSError:
        return False


def ensure_running():
    port = listen_port()
    if is_listening(port):
        return 0
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    with LOG_FILE.open("ab", buffering=0) as log:
        proc = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve())],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            start_new_session=True, close_fds=True,
        )
    PID_FILE.write_text(str(proc.pid))
    for _ in range(50):
        time.sleep(0.1)
        if is_listening(port):
            return 0
    print(f"claude-corp-proxy: bridge did not start, see {LOG_FILE}", file=sys.stderr)
    return 1


def stop():
    try:
        pid = int(PID_FILE.read_text().strip())
    except (OSError, ValueError):
        print("bridge is not running")
        return 0
    try:
        os.kill(pid, signal.SIGTERM)
        print(f"bridge stopped (pid {pid})")
    except ProcessLookupError:
        print("bridge is not running")
    PID_FILE.unlink(missing_ok=True)
    return 0


def status():
    port = listen_port()
    running = is_listening(port)
    try:
        host, uport, auth = upstream_settings()
        upstream = f"{host}:{uport} ({'with' if auth else 'no'} auth)"
    except ValueError as exc:
        upstream = f"invalid: {exc}"
    print(f"bridge:   {'running' if running else 'stopped'} on {LISTEN_HOST}:{port}")
    print(f"upstream: {upstream}")
    print(f"config:   {CONFIG_FILE}")
    print(f"log:      {LOG_FILE}")
    return 0 if running else 3


def check():
    """CONNECT to api.anthropic.com:443 through the upstream proxy."""
    try:
        host, port, auth = upstream_settings()
    except ValueError as exc:
        print(f"config error: {exc}")
        return 2
    target = f"{CHECK_TARGET[0]}:{CHECK_TARGET[1]}".encode()
    request = b"CONNECT " + target + b" HTTP/1.1\r\nHost: " + target + b"\r\n"
    if auth:
        request += b"Proxy-Authorization: Basic " + auth.encode("ascii") + b"\r\n"
    request += b"\r\n"
    started = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=15) as sock:
            sock.settimeout(15)
            sock.sendall(request)
            response, _ = recv_headers(sock)
    except (OSError, ValueError, ConnectionError) as exc:
        print(f"proxy unreachable: {exc}")
        return 1
    line = response.split(b"\r\n", 1)[0].decode("latin-1")
    took = int((time.monotonic() - started) * 1000)
    code = line.split()[1] if len(line.split()) > 1 else "?"
    if code == "200":
        print(f"ok: {CHECK_TARGET[0]} reachable through the proxy ({took} ms)")
        return 0
    if code == "407":
        print("proxy rejected the credentials (407 Proxy Authentication Required)")
    else:
        print(f"proxy answered: {line}")
    return 1


def main():
    commands = {"--ensure": ensure_running, "--stop": stop, "--status": status, "--check": check}
    if len(sys.argv) == 2 and sys.argv[1] in commands:
        return commands[sys.argv[1]]()
    try:
        upstream_settings()
        with ThreadingProxy((LISTEN_HOST, listen_port()), ProxyHandler) as server:
            server.serve_forever()
    except Exception as exc:  # noqa: BLE001 — a bridge must report, not crash silently
        print(f"claude-corp-proxy bridge: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
