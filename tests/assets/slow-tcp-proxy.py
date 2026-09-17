#!/usr/bin/env python3
"""A TCP forwarder that stalls before connecting, standing in for a slow link.

Usage: slow-tcp-proxy.py <listen-host> <target-host> <target-port> <delay-secs>
                         [stall-connection]
Prints "<host> <port>" once listening. Accepted connections wait <delay-secs>
before they are forwarded, which is how a hub that answers eventually but not
promptly looks from a client's side. <stall-connection> narrows which ones are
stalled, counting accepted connections from 1: "3" stalls only the third - a
hub that is prompt until one particular call - and "3+" stalls the third and
everything after it, a hub that goes slow and stays slow. A delay of 0 drops
the named connection instead of stalling it, which is how a hub that closes
one connection outright looks from a client's side.
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
stall_spec = sys.argv[5] if len(sys.argv) > 5 else ""
stall_onwards = stall_spec.endswith("+")
stall_connection = int(stall_spec.rstrip("+")) if stall_spec else 0
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
        index = next(accepted)
        if (not stall_connection
                or index == stall_connection
                or (stall_onwards and index > stall_connection)):
            if delay <= 0:
                return
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
