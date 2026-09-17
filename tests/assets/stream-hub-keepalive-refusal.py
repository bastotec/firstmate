#!/usr/bin/env python3
"""Refuse a POST that carries a body, then reuse the SAME connection.

Prints "clean" when the request after each refusal is answered correctly, and
the first failure otherwise. This is the viewer's own shape: one kept-alive
connection, a POST refused, and the next poll for the fleet listing on that
same connection. A fresh connection per request cannot reach the defect, which
is why this is not curl.

Two refusals are covered, because they refuse at different points: the token
class is checked before the body is read at all, and the size limit is checked
after the length is parsed but still before any byte is read.
"""

import http.client
import json
import sys

host, port, endpoint, view_token, control_token = sys.argv[1:6]
MAX_BODY = 4 * 1024 * 1024


def listing_after(conn, token, what):
    """The answer to a normal request issued after a refusal, on the same conn."""
    try:
        conn.request("GET", "/v1/tasks", headers={"Authorization": "Bearer " + token})
        answer = conn.getresponse()
        payload = answer.read().decode("utf-8", "replace")
    except Exception as exc:  # noqa: BLE001
        return "the request after %s failed: %r" % (what, exc)
    if answer.status != 200:
        return "the request after %s answered %d: %s" % (what, answer.status, payload[:200])
    if not json.loads(payload).get("ok"):
        return "the request after %s did not answer the listing: %s" % (what, payload[:200])
    return ""


def refused_send_box():
    """A viewing token's send box: refused on class, before the body is read."""
    conn = http.client.HTTPConnection(host, int(port), timeout=15)
    body = json.dumps({"text": "echo NEVER-TYPED", "submit": True})
    conn.request("POST", "/v1/tasks/%s/input" % endpoint, body=body,
                 headers={"Authorization": "Bearer " + view_token,
                          "Content-Type": "application/json"})
    refusal = conn.getresponse()
    refusal.read()
    if refusal.status != 403:
        return "the send box should have been refused, got %d" % refusal.status
    return listing_after(conn, view_token, "a refused send box")


def refused_oversized_body():
    """A body over the hub's limit: refused after the length, before any read."""
    conn = http.client.HTTPConnection(host, int(port), timeout=15)
    conn.putrequest("POST", "/v1/tasks/%s/input" % endpoint)
    conn.putheader("Authorization", "Bearer " + control_token)
    conn.putheader("Content-Type", "application/json")
    # Declared over the limit so the hub refuses without reading, while only a
    # few bytes actually go out - the whole body would never fit in the socket
    # buffers of a server that is not reading it.
    conn.putheader("Content-Length", str(MAX_BODY + 1))
    conn.endheaders()
    conn.send(b'{"text":"x"}')
    refusal = conn.getresponse()
    refusal.read()
    if refusal.status != 413:
        return "an oversized body should have been refused, got %d" % refusal.status
    return listing_after(conn, control_token, "a refused oversized body")


def refused_viewer_post():
    """A POST to the viewer path: refused before any route reads a body."""
    conn = http.client.HTTPConnection(host, int(port), timeout=15)
    conn.request("POST", "/ui", body=json.dumps({"text": "x"}),
                 headers={"Content-Type": "application/json"})
    refusal = conn.getresponse()
    page = refusal.read().decode("utf-8", "replace")
    if refusal.status == 200:
        return "a POST to the viewer path was answered with the page"
    return listing_after(conn, view_token, "a refused POST to the viewer path") or (
        "a refused viewer POST answered the page" if "EventSource" in page else "")


for check in (refused_send_box, refused_oversized_body, refused_viewer_post):
    failure = check()
    if failure:
        print(failure)
        break
else:
    print("clean")
