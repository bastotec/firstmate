#!/usr/bin/env python3
import json
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


def call(url, token, method, path, payload=None, capability=""):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {"Authorization": "Bearer " + token}
    if capability:
        headers["X-Endpoint-Capability"] = capability
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
    count = int(sys.argv[4]) if len(sys.argv) > 4 else 513
    pause_before_second = float(sys.argv[5]) if len(sys.argv) > 5 else 0.0
    endpoint = "d" * 32
    status, body = call(url, publish_token, "POST", "/v1/agent/endpoints", {
        "endpoint_id": endpoint,
        "machine": "result-journal",
        "label": "worker",
        "cwd": "/tmp",
        "capabilities": ["idempotent_command_results"],
        "protocol": 3,
    })
    if status != 201:
        raise SystemExit("registration failed: %s %r" % (status, body))

    capability = body["command_capability"]
    first_result = None
    for number in range(count):
        if number == 1 and pause_before_second > 0:
            time.sleep(pause_before_second)
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
            url, publish_token, "GET", "/v1/agent/commands?" + query, capability=capability)
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
            url, publish_token, "POST", "/v1/agent/results", result, capability)
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
        url, publish_token, "POST", "/v1/agent/results", first_result, capability)
    print(json.dumps({"retry_status": retry_status, "retry_body": retry_body,
                      "completed": count}, separators=(",", ":")))


if __name__ == "__main__":
    main()
