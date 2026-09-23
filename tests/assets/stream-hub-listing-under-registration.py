#!/usr/bin/env python3
"""Poll the fleet listings while new machines keep registering.

Prints "clean" when every listing answered, and the first failure otherwise.
The viewer polls /v1/tasks every few seconds and a mate on a machine the hub
has never seen can register at any moment, so the two genuinely overlap on a
threading server; a listing built by iterating the live registry raises instead
of answering, and the fleet view blanks out exactly when a worker joins.
"""

import json
import sys
import threading
import urllib.error
import urllib.request

url, publish_token, view_token = sys.argv[1:4]
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


def joiner(tag):
    n = 0
    while not stop.is_set():
        n += 1
        try:
            request("/v1/agent/endpoints", publish_token, "POST", {
                "endpoint_id": "%032x" % ((hash((tag, n)) & 0xFFFFFFFF) + n * 7919),
                "machine": "box-%s-%d" % (tag, n),
                "label": "joiner-%s-%d" % (tag, n),
                "cwd": "/tmp",
                "protocol": 3,
            })
        except urllib.error.HTTPError:
            continue
        except Exception as exc:  # noqa: BLE001
            failures.append("registering a machine failed: %r" % (exc,))
            return


def watcher(path):
    for _ in range(150):
        try:
            status, body = request(path, view_token)
        except urllib.error.HTTPError as exc:
            failures.append("%s answered %d: %s"
                            % (path, exc.code, exc.read().decode("utf-8", "replace")[:200]))
            return
        except Exception as exc:  # noqa: BLE001
            failures.append("%s failed: %r" % (path, exc))
            return
        payload = json.loads(body)
        if status != 200 or not payload.get("ok"):
            failures.append("%s answered %s: %s" % (path, status, body[:200]))
            return
        names = [m["machine"] for m in payload.get("machines", [])]
        if len(set(names)) != len(names):
            failures.append("%s listed a machine twice: %s" % (path, body[:200]))
            return


joiners = [threading.Thread(target=joiner, args=(tag,)) for tag in ("a", "b")]
watchers = [threading.Thread(target=watcher, args=(path,))
            for path in ("/v1/tasks", "/v1/machines", "/v1/tasks")]
for thread in joiners + watchers:
    thread.start()
for thread in watchers:
    thread.join()
stop.set()
for thread in joiners:
    thread.join()
print(failures[0] if failures else "clean")
