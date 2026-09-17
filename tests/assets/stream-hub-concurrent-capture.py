#!/usr/bin/env python3
"""Drive concurrent capture reads against a live hub while frames arrive.

Prints "clean" when every capture answered 200 with a well-formed body, and
the first failure otherwise. Used by tests/fm-stream-hub.test.sh, which cannot
express real overlap from a shell loop.
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
    # The endpoint has four screen rows, so every published line scrolls one
    # row into the scrollback deque the capture read is iterating.
    n = 0
    while not stop.is_set():
        n += 1
        chunk = "".join("row-%d-%d\r\n" % (n, i) for i in range(20))
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
    for _ in range(150):
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
        # Every published line is unique, so one line appearing twice means the
        # render read the scrollback and the screen in two different states.
        lines = [line for line in body.split("\n") if line]
        if len(set(lines)) != len(lines):
            failures.append("capture returned a torn screen: %r" % (body[:200],))
            return


publishers = [threading.Thread(target=publisher) for _ in range(2)]
readers = [threading.Thread(target=reader) for _ in range(3)]
for thread in publishers + readers:
    thread.start()
for thread in readers:
    thread.join()
stop.set()
for thread in publishers:
    thread.join()
print(failures[0] if failures else "clean")
