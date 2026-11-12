"""stub.py - A stand-in for Wrike's API v4, for testing gnoto without a Wrike account.

Run by:  test/testbed/testbed.sh services, in python:3.14-slim, on the test bed's
         network as wrike-stub, port 8080
Usage:   python3 stub.py [--token <token>]

Holds its state in memory: spaces, workflows and their statuses, folders,
custom fields, tasks with their custom fields, comments and attachments,
webhooks and request forms. It answers the calls gnoto makes, in Wrike's shape,
with a bearer token required. Parameters come as a query string or a form body,
as Wrike takes them, and those Wrike takes as JSON are parsed.

Test helpers, which need no token:
  POST /_test/fail?count=N&code=C   the next N API calls answer C
  GET  /_test/state                  the whole state, as JSON
  POST /_test/form                   adds a request form: a JSON body with
                                     title, spaceId and pages
  POST /_test/reset                  forgets everything
"""

import itertools
import json
import random
import string
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TOKEN = sys.argv[sys.argv.index('--token') + 1] if '--token' in sys.argv else 'stub-token'
BOT = {'id': 'KUSTUBBOT', 'firstName': 'gnoto', 'lastName': 'Bot', 'profiles': [{'role': 'User'}]}
LOCK = threading.Lock()
IDS = itertools.count(1)
RUN = ''.join(random.choices(string.ascii_uppercase + string.digits, k=4))
STATE = {}
FAIL = {'count': 0, 'code': 500}


def reset():
    STATE.clear()
    STATE.update(spaces={}, workflows={}, folders={}, fields={}, tasks={}, webhooks={}, forms={},
                 attachments={}, calls=[])


def new_id(prefix, width=16):
    """An ID unique to this stub's run, as Wrike's are for good: gnoto derives a
    run's uid from its task's ID, so a stub started again mustn't repeat one."""
    head = prefix[:width - 10]
    return head + RUN + str(next(IDS)).zfill(width - len(head) - len(RUN))


def now():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def as_json(value):
    if value is None:
        return None
    try:
        return json.loads(value)
    except ValueError:
        return value


