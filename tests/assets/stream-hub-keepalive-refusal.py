#!/usr/bin/env python3
"""Refuse a POST that carries a body, then reuse the SAME connection.

Prints "clean" when the request after the refusal is answered correctly, and
the failure otherwise. This is the viewer's own shape: one kept-alive
connection, a send box refused for a viewing token, and the next poll for the
fleet listing on that same connection. A fresh connection per request cannot
reach the defect, which is why this is not curl.
"""

import http.client
import json
import sys

url_host, url_port, endpoint, token = sys.argv[1:5]
conn = http.client.HTTPConnection(url_host, int(url_port), timeout=15)

body = json.dumps({"text": "echo NEVER-TYPED", "submit": True})
conn.request("POST", "/v1/tasks/%s/input" % endpoint, body=body,
             headers={"Authorization": "Bearer " + token,
                      "Content-Type": "application/json"})
refusal = conn.getresponse()
refusal.read()
if refusal.status != 403:
    print("the send box should have been refused, got %d" % refusal.status)
    raise SystemExit(0)

try:
    conn.request("GET", "/v1/tasks", headers={"Authorization": "Bearer " + token})
    answer = conn.getresponse()
    payload = answer.read().decode("utf-8", "replace")
except Exception as exc:  # noqa: BLE001
    print("the request after a refusal failed: %r" % (exc,))
    raise SystemExit(0)

if answer.status != 200:
    print("the request after a refusal answered %d: %s" % (answer.status, payload[:200]))
elif not json.loads(payload).get("ok"):
    print("the request after a refusal answered a body that is not the listing: %s"
          % payload[:200])
else:
    print("clean")
