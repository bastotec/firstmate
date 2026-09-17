#!/usr/bin/env python3
"""A TCP forwarder that stalls before connecting, standing in for a slow link.

Usage: slow-tcp-proxy.py <listen-host> <target-host> <target-port> <delay-secs>
                         [stall-connection]
Prints "<host> <port>" once listening. Accepted connections wait <delay-secs>
before they are forwarded, which is how a hub that answers eventually but not
promptly looks from a client's side. With <stall-connection> given, only that
one connection (counted from 1) is stalled and every other is forwarded at
once - a hub that is prompt until one particular call.
"""

import itertools
import socket
import socketserver
import sys
import threading
import time

listen_host, target_host, target_port, delay = sys.argv[1:5]
target = (target_host, int(target_port))
delay = float(delay)
stall_connection = int(sys.argv[5]) if len(sys.argv) > 5 else 0
accepted = itertools.count(1)


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
        if not stall_connection or next(accepted) == stall_connection:
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
