# access.py - The Lambda behind the dashboards' Get the data: finishes a
# reader's Globus sign-in, and queues a request for gnoto's listener to grant
# that identity read on the run's folder.
#
# Deployed by:  gnoto config sqs --deploy, inline in service/aws/stacks/sqs.yaml,
#               with its comments taken out, when globus.app_client_id and S3
#               are set. A site that sets up its own queue deploys this file
#               as the function, handler lambda_handler, behind an HTTP API
#               that allows its results' origin.
# Runtime:      python3.14, with the boto3 Lambda includes
# Env:          AWS_SQS_QUEUE_URL, the queue; RESULTS_BUCKET and RUN_PREFIX,
#               where the dashboards are; GLOBUS_CLIENT_ID, the dashboards'
#               Globus app, a public client; REDIRECT_URI, its return page,
#               <results_base_url>/<run_prefix>/access.html; GLOBUS_AUTH_URL,
#               https://auth.globus.org unless a test sets it
#
# The return page posts {run, code, verifier, request}: the run's folder,
# <uid>-<token>; the authorization code and PKCE verifier from the sign-in;
# and a random ID the listener answers under, at <run>/access/<request>.json.
# Anyone with a dashboard's address may have its data, so the reader is checked
# only for having signed in. The run must have globus.json beside its
# dashboard, which Publish writes for a run on Globus, so a made-up address
# never reaches the queue. The code is exchanged here and the identity read
# from Globus Auth's userinfo; the token is revoked, and only the identity is
# queued.

import base64
import json
import os
import re
import urllib.parse
import urllib.request

import boto3
from botocore.exceptions import ClientError

QUEUE_URL = os.environ.get('AWS_SQS_QUEUE_URL', '')
BUCKET = os.environ.get('RESULTS_BUCKET', '')
PREFIX = os.environ.get('RUN_PREFIX', '') or 'gnoto'
CLIENT_ID = os.environ.get('GLOBUS_CLIENT_ID', '')
REDIRECT = os.environ.get('REDIRECT_URI', '')
AUTH = (os.environ.get('GLOBUS_AUTH_URL', '') or 'https://auth.globus.org').rstrip('/')
RUN = re.compile(r'[a-z2-7]{8}-[a-z2-7]{16}')
REQUEST = re.compile(r'[0-9a-f]{32}')
VERIFIER = re.compile(r'[A-Za-z0-9._~-]{43,128}')
CODE = re.compile(r'[!-~]{1,1024}')
IDENTITY = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')

s3 = boto3.client('s3')
sqs = boto3.client('sqs')


def reply(status, body):
    return {'statusCode': status, 'headers': {'Content-Type': 'application/json'}, 'body': json.dumps(body)}


def matches(pattern, value):
    return isinstance(value, str) and pattern.fullmatch(value) is not None


# A call to Globus Auth: a form posted, or with a token, a GET
def auth(path, form=None, token=None):
    request = urllib.request.Request(AUTH + path, data=urllib.parse.urlencode(form).encode() if form else None)
    if token:
        request.add_header('Authorization', 'Bearer ' + token)
    with urllib.request.urlopen(request, timeout=8) as response:
        return json.loads(response.read() or b'{}')


def lambda_handler(event, context):
    if not (QUEUE_URL and BUCKET and CLIENT_ID and REDIRECT):
        return reply(500, {'error': 'Missing settings'})
    try:
        raw = event.get('body') or ''
        body = json.loads(base64.b64decode(raw) if event.get('isBase64Encoded') else raw)
        run, code, verifier, request = (body.get(k) for k in ('run', 'code', 'verifier', 'request'))
    except (ValueError, TypeError, AttributeError):
        return reply(400, {'error': 'Unreadable request'})
    if not all(matches(p, v) for p, v in ((RUN, run), (CODE, code), (VERIFIER, verifier), (REQUEST, request))):
        return reply(400, {'error': 'Not a request for a run'})

    # 1. A run on Globus, as Publish says
    try:
        s3.head_object(Bucket=BUCKET, Key=f'{PREFIX}/{run}/globus.json')
    except ClientError:
        return reply(404, {'error': 'No run on Globus there'})

    # 2. The sign-in, finished, and who it is
    try:
        token = auth('/v2/oauth2/token', {'grant_type': 'authorization_code', 'code': code, 'redirect_uri': REDIRECT,
                                          'client_id': CLIENT_ID, 'code_verifier': verifier})['access_token']
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'Sign-in refused: {error}')
        return reply(403, {'error': 'Globus refused the sign-in'})
    who = {}
    try:
        who = auth('/v2/oauth2/userinfo', token=token)
        auth('/v2/oauth2/token/revoke', {'token': token, 'client_id': CLIENT_ID})
    except (OSError, ValueError) as error:
        print(f'Globus Auth failed: {error}')
    identity = who.get('sub') if isinstance(who, dict) else None
    if not matches(IDENTITY, identity):
        return reply(502, {'error': 'Globus did not say who signed in'})

    # 3. The identity, queued
    message = {'gnoto': 'globus_access', 'run': run, 'request': request, 'identity': identity,
               'username': str(who.get('preferred_username') or '')[:200]}
    try:
        send = {'QueueUrl': QUEUE_URL, 'MessageBody': json.dumps(message)}
        if QUEUE_URL.endswith('.fifo'):
            send.update(MessageGroupId='globus-access', MessageDeduplicationId=request)
        sqs.send_message(**send)
    except Exception as error:
        print(f'SQS error: {error}')
        return reply(500, {'error': 'Failed to queue the request'})
    return reply(202, {'status': 'queued'})
