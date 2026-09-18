import socket, threading
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 0)); s.listen(20)
print(s.getsockname()[1], flush=True)
def handle(c):
    req = c.recv(4096).decode(errors="replace")
    if "/v1/health" in req:
        body = b'{"ok":true,"protocol":2}'
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
    else:  # promise 1000 bytes, send a few, hang up
        c.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n{"tasks": [')
    c.close()
while True:
    c, _ = s.accept(); threading.Thread(target=handle, args=(c,), daemon=True).start()
