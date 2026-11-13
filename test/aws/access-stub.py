# access-stub.py - Stands in for Globus Auth and for S3's HEAD of a run's
# globus.json, for test/aws/access-test.sh, inside the Lambda's own container.
#
# Run by:    access-test.sh, as python3 access-stub.py <port> <state dir>
#
# Globus Auth: the token endpoint refuses the code "bad", answers the code
# "nosub" with a token whose userinfo names nobody, and otherwise answers
# tok-123, whose userinfo is a reader. It writes each form it's posted to
# <state dir>/<endpoint>.json. S3: only the run abcdefgh-abcdefghijklmnop has
# a globus.json, in any bucket under the prefix gnoto.

import json
import os
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
STATE = sys.argv[2]
RUN_KEY = '/gnoto/abcdefgh-abcdefghijklmnop/globus.json'
READER = {'sub': 'aaaaaaaa-0000-4000-8000-000000000001', 'preferred_username': 'reader@example.org'}


class Stub(BaseHTTPRequestHandler):
    def answer(self, status, body=None):
        data = json.dumps(body).encode() if body is not None else b''
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def form(self, name):
        length = int(self.headers.get('Content-Length') or 0)
        form = dict(urllib.parse.parse_qsl(self.rfile.read(length).decode()))
        with open(os.path.join(STATE, name + '.json'), 'w') as f:
            json.dump(form, f)
        return form

    def do_HEAD(self):
        self.answer(200 if self.path.split('?')[0].endswith(RUN_KEY) else 404)

    def do_POST(self):
        if self.path == '/v2/oauth2/token':
            code = self.form('token').get('code')
            if code == 'bad':
                return self.answer(400, {'error': 'invalid_grant'})
            return self.answer(200, {'access_token': 'tok-nosub' if code == 'nosub' else 'tok-123'})
        if self.path == '/v2/oauth2/token/revoke':
            self.form('revoke')
            return self.answer(200, {'active': False})
        self.answer(404, {})

    def do_GET(self):
        if self.path == '/v2/oauth2/userinfo':
            token = self.headers.get('Authorization', '')
            if token == 'Bearer tok-123':
                return self.answer(200, READER)
            if token == 'Bearer tok-nosub':
                return self.answer(200, {})
            return self.answer(401, {'error': 'unauthorized'})
        self.answer(404, {})

    def log_message(self, *args):
        pass


HTTPServer(('127.0.0.1', PORT), Stub).serve_forever()
