#!/usr/bin/env python3
import json
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request


def call(url, token, method, path, payload=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {"Authorization": "Bearer " + token}
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            body = response.read().decode("utf-8")
            return response.status, json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8")
        return exc.code, json.loads(body) if body else {}


def main():
    url, publish_token, control_token = sys.argv[1:4]
    endpoint = "d" * 32
    status, body = call(url, publish_token, "POST", "/v1/agent/endpoints", {
        "endpoint_id": endpoint,
        "machine": "result-journal",
        "label": "worker",
        "cwd": "/tmp",
        "capabilities": ["idempotent_command_results"],
    })
    if status != 201:
        raise SystemExit("registration failed: %s %r" % (status, body))

    first_result = None
    for number in range(513):
        placed = {}

        def place():
            placed["answer"] = call(
                url, control_token, "POST", "/v1/tasks/%s/status" % endpoint,
                {"state": "working", "note": "result %d" % number})

        thread = threading.Thread(target=place)
        thread.start()
        query = urllib.parse.urlencode({
            "machine": "result-journal", "endpoint": endpoint, "wait": 2})
        command_status, commands = call(
            url, publish_token, "GET", "/v1/agent/commands?" + query)
        rows = commands.get("commands") or []
        if command_status != 200 or len(rows) != 1:
            raise SystemExit("command %d was not delivered: %s %r"
                             % (number, command_status, commands))
        result = {
            "machine": "result-journal",
            "command_id": rows[0]["command_id"],
            "ok": True,
            "error": "",
        }
        result_status, result_body = call(
            url, publish_token, "POST", "/v1/agent/results", result)
        if result_status != 200:
            raise SystemExit("result %d failed: %s %r"
                             % (number, result_status, result_body))
        thread.join(10)
        if thread.is_alive() or placed.get("answer", (0,))[0] != 200:
            raise SystemExit("status command %d did not settle: %r"
                             % (number, placed.get("answer")))
        if number == 0:
            first_result = result

    retry_status, retry_body = call(
        url, publish_token, "POST", "/v1/agent/results", first_result)
    print(json.dumps({"retry_status": retry_status, "retry_body": retry_body,
                      "completed": 513}, separators=(",", ":")))


if __name__ == "__main__":
    main()
