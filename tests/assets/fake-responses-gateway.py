#!/usr/bin/env python3
"""A one-tool fake of the OpenAI Responses gateway Deck talks to, for tests.

Usage: fake-responses-gateway.py <port-file> <log-file> <tool-args-json>

Each POST .../responses gets one streamed reply: while the request carries no
function_call_output it asks for run_command with <tool-args-json>; once it does,
it answers with plain text quoting the start of that output. Every request body
is appended to <log-file>, one JSON line each. The chosen port is written to
<port-file>. Runs until killed.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_FILE, LOG, TOOL_ARGS = sys.argv[1], sys.argv[2], sys.argv[3]


def frame(value):
    return f'data: {json.dumps(value)}\n\n'


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length') or 0)).decode()
        with open(LOG, 'a') as f:
            f.write(json.dumps(json.loads(body)) + '\n')
        if 'function_call_output' in body:
            item = {'type': 'message', 'id': 'msg_1', 'role': 'assistant', 'status': 'completed',
                    'content': [{'type': 'output_text', 'text': 'done', 'annotations': []}]}
            out = frame({'type': 'response.output_text.delta', 'item_id': 'msg_1', 'output_index': 0,
                         'content_index': 0, 'sequence_number': 1, 'delta': 'done'})
        else:
            item = {'type': 'function_call', 'id': 'fc_1', 'call_id': 'call_1', 'name': 'run_command',
                    'status': 'completed', 'arguments': TOOL_ARGS}
            out = frame({'type': 'response.output_item.done', 'output_index': 0,
                         'sequence_number': 1, 'item': item})
        out += frame({'type': 'response.completed', 'sequence_number': 2, 'response': {
            'id': 'resp_1', 'object': 'response', 'created_at': 0, 'status': 'completed',
            'model': 'fake', 'output': [item], 'tools': []}})
        data = out.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(data)


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(PORT_FILE, 'w') as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
