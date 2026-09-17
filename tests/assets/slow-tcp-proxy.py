#!/usr/bin/env python3
"""A TCP forwarder that stalls before connecting, standing in for a slow link.

Usage: slow-tcp-proxy.py <listen-host> <target-host> <target-port> <delay-secs>
Prints "<host> <port>" once listening. Every accepted connection waits
<delay-secs> before it is forwarded, which is how a hub that answers eventually
but not promptly looks from an agent's side.
"""

import socket
import socketserver
import sys
import threading
import time

listen_host, target_host, target_port, delay = sys.argv[1:5]
target = (target_host, int(target_port))
delay = float(delay)


def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        time.sleep(delay)
        try:
            upstream = socket.create_connection(target, timeout=30)
        except OSError:
            return
        with upstream:
            back = threading.Thread(target=pump, args=(upstream, self.request), daemon=True)
            back.start()
            pump(self.request, upstream)
            back.join(timeout=30)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


server = Server((listen_host, 0), Handler)
print("%s %d" % server.server_address[:2], flush=True)
server.serve_forever()
