#!/usr/bin/env python3
"""Forward loopback HTTP and drop one selected response after upstream accepts it."""

import argparse
import http.client
import http.server
import json
import socketserver
import threading
import urllib.parse


class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: ARG002
        pass

    def do_GET(self) -> None:  # noqa: N802
        self._forward()

    def do_POST(self) -> None:  # noqa: N802
        self._forward()

    def do_DELETE(self) -> None:  # noqa: N802
        self._forward()

    def _forward(self) -> None:
        state = self.server.state
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        target = state["target"]
        connection = http.client.HTTPConnection(target.hostname, target.port, timeout=35)
        headers = {
            name: value for name, value in self.headers.items()
            if name.lower() not in {"host", "connection", "content-length"}
        }
        if body is not None:
            headers["Content-Length"] = str(len(body))
        try:
            connection.request(self.command, self.path, body=body, headers=headers)
            response = connection.getresponse()
            response_body = response.read()
            response_headers = response.getheaders()
        except OSError as exc:
            response_body = json.dumps({
                "ok": False,
                "error": "proxy_upstream_unreachable",
                "message": str(exc),
            }).encode("utf-8")
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            self.wfile.write(response_body)
            return
        finally:
            connection.close()

        path = self.path.split("?", 1)[0]
        drop = False
        if path == state["drop_path"]:
            with state["lock"]:
                state["matches"] += 1
                drop = state["matches"] == state["drop_number"]
        if drop:
            with open(state["dropped_file"], "w", encoding="utf-8") as handle:
                handle.write("%s %s\n" % (self.command, path))
            self.close_connection = True
            return

        self.send_response(response.status)
        for name, value in response_headers:
            if name.lower() not in {"connection", "content-length", "transfer-encoding"}:
                self.send_header(name, value)
        self.send_header("Content-Length", str(len(response_body)))
        self.end_headers()
        if response_body:
            self.wfile.write(response_body)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True)
    parser.add_argument("--drop-path", required=True)
    parser.add_argument("--drop-number", type=int, required=True)
    parser.add_argument("--dropped-file", required=True)
    parser.add_argument("--ready-file", required=True)
    options = parser.parse_args()
    target = urllib.parse.urlparse(options.target)
    if target.scheme != "http" or not target.hostname or not target.port:
        parser.error("--target must be an http URL with an explicit port")

    server = Server(("127.0.0.1", 0), Proxy)
    server.state = {
        "target": target,
        "drop_path": options.drop_path,
        "drop_number": options.drop_number,
        "dropped_file": options.dropped_file,
        "matches": 0,
        "lock": threading.Lock(),
    }
    host, port = server.server_address
    with open(options.ready_file, "w", encoding="utf-8") as handle:
        handle.write("%s %s\n" % (host, port))
    server.serve_forever(poll_interval=0.2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
