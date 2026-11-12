# webhook.py - The Lambda behind Wrike's webhook: checks each request's
# signature, and puts the events on the SQS queue gnoto's listener reads.
#
# Deployed by:  gnoto config sqs --deploy, inline in service/aws/stacks/sqs.yaml,
#               with its comments taken out. A site that sets up its own queue
#               deploys this file as the function, handler lambda_handler.
# Runtime:      python3.14, with the boto3 Lambda includes
# Env:          AWS_SQS_QUEUE_URL, the queue; WRIKE_WEBHOOK_SECRET, the secret
#               the webhook was registered with, wrike.webhook_secret
#
# Every request is signed: X-Hook-Signature is the lowercase hex HMAC-SHA256 of
# the raw body, and anything without a valid one is refused. Wrike also sends an
# X-Hook-Secret challenge, on events as well as on the handshake it makes when
# the webhook is registered, and each reply carries X-Hook-Secret:
# HMAC-SHA256(secret, challenge). A challenge that isn't 1 to 100 ASCII letters
# and digits is refused. Don't loosen that check: the reply is a signature over
# whatever the caller sent, so a JSON challenge would come back as a valid
# X-Hook-Signature for a forged event.
#
# The handshake is told apart by its body, {"requestType": "WebHook secret
# verification"}, and is answered but not queued. Everything else that passes is
# queued as it came. Don't treat X-Hook-Secret as marking the handshake: events
# carry it too, and would be answered and dropped.

import base64
import hashlib
import hmac
import json
import os
import re

import boto3

QUEUE_URL = os.environ.get('AWS_SQS_QUEUE_URL', '')
SECRET = os.environ.get('WRIKE_WEBHOOK_SECRET', '')
CHALLENGE = re.compile(r'[A-Za-z0-9]{1,100}')

sqs = boto3.client('sqs')


def sign(data):
    return hmac.new(SECRET.encode('utf-8'), data, hashlib.sha256).hexdigest()


def reply(status, body, headers=None):
    return {'statusCode': status, 'headers': {'Content-Type': 'application/json', **(headers or {})},
            'body': json.dumps(body)}


def is_handshake(text):
    try:
        body = json.loads(text)
    except ValueError:
        return False
    return isinstance(body, dict) and body.get('requestType') == 'WebHook secret verification'


def lambda_handler(event, context):
    if not QUEUE_URL or not SECRET:
        return reply(500, {'error': 'The function is missing its settings'})
    headers = {k.lower(): v for k, v in (event.get('headers') or {}).items()}
    raw = event.get('body') or ''
    try:
        data = base64.b64decode(raw) if event.get('isBase64Encoded') else raw.encode('utf-8')
        text = data.decode('utf-8')
    except (ValueError, UnicodeDecodeError):
        return reply(400, {'error': 'Unreadable body'})

    # 1. A malformed challenge is refused before anything is computed from it
    challenge = headers.get('x-hook-secret')
    if challenge is not None and not CHALLENGE.fullmatch(challenge):
        return reply(400, {'error': 'Invalid X-Hook-Secret'})

    # 2. The signature, which every request carries, events and handshake alike
    signature = headers.get('x-hook-signature')
    if not signature:
        return reply(401, {'error': 'Missing signature'})
    if not hmac.compare_digest(sign(data), signature.lower()):
        return reply(403, {'error': 'Invalid signature'})

    # 3. The challenge's answer, which Wrike asks for with events too
    answer = {'X-Hook-Secret': sign(challenge.encode('utf-8'))} if challenge is not None else {}

    # 4. The handshake is answered and not queued
    if is_handshake(text):
        return reply(200, {'status': 'handshake_success'}, answer)

    # 5. An event, queued as it came
    try:
        message = {'QueueUrl': QUEUE_URL, 'MessageBody': text}
        if QUEUE_URL.endswith('.fifo'):
            message['MessageGroupId'] = 'wrike-webhook-events'
        sqs.send_message(**message)
    except Exception as error:
        print(f'SQS error: {error}')
        return reply(500, {'error': 'Failed to enqueue message'})
    return reply(200, {'status': 'message_queued'}, answer)
