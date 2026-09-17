#!/usr/bin/env python3
"""Drive concurrent capture reads against a live hub while frames arrive.

Prints "clean" when every capture answered 200 with a coherent screen, and the
first failure otherwise. Used by tests/fm-stream-hub.test.sh, which cannot
express real publish/read overlap from a shell loop.

Every published line repeats its own row number three times, and the numbers
run consecutively. A capture is coherent exactly when each line agrees with
itself and the lines run in sequence: a render that walks the screen while the
worker is still writing into it returns a row built from two different lines,
and one that reads the scrollback and the screen in two different states drops
the row that moved between them.
"""

import base64
import json
import sys
import threading
import urllib.error
import urllib.request

url, endpoint, publish_token, view_token = sys.argv[1:5]
stop = threading.Event()
failures = []


def request(path, token, method="GET", body=None):
    req = urllib.request.Request(url + path, method=method,
                                 data=json.dumps(body).encode() if body else None)
    req.add_header("Authorization", "Bearer " + token)
    if body:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status, resp.read().decode("utf-8", "replace")


def publisher():
    # Each POST rewrites the whole screen many times over, so the worker is
    # still writing into the rows a concurrent capture is rendering.
    n = 0
    while not stop.is_set():
        chunk = "".join("row-%08d-%08d-%08d\r\n" % ((n + i,) * 3) for i in range(400))
        n += 400
        try:
            request("/v1/agent/frames", publish_token, "POST", {
                "machine": "box-a",
                "frames": [{"endpoint_id": endpoint,
                            "b64": base64.b64encode(chunk.encode()).decode()}],
            })
        except Exception as exc:  # noqa: BLE001
            failures.append("publish failed: %r" % (exc,))
            return


def reader():
    for _ in range(200):
        try:
            status, body = request("/v1/tasks/%s/capture?lines=40" % endpoint, view_token)
        except urllib.error.HTTPError as exc:
            failures.append("capture answered %d: %s"
                            % (exc.code, exc.read().decode("utf-8", "replace")[:200]))
            return
        except Exception as exc:  # noqa: BLE001
            failures.append("capture failed: %r" % (exc,))
            return
        if status != 200 or not body.endswith("\n"):
            failures.append("capture answered %s with %r" % (status, body[:120]))
            return
        rows = []
        for line in body.split("\n"):
            if not line.startswith("row-"):
                continue
            fields = line[4:].split("-")
            if len(fields) != 3 or len(set(fields)) != 1:
                failures.append("capture returned a torn row: %r" % (line,))
                return
            rows.append(int(fields[0]))
        for previous, current in zip(rows, rows[1:]):
            if current != previous + 1:
                failures.append("capture returned a torn screen: row %d is followed by "
                                "row %d" % (previous, current))
                return


publisher_thread = threading.Thread(target=publisher)
readers = [threading.Thread(target=reader) for _ in range(6)]
publisher_thread.start()
for thread in readers:
    thread.start()
for thread in readers:
    thread.join()
stop.set()
publisher_thread.join()
print(failures[0] if failures else "clean")