def task_view(task, fields=()):
    view = {k: v for k, v in task.items() if k not in ('comments', 'attachmentIds')}
    return view


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, code, body, ctype='application/json'):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def data(self, kind, items):
        self.answer(200, {'kind': kind, 'data': items})

    def error(self, code, text):
        self.answer(code, {'errorDescription': text, 'error': 'stub'})

    def params(self):
        url = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query, keep_blank_values=True).items()}
        length = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(length) if length else b''
        if raw and 'x-www-form-urlencoded' in (self.headers.get('Content-Type') or 'x-www-form-urlencoded'):
            if not self.headers.get('X-File-Name'):
                query.update({k: v[0] for k, v in parse_qs(raw.decode(), keep_blank_values=True).items()})
        return url.path, query, raw

    def do_GET(self):
        self.route('GET')

    def do_POST(self):
        self.route('POST')

    def do_PUT(self):
        self.route('PUT')

    def do_DELETE(self):
        self.route('DELETE')

    def route(self, verb):
        path, p, raw = self.params()
        with LOCK:
            if path.startswith('/_test/'):
                return self.test_route(verb, path, p, raw)
            if path.startswith('/sts'):
                # STS's GetCallerIdentity, which gnoto's lint asks, for the test
                # bed's AWS stand-ins
                return self.answer(200, (
                    '<GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">'
                    '<GetCallerIdentityResult><Arn>arn:aws:iam::000000000000:user/gnoto/stand-in</Arn>'
                    '<UserId>STANDIN</UserId><Account>000000000000</Account></GetCallerIdentityResult>'
                    '<ResponseMetadata><RequestId>stub</RequestId></ResponseMetadata>'
                    '</GetCallerIdentityResponse>').encode(), 'text/xml')
            STATE['calls'].append({'verb': verb, 'path': path, 'params': p})
            if self.headers.get('Authorization') != 'bearer ' + TOKEN:
                return self.error(401, 'Not authorized')
            if FAIL['count'] > 0:
                FAIL['count'] -= 1
                return self.error(FAIL['code'], 'Injected failure')
            parts = [x for x in path.split('/') if x][2:]
            try:
                return self.api(verb, parts, p, raw)
            except KeyError as missing:
                return self.error(404, f'Not found: {missing}')

    def test_route(self, verb, path, p, raw):
        if path == '/_test/fail':
            FAIL['count'] = int(p.get('count', 1))
            FAIL['code'] = int(p.get('code', 500))
            return self.answer(200, FAIL)
        if path == '/_test/state':
            return self.answer(200, STATE)
        if path == '/_test/reset':
            reset()
            return self.answer(200, {})
        if path == '/_test/form':
            form = json.loads(raw)
            form['id'] = new_id('IEFORM')
            STATE['forms'][form['id']] = form
            return self.data('requestForms', [form])
        return self.error(404, path)

    def api(self, verb, parts, p, raw):
        s = STATE
        match (verb, parts):
            case ('GET', ['contacts']):
                return self.data('contacts', [BOT])
            case ('GET', ['spaces']):
                return self.data('spaces', list(s['spaces'].values()))
            case ('POST', ['spaces']):
                space = {'id': new_id('MQSPACE', 12), 'title': p['title'], 'accessType': p.get('accessType'),
                         'defaultTaskWorkflowId': p.get('defaultTaskWorkflowId')}
                s['spaces'][space['id']] = space
                return self.data('spaces', [space])
            case ('GET', ['spaces', sid]):
                return self.data('spaces', [s['spaces'][sid]])
            case ('PUT', ['spaces', sid]):
                s['spaces'][sid].update({k: v for k, v in p.items() if k in ('defaultTaskWorkflowId', 'title')})
                return self.data('spaces', [s['spaces'][sid]])
            case ('GET', ['workflows']):
                return self.data('workflows', list(s['workflows'].values()))
            case ('POST', ['workflows']):
                wf = {'id': new_id('IEWF'), 'name': p['name'], 'standard': False, 'hidden': False,
                      'customStatuses': [{'id': new_id('IESTNEW'), 'name': 'New', 'group': 'Active', 'hidden': False}]}
                s['workflows'][wf['id']] = wf
                return self.data('workflows', [wf])
            case ('PUT', ['workflows', wid]):
                wf = s['workflows'][wid]
                status = as_json(p.get('customStatus'))
                if isinstance(status, dict):
                    if status.get('id'):
                        next(x for x in wf['customStatuses'] if x['id'] == status['id']).update(status)
                    else:
                        wf['customStatuses'].append({'id': new_id('IEST'), **status})
                return self.data('workflows', [wf])
            case ('GET', ['spaces', sid, 'folders']):
                return self.data('folders', [f for f in s['folders'].values() if f['spaceId'] == sid])
            case ('POST', ['folders', parent, 'folders']):
                space = parent if parent in s['spaces'] else s['folders'][parent]['spaceId']
                folder = {'id': new_id('MQFOLDER', 12), 'title': p['title'], 'spaceId': space,
                          'scope': 'WsFolder', 'parentIds': [parent]}
                s['folders'][folder['id']] = folder
                return self.data('folders', [folder])
            case ('GET', ['spaces', sid, 'customfields']):
                return self.data('customfields', [f for f in s['fields'].values() if f.get('spaceId') == sid])
            case ('POST', ['customfields']):
                field = {'id': new_id('IECF'), 'title': p['title'], 'type': p['type'], 'spaceId': p.get('spaceId'),
                         'settings': as_json(p.get('settings')) or {}}
                s['fields'][field['id']] = field
                return self.data('customfields', [field])
            case ('PUT', ['customfields', fid]):
                s['fields'][fid]['settings'].update(as_json(p.get('settings')) or {})
                return self.data('customfields', [s['fields'][fid]])
            case ('GET', ['webhooks']):
                return self.data('webhooks', list(s['webhooks'].values()))
            case ('GET', ['webhooks', wid]):
                return self.data('webhooks', [s['webhooks'][wid]])
            case ('POST', ['folders', fid, 'webhooks']):
                events = p.get('events', '').strip('[]')
                hook = {'id': new_id('IEHOOK'), 'folderId': fid, 'hookUrl': p['hookUrl'], 'status': 'Active',
                        'events': [e for e in events.split(',') if e], 'secret': p.get('secret')}
                s['webhooks'][hook['id']] = hook
                return self.data('webhooks', [hook])
            case ('PUT', ['webhooks', wid]):
                s['webhooks'][wid]['status'] = p.get('status', 'Active')
                return self.data('webhooks', [s['webhooks'][wid]])
            case ('DELETE', ['webhooks', wid]):
                del s['webhooks'][wid]
                return self.data('webhooks', [])
            case ('GET', ['spaces', sid, 'request_forms']):
                return self.data('requestForms', [f for f in s['forms'].values() if f.get('spaceId') == sid])
            case ('GET', ['request_forms', rid]):
                return self.data('requestForms', [s['forms'][rid]])
            case ('POST', ['folders', fid, 'tasks']):
                task = {'id': new_id('MASTUBTASK', 12), 'title': p['title'], 'description': p.get('description', ''),
                        'customStatusId': p.get('customStatus'), 'customFields': as_json(p.get('customFields')) or [],
                        'parentIds': [fid], 'authorIds': [p.get('_author', BOT['id'])], 'scope': 'WsTask',
                        'createdDate': now(), 'comments': [], 'attachmentIds': []}
                s['tasks'][task['id']] = task
                return self.data('tasks', [task_view(task)])
            case ('GET', ['folders', fid, 'tasks']):
                tasks = [task_view(t) for t in s['tasks'].values() if fid in t['parentIds'] and t['scope'] == 'WsTask']
                return self.answer(200, {'kind': 'tasks', 'data': tasks})
            case ('GET', ['tasks', tid]):
                return self.data('tasks', [task_view(s['tasks'][tid])])
            case ('PUT', ['tasks', tid]):
                task = s['tasks'][tid]
                if task['scope'] != 'WsTask':
                    return self.error(404, 'deleted')
                if 'customStatus' in p:
                    task['customStatusId'] = p['customStatus']
                for change in as_json(p.get('customFields')) or []:
                    task['customFields'] = [f for f in task['customFields'] if f['id'] != change['id']]
                    if change.get('value', '') != '':
                        task['customFields'].append(change)
                return self.data('tasks', [task_view(task)])
            case ('DELETE', ['tasks', tid]):
                s['tasks'][tid]['scope'] = 'RbTask'
                return self.data('tasks', [task_view(s['tasks'][tid])])
            case ('GET', ['tasks', tid, 'comments']):
                return self.data('comments', s['tasks'][tid]['comments'])
            case ('POST', ['tasks', tid, 'comments']):
                comment = {'id': new_id('IECOMMENT'), 'authorId': BOT['id'], 'text': p['text'],
                           'plainText': p.get('plainText') == 'true', 'createdDate': now()}
                s['tasks'][tid]['comments'].append(comment)
                return self.data('comments', [comment])
            case ('GET', ['tasks', tid, 'attachments']):
                ids = s['tasks'][tid]['attachmentIds']
                return self.data('attachments', [{k: v for k, v in s['attachments'][a].items() if k != 'content'}
                                                 for a in ids])
            case ('POST', ['tasks', tid, 'attachments']):
                att = {'id': new_id('IEATT'), 'name': self.headers.get('X-File-Name'), 'taskId': tid,
                       'size': len(raw), 'content': raw.decode('latin-1')}
                s['attachments'][att['id']] = att
                s['tasks'][tid]['attachmentIds'].append(att['id'])
                return self.data('attachments', [{k: v for k, v in att.items() if k != 'content'}])
            case ('GET', ['attachments', aid, 'download']):
                return self.answer(200, s['attachments'][aid]['content'].encode('latin-1'), 'application/octet-stream')
        return self.error(404, f'The stub has no {verb} {"/".join(parts)}')


if __name__ == '__main__':
    reset()
    ThreadingHTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
